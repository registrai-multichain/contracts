// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";
import {NanoLedger} from "./NanoLedger.sol";
import {SettlementPolicy} from "./SettlementPolicy.sol";

/// @title MarketsV4. A binary prediction market settled entirely on NanoLedger.
/// @notice Common markets. Same constant-product AMM as Markets, but ALL value
///         moves as NanoLedger internal-balance accounting instead of ERC20
///         transfers: collateral in via ledger.transferFromInternal(trader ->
///         this), payouts via ledger.internalTransfer(this -> recipient). Real
///         USDC only crosses at NanoLedger.deposit/withdraw. Traders approve
///         MarketsV4 on the ledger (approveSpender) before trading. MarketsV4
///         needs no ledger role (it creates no fee pools).
///
///         Fees: a TRADE_FEE_BPS (1%) trading fee on every buy (of collateralIn)
///         and every sell (of the gross curve amount; the seller receives the
///         rest), split per trade: 30% to the market creator and 50% to the
///         Registrai TREASURY (the rounding remainder), paid now; 20% to the
///         bonded agent, HELD in `agentEscrow` until the market settles.
///         Nothing is charged at settlement. resolve releases the escrow to the
///         agent; winners redeem 1 per winning share; the LP gets the winning
///         reserve.
///
///         Void: a market that cannot be settled voids (SettlementPolicy, shared
///         with MarketsPerennial). The escrow goes to the challenger who got the
///         agent's reading ruled Invalid, else to the treasury. Every trader is
///         refunded its net cost (what it put in after fees, minus what it took
///         out; pro rata only if earlier sellers took profits larger than the LP
///         seed); the LP gets the rest.
///
///         Agents are permissionless: any agent registered and active on the
///         feed may settle a market. Governance (GOVERNOR_ROLE) is limited to
///         the allowlist of dispute resolvers a market's feed may name, and a
///         feed whose agent is its own resolver is always refused.
contract MarketsV4 is AccessControl, ReentrancyGuard, SettlementPolicy {
    enum Outcome { Yes, No }
    enum Comparator { GreaterThan, GreaterOrEqual, LessThan, LessOrEqual }
    enum Phase { Trading, Resolved, Voided }

    struct Market {
        bytes32 feedId;
        address agent;
        int256 threshold;
        Comparator comparator;
        uint256 expiry;
        address creator;
        uint256 yesReserve;
        uint256 noReserve;
        Phase phase;
        bool yesWon;
        uint256 createdAt;
    }

    NanoLedger public immutable LEDGER;
    Registry public immutable REGISTRY;
    Attestation public immutable ATTESTATION;
    /// @notice The Registrai treasury: receives the 50% leg. Immutable.
    address public immutable TREASURY;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    uint256 public constant MIN_LIQUIDITY = 5e6;
    /// @notice The trading fee: 1% of every buy and every sell.
    uint256 public constant TRADE_FEE_BPS = 100;
    /// @notice Shares of each trading fee (of BPS). The agent's 20% is escrowed
    /// until settlement (the challenger reward on void); the treasury takes the rounding remainder.
    uint256 public constant CREATOR_SHARE_BPS = 3000;
    uint256 public constant AGENT_SHARE_BPS = 2000;
    uint256 public constant TREASURY_SHARE_BPS = 5000;
    uint256 public constant BPS = 10_000;

    mapping(bytes32 => Market) internal _markets;
    mapping(bytes32 => mapping(address => uint256)) public yesBalance;
    mapping(bytes32 => mapping(address => uint256)) public noBalance;
    mapping(address => uint256) public createdBy;
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    mapping(bytes32 => uint256) public totalLpShares;
    mapping(bytes32 => uint256) public lpPotAtResolution;

    /// @notice C: all collateral backing a market (== YES supply == NO supply).
    mapping(bytes32 => uint256) public collateralOf;
    /// @notice What a trader has put in after fees and not yet taken out (never
    /// below 0; the LP seed is not a trader cost).
    mapping(bytes32 => mapping(address => uint256)) public netCost;
    /// @notice Sum of every trader's netCost.
    mapping(bytes32 => uint256) public totalNetCost;
    /// @notice The agent's 20% of every trading fee, held until the market
    /// settles: released to the agent on resolve, to a successful challenger
    /// (else the treasury) on void.
    mapping(bytes32 => uint256) public agentEscrow;
    /// @notice At void: what traders share (their net cost, capped by what the
    /// market holds), and the totalNetCost it is shared over.
    mapping(bytes32 => uint256) public voidTraderPool;
    mapping(bytes32 => uint256) public voidNetCostTotal;

    /// @notice Governor allowlist of dispute resolvers a market's feed may name.
    /// A feed's resolver is fixed at Registry.createFeed (no setter) and Dispute
    /// snapshots it per challenge, so checking it once at market creation is sound.
    mapping(address => bool) public approvedResolver;

    event MarketCreated(bytes32 indexed marketId, address indexed creator, bytes32 indexed feedId, address agent, int256 threshold, Comparator comparator, uint256 expiry, uint256 liquidity);
    event Bought(bytes32 indexed marketId, address indexed buyer, Outcome outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee);
    event Sold(bytes32 indexed marketId, address indexed seller, Outcome outcome, uint256 sharesIn, uint256 collateralOut, uint256 fee);
    event FeesPaid(bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 agentFee);
    event Resolved(bytes32 indexed marketId, bool yesWon, int256 value);
    event Redeemed(bytes32 indexed marketId, address indexed holder, uint256 payout);
    event LPClaimed(bytes32 indexed marketId, address indexed lp, uint256 payout);
    event MarketVoided(bytes32 indexed marketId);
    event AgentFeeReleased(bytes32 indexed marketId, address indexed agent, uint256 amount);
    event VoidFeesPaid(
        bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 challengerReward, address challenger
    );
    event ResolverApprovalSet(address indexed resolver, bool approved);

    error MarketMissing();
    error MarketExists();
    error NotTrading();
    error MarketExpired();
    error MarketNotExpired();
    error AlreadyResolved();
    error NotResolved();
    error AmountTooLow();
    error LiquidityTooLow();
    error BadExpiry();
    error AgentNotRegistered();
    error SlippageExceeded();
    error InsufficientShares();
    error NoLPShares();
    error ZeroAddress();
    error ReserveDepleted();
    error ResolverNotApproved();
    error SelfResolvedFeed();

    constructor(
        NanoLedger ledger_,
        Registry registry_,
        Attestation attestation_,
        address admin,
        address treasury_,
        uint256 settlementWindow_,
        uint256 resolutionGrace_
    ) SettlementPolicy(settlementWindow_, resolutionGrace_) {
        if (treasury_ == address(0) || admin == address(0)) revert ZeroAddress();
        LEDGER = ledger_;
        REGISTRY = registry_;
        ATTESTATION = attestation_;
        TREASURY = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ───────────────────────────── create ─────────────────────────────

    function createMarket(
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    ) external nonReentrant returns (bytes32 marketId) {
        if (expiry <= block.timestamp) revert BadExpiry();
        if (liquidity < MIN_LIQUIDITY) revert LiquidityTooLow();
        if (!REGISTRY.isActiveAgent(feedId, agent)) revert AgentNotRegistered();
        _requireApprovedOracle(feedId, agent);
        _requireSettleableFeed(REGISTRY, feedId);

        uint256 nonce = createdBy[msg.sender]++;
        marketId = keccak256(abi.encode(msg.sender, nonce, feedId, agent, threshold, comparator, expiry));
        if (_markets[marketId].createdAt != 0) revert MarketExists();

        // pull seed liquidity from the creator's ledger balance (approved)
        LEDGER.transferFromInternal(msg.sender, address(this), liquidity);

        _markets[marketId] = Market({
            feedId: feedId, agent: agent, threshold: threshold, comparator: comparator,
            expiry: expiry, creator: msg.sender, yesReserve: liquidity, noReserve: liquidity,
            phase: Phase.Trading, yesWon: false, createdAt: block.timestamp
        });
        lpShares[marketId][msg.sender] = liquidity;
        totalLpShares[marketId] = liquidity;
        collateralOf[marketId] = liquidity;

        emit MarketCreated(marketId, msg.sender, feedId, agent, threshold, comparator, expiry, liquidity);
    }

    /// @dev Agents are permissionless (createMarket already requires the agent to
    /// be registered and active on the feed). The dispute resolver is not: the
    /// feed must name a governor-approved resolver, and never its own agent —
    /// otherwise anyone could open a market on a feed where they attest AND
    /// adjudicate, and settle it however they like. Checked at creation only:
    /// the feed's resolver cannot change afterwards, and revoking an approval
    /// must not strand markets already open (they settle or void as before).
    function _requireApprovedOracle(bytes32 feedId, address agent) internal view {
        address resolver = REGISTRY.getFeed(feedId).resolver;
        if (!approvedResolver[resolver]) revert ResolverNotApproved();
        if (resolver == agent) revert SelfResolvedFeed();
    }

    // ───────────────────────────── trade ─────────────────────────────

    function buy(bytes32 marketId, Outcome outcome, uint256 collateralIn, uint256 minSharesOut)
        external nonReentrant returns (uint256 sharesOut)
    {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert NotTrading();
        if (block.timestamp >= m.expiry) revert MarketExpired();
        if (collateralIn == 0) revert LiquidityTooLow();

        LEDGER.transferFromInternal(msg.sender, address(this), collateralIn);
        uint256 fee = (collateralIn * TRADE_FEE_BPS) / BPS;
        uint256 effectiveIn = collateralIn - fee;
        _chargeFee(marketId, m, fee);
        collateralOf[marketId] += effectiveIn;
        netCost[marketId][msg.sender] += effectiveIn;
        totalNetCost[marketId] += effectiveIn;

        // what is left after the fee mints a full YES + NO set
        uint256 yesAfterMint = m.yesReserve + effectiveIn;
        uint256 noAfterMint = m.noReserve + effectiveIn;
        uint256 k = m.yesReserve * m.noReserve;

        if (outcome == Outcome.Yes) {
            sharesOut = yesAfterMint - Math.ceilDiv(k, noAfterMint);
            m.yesReserve = yesAfterMint - sharesOut;
            m.noReserve = noAfterMint;
            yesBalance[marketId][msg.sender] += sharesOut;
        } else {
            sharesOut = noAfterMint - Math.ceilDiv(k, yesAfterMint);
            m.noReserve = noAfterMint - sharesOut;
            m.yesReserve = yesAfterMint;
            noBalance[marketId][msg.sender] += sharesOut;
        }
        if (sharesOut == 0) revert AmountTooLow();
        if (m.yesReserve == 0 || m.noReserve == 0) revert ReserveDepleted();
        if (sharesOut < minSharesOut) revert SlippageExceeded();
        emit Bought(marketId, msg.sender, outcome, collateralIn, sharesOut, fee);
    }

    function sell(bytes32 marketId, Outcome outcome, uint256 sharesIn, uint256 minCollateralOut)
        external nonReentrant returns (uint256 collateralOut)
    {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert NotTrading();
        if (block.timestamp >= m.expiry) revert MarketExpired();
        if (sharesIn == 0) revert LiquidityTooLow();

        if (outcome == Outcome.Yes) {
            if (yesBalance[marketId][msg.sender] < sharesIn) revert InsufficientShares();
            yesBalance[marketId][msg.sender] -= sharesIn;
        } else {
            if (noBalance[marketId][msg.sender] < sharesIn) revert InsufficientShares();
            noBalance[marketId][msg.sender] -= sharesIn;
        }

        uint256 yesPostSell = outcome == Outcome.Yes ? m.yesReserve + sharesIn : m.yesReserve;
        uint256 noPostSell = outcome == Outcome.No ? m.noReserve + sharesIn : m.noReserve;
        uint256 k = m.yesReserve * m.noReserve;
        uint256 sumAB = yesPostSell + noPostSell;
        uint256 prodAB = yesPostSell * noPostSell;
        uint256 disc = sumAB * sumAB - 4 * (prodAB - k);
        // Round in the protocol's favour: the exact payout is (sumAB - sqrt(disc)) / 2;
        // ceiling the root and flooring the halving can only pay less, so k never
        // decreases on a sell (a floored root could pay 1 unit over the curve).
        uint256 grossOut = (sumAB - Math.sqrt(disc, Math.Rounding.Ceil)) / 2;

        uint256 fee = (grossOut * TRADE_FEE_BPS) / BPS;
        collateralOut = grossOut - fee;
        if (collateralOut < minCollateralOut) revert SlippageExceeded();

        m.yesReserve = yesPostSell - grossOut;
        m.noReserve = noPostSell - grossOut;
        if (m.yesReserve == 0 || m.noReserve == 0) revert ReserveDepleted();

        _recordSell(marketId, grossOut);
        _chargeFee(marketId, m, fee);
        if (collateralOut > 0) LEDGER.internalTransfer(msg.sender, collateralOut);
        emit Sold(marketId, msg.sender, outcome, sharesIn, collateralOut, fee);
    }

    /// @dev A sell burns `out` (the gross curve amount) of each side, so C falls by
    /// `out`. The seller's net cost falls by at most what it still has in: a
    /// profit beyond it is not a negative cost.
    function _recordSell(bytes32 marketId, uint256 out) internal {
        collateralOf[marketId] -= out;
        uint256 nc = netCost[marketId][msg.sender];
        uint256 d = out < nc ? out : nc;
        if (d > 0) {
            netCost[marketId][msg.sender] = nc - d;
            totalNetCost[marketId] -= d;
        }
    }

    /// @dev Split one trading fee: creator 30% and treasury (the rounding
    /// remainder, so no unit is stranded) paid now; the agent's 20% escrowed for
    /// the market until it settles. Emits FeesPaid on every trade.
    function _chargeFee(bytes32 marketId, Market storage m, uint256 fee) internal {
        uint256 creatorFee = (fee * CREATOR_SHARE_BPS) / BPS;
        uint256 agentFee = (fee * AGENT_SHARE_BPS) / BPS;
        uint256 treasuryFee = fee - creatorFee - agentFee;
        if (agentFee > 0) agentEscrow[marketId] += agentFee; // stays in this contract's ledger balance
        _pay(m.creator, creatorFee);
        _pay(TREASURY, treasuryFee);
        emit FeesPaid(marketId, creatorFee, treasuryFee, agentFee);
    }

    function _pay(address to, uint256 amount) internal {
        if (amount > 0) LEDGER.internalTransfer(to, amount);
    }

    // ───────────────────────── resolve / claim ─────────────────────────

    function resolve(bytes32 marketId) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert AlreadyResolved();
        if (block.timestamp < m.expiry) revert MarketNotExpired();

        (Settlement state, int256 value) = _settlement(ATTESTATION, m.feedId, m.agent, m.expiry);
        if (state != Settlement.Resolvable) revert SettlementPending();

        bool yesWon = _evaluate(value, m.threshold, m.comparator);
        m.yesWon = yesWon;
        m.phase = Phase.Resolved;

        lpPotAtResolution[marketId] = yesWon ? m.yesReserve : m.noReserve;
        emit Resolved(marketId, yesWon, value);

        uint256 escrow = agentEscrow[marketId];
        if (escrow > 0) {
            agentEscrow[marketId] = 0;
            LEDGER.internalTransfer(m.agent, escrow);
        }
        emit AgentFeeReleased(marketId, m.agent, escrow);
    }

    /// @notice Close a market that can no longer be settled. Anyone may call it.
    /// @dev Nothing is charged. The agent's escrow goes to the challenger that got
    /// the agent's reading ruled Invalid in the settlement window (else to the
    /// treasury). Traders share traderPool = min(totalNetCost, C), each pro
    /// rata to its net cost (so each gets its net cost back unless earlier
    /// sellers took more profit than the LP seed); the LP gets C - traderPool.
    /// Solvent by construction: the payouts sum to at most C, which the market
    /// holds besides the escrow.
    function voidMarket(bytes32 marketId) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert AlreadyResolved();
        (Settlement state,) = _settlement(ATTESTATION, m.feedId, m.agent, m.expiry);
        if (state != Settlement.Voidable) revert NotVoidable();

        m.phase = Phase.Voided;
        uint256 c = collateralOf[marketId];
        uint256 tnc = totalNetCost[marketId];
        uint256 traderPool = tnc < c ? tnc : c;
        voidTraderPool[marketId] = traderPool;
        voidNetCostTotal[marketId] = tnc;
        lpPotAtResolution[marketId] = c - traderPool;
        emit MarketVoided(marketId);

        uint256 escrow = agentEscrow[marketId];
        agentEscrow[marketId] = 0;
        address challenger = _challengerOf(ATTESTATION, m.feedId, m.agent, m.expiry);
        if (challenger != address(0)) {
            _pay(challenger, escrow);
            emit VoidFeesPaid(marketId, 0, 0, escrow, challenger);
        } else {
            _pay(TREASURY, escrow);
            emit VoidFeesPaid(marketId, 0, escrow, 0, address(0));
        }
    }

    function _evaluate(int256 value, int256 threshold, Comparator c) internal pure returns (bool) {
        if (c == Comparator.GreaterThan) return value > threshold;
        if (c == Comparator.GreaterOrEqual) return value >= threshold;
        if (c == Comparator.LessThan) return value < threshold;
        return value <= threshold;
    }

    function redeem(bytes32 marketId) external nonReentrant returns (uint256 payout) {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase == Phase.Trading) revert NotResolved();
        payout = _redeemable(marketId, m, msg.sender);
        yesBalance[marketId][msg.sender] = 0;
        noBalance[marketId][msg.sender] = 0;
        netCost[marketId][msg.sender] = 0;
        if (payout == 0) revert InsufficientShares();
        LEDGER.internalTransfer(msg.sender, payout);
        emit Redeemed(marketId, msg.sender, payout);
    }

    function claimLP(bytes32 marketId) external nonReentrant returns (uint256 payout) {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase == Phase.Trading) revert NotResolved();
        uint256 myShares = lpShares[marketId][msg.sender];
        if (myShares == 0) revert NoLPShares();
        payout = (myShares * lpPotAtResolution[marketId]) / totalLpShares[marketId];
        lpShares[marketId][msg.sender] = 0;
        if (payout > 0) LEDGER.internalTransfer(msg.sender, payout);
        emit LPClaimed(marketId, msg.sender, payout);
    }

    /// @dev Resolved: 1 per winning share. Voided: net cost
    /// * voidTraderPool / voidNetCostTotal. Trading: 0.
    function _redeemable(bytes32 marketId, Market storage m, address who) internal view returns (uint256) {
        if (m.phase == Phase.Resolved) {
            return m.yesWon ? yesBalance[marketId][who] : noBalance[marketId][who];
        }
        if (m.phase == Phase.Voided) {
            uint256 total = voidNetCostTotal[marketId];
            if (total == 0) return 0;
            return (netCost[marketId][who] * voidTraderPool[marketId]) / total;
        }
        return 0;
    }

    // ──────────────────────────── governor ────────────────────────────

    function setApprovedResolver(address resolver, bool approved) external onlyRole(GOVERNOR_ROLE) {
        if (resolver == address(0)) revert ZeroAddress();
        approvedResolver[resolver] = approved;
        emit ResolverApprovalSet(resolver, approved);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice True when a market on `feedId` settled by `agent` passes the oracle
    /// rules: the feed exists, the agent is registered and active on it, the
    /// feed's resolver is approved, and the agent is not its own resolver.
    /// (createMarket additionally needs a settleable dispute window.)
    function isApprovedFeed(bytes32 feedId, address agent) external view returns (bool) {
        Registry.Feed memory f = REGISTRY.getFeed(feedId);
        return f.exists && REGISTRY.isActiveAgent(feedId, agent) && approvedResolver[f.resolver]
            && f.resolver != agent;
    }

    /// @notice What `redeem` would pay `who` now (0 while trading).
    function redeemable(bytes32 marketId, address who) external view returns (uint256) {
        return _redeemable(marketId, _markets[marketId], who);
    }

    /// @notice What `claimLP` would pay `who` now (0 while trading).
    function claimableLP(bytes32 marketId, address who) external view returns (uint256) {
        if (_markets[marketId].phase == Phase.Trading) return 0;
        uint256 total = totalLpShares[marketId];
        if (total == 0) return 0;
        return (lpShares[marketId][who] * lpPotAtResolution[marketId]) / total;
    }

    /// @notice Where a market stands in settlement, and the settling value once
    /// it is resolvable.
    function settlementState(bytes32 marketId) external view returns (Settlement state, int256 value) {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        return _settlement(ATTESTATION, m.feedId, m.agent, m.expiry);
    }

    function getMarket(bytes32 marketId) external view returns (Market memory) {
        return _markets[marketId];
    }

    function priceOf(bytes32 marketId, Outcome outcome) external view returns (uint256) {
        Market memory m = _markets[marketId];
        uint256 total = m.yesReserve + m.noReserve;
        if (total == 0) return 0;
        uint256 other = outcome == Outcome.Yes ? m.noReserve : m.yesReserve;
        return (other * 1e18) / total;
    }
}
