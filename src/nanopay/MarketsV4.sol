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
/// @notice Same constant-product AMM as Markets, but ALL value moves as
///         NanoLedger internal-balance accounting instead of ERC20 transfers:
///           - collateral in: ledger.transferFromInternal(trader -> this)
///           - collateral out / payouts: ledger.internalTransfer(this -> trader)
///           - the per-trade fee: ONE ledger.accrue(marketId, fee) write that
///             distributes to creator/treasury by share; recipients claim
///             lazily via ledger.claim(marketId). The agent's cut is NOT in the
///             pool (a pool is claimable at any time, so an agent that never
///             settled would still be paid): it is escrowed per market and
///             released on resolve, or forfeited to FORFEIT_SINK on void.
///         So a trade does zero ERC20 transfers and one fee write instead of
///         three pushes, and traders/creators just hold ledger balances. Real
///         USDC only crosses at NanoLedger.deposit/withdraw. Settlement rules —
///         which attestation decides a market, and when it voids instead — live
///         in SettlementPolicy, shared with MarketsPerennial.
///
/// MarketsV4 must be registered as a NanoLedger source (setSource) so it can
/// create + credit fee pools. Traders approve MarketsV4 on the ledger
/// (approveSpender) before trading.
///
/// Governance is limited to the oracle allowlist (GOVERNOR_ROLE): which agents
/// and dispute resolvers a new market may settle on. Fees, treasury and the
/// forfeit sink stay immutable.
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
    address public immutable TREASURY;
    /// @notice Receives a voided market's escrowed agent fee. Immutable; must not
    /// be protocol revenue, or the penalty is void.
    address public immutable FORFEIT_SINK;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    uint256 public constant MIN_LIQUIDITY = 5e6;
    uint256 public constant FEE_BPS_CREATOR = 40;
    uint256 public constant FEE_BPS_AGENT = 20;
    uint256 public constant FEE_BPS_TREASURY = 10;
    uint256 public constant FEE_BPS_TOTAL = 70;
    uint256 private constant BPS = 10_000;

    mapping(bytes32 => Market) internal _markets;
    mapping(bytes32 => mapping(address => uint256)) public yesBalance;
    mapping(bytes32 => mapping(address => uint256)) public noBalance;
    mapping(address => uint256) public createdBy;
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    mapping(bytes32 => uint256) public totalLpShares;
    mapping(bytes32 => uint256) public lpPotAtResolution;
    /// @notice Agent-cut fees held until the market settles.
    mapping(bytes32 => uint256) public agentEscrow;
    /// @notice Governor allowlist of bonded agents a market may settle on.
    mapping(address => bool) public approvedAgent;
    /// @notice Governor allowlist of dispute resolvers a market's feed may name.
    /// A feed's resolver is fixed at Registry.createFeed (no setter) and Dispute
    /// snapshots it per challenge, so checking it once at market creation is sound.
    mapping(address => bool) public approvedResolver;

    event MarketCreated(bytes32 indexed marketId, address indexed creator, bytes32 indexed feedId, address agent, int256 threshold, Comparator comparator, uint256 expiry, uint256 liquidity);
    event Bought(bytes32 indexed marketId, address indexed buyer, Outcome outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee);
    event Sold(bytes32 indexed marketId, address indexed seller, Outcome outcome, uint256 sharesIn, uint256 collateralOut, uint256 fee);
    event Resolved(bytes32 indexed marketId, bool yesWon, int256 value);
    event Redeemed(bytes32 indexed marketId, address indexed holder, uint256 payout);
    event LPClaimed(bytes32 indexed marketId, address indexed lp, uint256 payout);
    event MarketVoided(bytes32 indexed marketId);
    event AgentFeeReleased(bytes32 indexed marketId, address indexed agent, uint256 amount);
    event AgentFeeForfeited(bytes32 indexed marketId, address indexed sink, uint256 amount);
    event AgentApprovalSet(address indexed agent, bool approved);
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
    error AgentNotApproved();
    error ResolverNotApproved();

    constructor(
        NanoLedger ledger_,
        Registry registry_,
        Attestation attestation_,
        address admin,
        address treasury_,
        address forfeitSink_,
        uint256 settlementWindow_,
        uint256 resolutionGrace_
    ) SettlementPolicy(settlementWindow_, resolutionGrace_) {
        if (treasury_ == address(0)) revert AmountTooLow();
        if (forfeitSink_ == address(0) || admin == address(0)) revert ZeroAddress();
        FORFEIT_SINK = forfeitSink_;
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

        // fee pool: creator 40 / treasury 10 bps, deduped by address. The agent's
        // 20 is escrowed instead (see _chargeFee).
        LEDGER.createPool(marketId);
        _setFeeShares(marketId, msg.sender);

        emit MarketCreated(marketId, msg.sender, feedId, agent, threshold, comparator, expiry, liquidity);
    }

    /// @dev Refuse a market whose oracle the governor has not vetted: both the
    /// agent that attests and the resolver that adjudicates disputes on its feed.
    /// Without this, anyone could open a market on a feed where they are agent
    /// AND resolver and settle it however they like. Checked at creation only:
    /// the feed's resolver cannot change afterwards, and revoking an approval
    /// must not strand markets already open (they settle or void as before).
    function _requireApprovedOracle(bytes32 feedId, address agent) internal view {
        if (!approvedAgent[agent]) revert AgentNotApproved();
        if (!approvedResolver[REGISTRY.getFeed(feedId).resolver]) revert ResolverNotApproved();
    }

    function _setFeeShares(bytes32 marketId, address creator) internal {
        if (creator == TREASURY) {
            LEDGER.setShares(marketId, creator, FEE_BPS_CREATOR + FEE_BPS_TREASURY);
        } else {
            LEDGER.setShares(marketId, creator, FEE_BPS_CREATOR);
            LEDGER.setShares(marketId, TREASURY, FEE_BPS_TREASURY);
        }
    }

    /// @dev Escrow the agent's cut, pool the rest. Pool shares are 40:10, so
    /// pooling the remainder pays creator and treasury exactly their bps of the
    /// whole fee.
    function _chargeFee(bytes32 marketId, uint256 fee) internal {
        if (fee == 0) return;
        uint256 aFee = (fee * FEE_BPS_AGENT) / FEE_BPS_TOTAL;
        if (aFee > 0) agentEscrow[marketId] += aFee;
        uint256 pooled = fee - aFee;
        if (pooled > 0) LEDGER.accrue(marketId, pooled);
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

        // pull full collateral into this market's ledger account, then skim fee
        LEDGER.transferFromInternal(msg.sender, address(this), collateralIn);
        uint256 fee = (collateralIn * FEE_BPS_TOTAL) / BPS;
        uint256 effectiveIn = collateralIn - fee;
        _chargeFee(marketId, fee);

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

        uint256 fee = (grossOut * FEE_BPS_TOTAL) / BPS;
        collateralOut = grossOut - fee;
        if (collateralOut < minCollateralOut) revert SlippageExceeded();

        m.yesReserve = yesPostSell - grossOut;
        m.noReserve = noPostSell - grossOut;
        if (m.yesReserve == 0 || m.noReserve == 0) revert ReserveDepleted();

        _chargeFee(marketId, fee);
        if (collateralOut > 0) LEDGER.internalTransfer(msg.sender, collateralOut);
        emit Sold(marketId, msg.sender, outcome, sharesIn, collateralOut, fee);
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

        uint256 fee = agentEscrow[marketId];
        if (fee > 0) {
            agentEscrow[marketId] = 0;
            LEDGER.internalTransfer(m.agent, fee);
            emit AgentFeeReleased(marketId, m.agent, fee);
        }
    }

    /// @notice Close a market that can no longer be settled. Anyone may call it.
    /// @dev Half a unit per YES and per NO share; LPs share half the combined
    /// reserves. Solvent by construction (each side's supply equals the
    /// collateral held). The escrowed agent fee is forfeited to FORFEIT_SINK.
    function voidMarket(bytes32 marketId) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert AlreadyResolved();
        (Settlement state,) = _settlement(ATTESTATION, m.feedId, m.agent, m.expiry);
        if (state != Settlement.Voidable) revert NotVoidable();

        m.phase = Phase.Voided;
        lpPotAtResolution[marketId] = (m.yesReserve + m.noReserve) / 2;
        emit MarketVoided(marketId);

        uint256 fee = agentEscrow[marketId];
        if (fee > 0) {
            agentEscrow[marketId] = 0;
            LEDGER.internalTransfer(FORFEIT_SINK, fee);
            emit AgentFeeForfeited(marketId, FORFEIT_SINK, fee);
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
        if (m.phase == Phase.Voided) {
            payout = (yesBalance[marketId][msg.sender] + noBalance[marketId][msg.sender]) / 2;
            yesBalance[marketId][msg.sender] = 0;
            noBalance[marketId][msg.sender] = 0;
        } else if (m.yesWon) {
            payout = yesBalance[marketId][msg.sender];
            yesBalance[marketId][msg.sender] = 0;
        } else {
            payout = noBalance[marketId][msg.sender];
            noBalance[marketId][msg.sender] = 0;
        }
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

    // ──────────────────────────── governor ────────────────────────────

    function setApprovedAgent(address agent, bool approved) external onlyRole(GOVERNOR_ROLE) {
        if (agent == address(0)) revert ZeroAddress();
        approvedAgent[agent] = approved;
        emit AgentApprovalSet(agent, approved);
    }

    function setApprovedResolver(address resolver, bool approved) external onlyRole(GOVERNOR_ROLE) {
        if (resolver == address(0)) revert ZeroAddress();
        approvedResolver[resolver] = approved;
        emit ResolverApprovalSet(resolver, approved);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice True when a market on `feedId` settled by `agent` passes the oracle
    /// allowlist: the feed exists, the agent is approved, and the feed's resolver
    /// is approved. (createMarket additionally needs the agent registered and
    /// active on the feed and a settleable dispute window.)
    function isApprovedFeed(bytes32 feedId, address agent) external view returns (bool) {
        Registry.Feed memory f = REGISTRY.getFeed(feedId);
        return f.exists && approvedAgent[agent] && approvedResolver[f.resolver];
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
