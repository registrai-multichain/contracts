// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";
import {NanoLedger} from "./NanoLedger.sol";
import {BuilderRegistry} from "../perennial/BuilderRegistry.sol";
import {SettlementPolicy} from "./SettlementPolicy.sol";

/// @title MarketsPerennial. Builder-milestone prediction markets that fund a
///        shared commons.
/// @notice Same constant-product binary market as MarketsV4 (settled entirely on
///         NanoLedger), specialized for the Perennial funding model. Each market
///         is tagged to a `builderId` it is about.
///
///         Fees: NO per-trade fee. One resolution fee of RESOLUTION_FEE_BPS (1%)
///         of the market's collateral pot C, charged once at settlement and paid
///         immediately as ledger internalTransfers:
///           - 30% to whoever opened the market (CREATOR_SHARE_BPS);
///           - 20% to the bonded agent that settled it (AGENT_SHARE_BPS);
///           - 50% to the `commons` (the ProgressPool), never to the builder the
///             market is about, so attention fills the commons but never
///             captures it (COMMONS_SHARE_BPS, takes the rounding remainder).
///         Winners redeem shares * (C - fee) / C; the LP gets its reserve on the
///         same terms.
///
///         Void: a market that cannot be settled voids (SettlementPolicy). The
///         same 1% is charged; its 20% agent leg goes to the challenger who got
///         the agent's reading ruled Invalid, else to the commons. Every trader
///         is refunded its net cost minus 1% (pro rata only if earlier sellers
///         took profits larger than the LP seed); the LP gets the rest.
///
///         Accounting invariant while trading: YES supply == NO supply ==
///         collateralOf == this market's share of the contract's ledger balance.
///         Real USDC only crosses at NanoLedger.deposit/withdraw.
contract MarketsPerennial is AccessControl, ReentrancyGuard, SettlementPolicy {
    enum Outcome {
        Yes,
        No
    }
    enum Comparator {
        GreaterThan,
        GreaterOrEqual,
        LessThan,
        LessOrEqual
    }
    enum Phase {
        Trading,
        Resolved,
        Voided
    }

    struct Market {
        bytes32 feedId;
        address agent;
        int256 threshold;
        Comparator comparator;
        uint256 expiry;
        address creator;
        uint256 builderId;
        uint256 yesReserve;
        uint256 noReserve;
        Phase phase;
        bool yesWon;
        uint256 createdAt;
    }

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    NanoLedger public immutable LEDGER;
    Registry public immutable REGISTRY;
    Attestation public immutable ATTESTATION;
    BuilderRegistry public immutable BUILDERS;

    uint256 public constant MIN_LIQUIDITY = 5e6;
    /// @notice The resolution fee: 1% of the market's collateral pot, once.
    uint256 public constant RESOLUTION_FEE_BPS = 100;
    /// @notice Shares of the resolution fee (of BPS). The agent's 20% becomes the
    /// challenger reward on void; the commons takes the rounding remainder.
    uint256 public constant CREATOR_SHARE_BPS = 3000;
    uint256 public constant AGENT_SHARE_BPS = 2000;
    uint256 public constant COMMONS_SHARE_BPS = 5000;
    uint256 public constant BPS = 10_000;

    /// @notice The commons (ProgressPool) ledger account. Immutable.
    address public immutable commons;

    mapping(bytes32 => Market) internal _markets;
    mapping(bytes32 => mapping(address => uint256)) public yesBalance;
    mapping(bytes32 => mapping(address => uint256)) public noBalance;
    mapping(address => uint256) public createdBy;
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    mapping(bytes32 => uint256) public totalLpShares;
    mapping(bytes32 => uint256) public lpPotAtResolution;

    /// @notice C: all collateral backing a market (== YES supply == NO supply).
    mapping(bytes32 => uint256) public collateralOf;
    /// @notice What a trader has put in and not yet taken out (never below 0;
    /// the LP seed is not a trader cost).
    mapping(bytes32 => mapping(address => uint256)) public netCost;
    /// @notice Sum of every trader's netCost.
    mapping(bytes32 => uint256) public totalNetCost;
    /// @notice At resolve: C, and C minus the resolution fee. Winners redeem
    /// shares * settledNet / settledGross.
    mapping(bytes32 => uint256) public settledGross;
    mapping(bytes32 => uint256) public settledNet;
    /// @notice At void: what traders share (net cost minus 1%, capped by what the
    /// market holds), and the totalNetCost it is shared over.
    mapping(bytes32 => uint256) public voidTraderPool;
    mapping(bytes32 => uint256) public voidNetCostTotal;

    /// @notice Governor allowlist of bonded agents a market may settle on.
    mapping(address => bool) public approvedAgent;
    /// @notice Governor allowlist of dispute resolvers a market's feed may name.
    /// A feed's resolver is fixed at Registry.createFeed (no setter) and Dispute
    /// snapshots it per challenge, so checking it once at market creation is sound.
    mapping(address => bool) public approvedResolver;

    event MarketCreated(
        bytes32 indexed marketId,
        uint256 indexed builderId,
        address indexed creator,
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry
    );
    event Bought(
        bytes32 indexed marketId,
        address indexed buyer,
        Outcome outcome,
        uint256 collateralIn,
        uint256 sharesOut,
        uint256 fee
    );
    event Sold(
        bytes32 indexed marketId,
        address indexed seller,
        Outcome outcome,
        uint256 sharesIn,
        uint256 collateralOut,
        uint256 fee
    );
    event FeesPaid(bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 agentFee);
    event Resolved(bytes32 indexed marketId, bool yesWon, int256 value);
    event Redeemed(bytes32 indexed marketId, address indexed holder, uint256 payout);
    event LPClaimed(bytes32 indexed marketId, address indexed lp, uint256 payout);
    event MarketVoided(bytes32 indexed marketId);
    event VoidFeesPaid(
        bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 challengerReward, address challenger
    );
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
    error BuilderInactive();
    error AgentNotApproved();
    error ResolverNotApproved();
    error SelfResolvedFeed();

    constructor(
        NanoLedger ledger_,
        Registry registry_,
        Attestation attestation_,
        BuilderRegistry builders_,
        address admin,
        address commons_,
        uint256 settlementWindow_,
        uint256 resolutionGrace_
    ) SettlementPolicy(settlementWindow_, resolutionGrace_) {
        if (address(builders_) == address(0) || admin == address(0) || commons_ == address(0)) revert ZeroAddress();
        LEDGER = ledger_;
        REGISTRY = registry_;
        ATTESTATION = attestation_;
        BUILDERS = builders_;
        commons = commons_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ───────────────────────────── create ─────────────────────────────

    function createMarket(
        uint256 builderId,
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    ) external nonReentrant returns (bytes32 marketId) {
        if (expiry <= block.timestamp) revert BadExpiry();
        if (liquidity < MIN_LIQUIDITY) revert LiquidityTooLow();
        if (!BUILDERS.isActiveBuilderId(builderId)) revert BuilderInactive();
        if (!REGISTRY.isActiveAgent(feedId, agent)) revert AgentNotRegistered();
        _requireApprovedOracle(feedId, agent);
        _requireSettleableFeed(REGISTRY, feedId);

        uint256 nonce = createdBy[msg.sender]++;
        marketId = keccak256(abi.encode(msg.sender, nonce, feedId, agent, threshold, comparator, expiry));
        if (_markets[marketId].createdAt != 0) revert MarketExists();

        LEDGER.transferFromInternal(msg.sender, address(this), liquidity);

        _markets[marketId] = Market({
            feedId: feedId,
            agent: agent,
            threshold: threshold,
            comparator: comparator,
            expiry: expiry,
            creator: msg.sender,
            builderId: builderId,
            yesReserve: liquidity,
            noReserve: liquidity,
            phase: Phase.Trading,
            yesWon: false,
            createdAt: block.timestamp
        });
        lpShares[marketId][msg.sender] = liquidity;
        totalLpShares[marketId] = liquidity;
        collateralOf[marketId] = liquidity;

        emit MarketCreated(marketId, builderId, msg.sender, feedId, agent, threshold, comparator, expiry);
    }

    // ───────────────────────────── trade ─────────────────────────────

    function buy(bytes32 marketId, Outcome outcome, uint256 collateralIn, uint256 minSharesOut)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert NotTrading();
        if (block.timestamp >= m.expiry) revert MarketExpired();
        if (collateralIn == 0) revert LiquidityTooLow();

        LEDGER.transferFromInternal(msg.sender, address(this), collateralIn);
        collateralOf[marketId] += collateralIn;
        netCost[marketId][msg.sender] += collateralIn;
        totalNetCost[marketId] += collateralIn;

        // no trading fee: the whole deposit mints a full YES + NO set
        uint256 yesAfterMint = m.yesReserve + collateralIn;
        uint256 noAfterMint = m.noReserve + collateralIn;
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
        emit Bought(marketId, msg.sender, outcome, collateralIn, sharesOut, 0);
    }

    function sell(bytes32 marketId, Outcome outcome, uint256 sharesIn, uint256 minCollateralOut)
        external
        nonReentrant
        returns (uint256 collateralOut)
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
        collateralOut = (sumAB - Math.sqrt(disc, Math.Rounding.Ceil)) / 2;
        if (collateralOut < minCollateralOut) revert SlippageExceeded();

        m.yesReserve = yesPostSell - collateralOut;
        m.noReserve = noPostSell - collateralOut;
        if (m.yesReserve == 0 || m.noReserve == 0) revert ReserveDepleted();

        _recordSell(marketId, collateralOut);
        if (collateralOut > 0) LEDGER.internalTransfer(msg.sender, collateralOut);
        emit Sold(marketId, msg.sender, outcome, sharesIn, collateralOut, 0);
    }

    /// @dev A sell burns `out` of each side, so C falls by `out`. The seller's net
    /// cost falls by at most what it still has in: a profit beyond it is not a
    /// negative cost.
    function _recordSell(bytes32 marketId, uint256 out) internal {
        collateralOf[marketId] -= out;
        uint256 nc = netCost[marketId][msg.sender];
        uint256 d = out < nc ? out : nc;
        if (d > 0) {
            netCost[marketId][msg.sender] = nc - d;
            totalNetCost[marketId] -= d;
        }
    }

    /// @dev The resolution fee on C: 30% creator, 20% agent leg, commons the
    /// remainder (so rounding never strands a unit).
    function _feeLegs(uint256 c)
        internal
        pure
        returns (uint256 fee, uint256 creatorFee, uint256 agentFee, uint256 commonsFee)
    {
        fee = (c * RESOLUTION_FEE_BPS) / BPS;
        creatorFee = (fee * CREATOR_SHARE_BPS) / BPS;
        agentFee = (fee * AGENT_SHARE_BPS) / BPS;
        commonsFee = fee - creatorFee - agentFee;
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

        uint256 c = collateralOf[marketId];
        (uint256 fee, uint256 creatorFee, uint256 agentFee, uint256 commonsFee) = _feeLegs(c);
        uint256 net = c - fee;
        settledGross[marketId] = c;
        settledNet[marketId] = net;
        lpPotAtResolution[marketId] = ((yesWon ? m.yesReserve : m.noReserve) * net) / c;
        emit Resolved(marketId, yesWon, value);

        _pay(m.creator, creatorFee);
        _pay(m.agent, agentFee);
        _pay(commons, commonsFee);
        emit FeesPaid(marketId, creatorFee, commonsFee, agentFee);
    }

    /// @notice Close a market that can no longer be settled. Anyone may call it.
    /// @dev The 1% fee is still charged: creator 30%, commons 50%, and the agent's
    /// 20% goes to the challenger that got the agent's reading ruled Invalid in
    /// the settlement window (else to the commons). Traders then share
    /// traderPool = min(totalNetCost * 99%, C - fee), each pro rata to its net
    /// cost; the LP gets what is left. Solvent by construction: the payouts sum
    /// to at most C - fee, which is what the market holds after the fee.
    function voidMarket(bytes32 marketId) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert AlreadyResolved();
        (Settlement state,) = _settlement(ATTESTATION, m.feedId, m.agent, m.expiry);
        if (state != Settlement.Voidable) revert NotVoidable();

        m.phase = Phase.Voided;
        uint256 c = collateralOf[marketId];
        (uint256 fee, uint256 creatorFee, uint256 agentFee, uint256 commonsFee) = _feeLegs(c);
        uint256 avail = c - fee;
        uint256 tnc = totalNetCost[marketId];
        uint256 traderPool = (tnc * (BPS - RESOLUTION_FEE_BPS)) / BPS;
        if (traderPool > avail) traderPool = avail;
        voidTraderPool[marketId] = traderPool;
        voidNetCostTotal[marketId] = tnc;
        lpPotAtResolution[marketId] = avail - traderPool;
        emit MarketVoided(marketId);

        address challenger = _challengerOf(ATTESTATION, m.feedId, m.agent, m.expiry);
        if (challenger == address(0)) commonsFee += agentFee;
        _pay(m.creator, creatorFee);
        _pay(commons, commonsFee);
        if (challenger != address(0)) _pay(challenger, agentFee);
        emit VoidFeesPaid(marketId, creatorFee, commonsFee, challenger == address(0) ? 0 : agentFee, challenger);
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

    /// @dev Resolved: winning shares * settledNet / settledGross. Voided: net cost
    /// * voidTraderPool / voidNetCostTotal. Trading: 0.
    function _redeemable(bytes32 marketId, Market storage m, address who) internal view returns (uint256) {
        if (m.phase == Phase.Resolved) {
            uint256 shares = m.yesWon ? yesBalance[marketId][who] : noBalance[marketId][who];
            return (shares * settledNet[marketId]) / settledGross[marketId];
        }
        if (m.phase == Phase.Voided) {
            uint256 total = voidNetCostTotal[marketId];
            if (total == 0) return 0;
            return (netCost[marketId][who] * voidTraderPool[marketId]) / total;
        }
        return 0;
    }

    /// @dev Refuse a market whose oracle the governor has not vetted: both the
    /// agent that attests and the resolver that adjudicates disputes on its feed.
    /// Without this, anyone could open a market on a feed where they are agent
    /// AND resolver and settle it however they like. Checked at creation only:
    /// the feed's resolver cannot change afterwards, and revoking an approval
    /// must not strand markets already open (they settle or void as before).
    function _requireApprovedOracle(bytes32 feedId, address agent) internal view {
        if (!approvedAgent[agent]) revert AgentNotApproved();
        address resolver = REGISTRY.getFeed(feedId).resolver;
        if (!approvedResolver[resolver]) revert ResolverNotApproved();
        // Both lists are vetted separately, so one address approved on both would
        // otherwise pass on a feed it attests AND adjudicates: the self-resolved
        // oracle this allowlist exists to refuse. The pairing is checked here, not
        // only in the deploy script, because approvals change after deploy.
        if (resolver == agent) revert SelfResolvedFeed();
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
    /// active on the feed, a settleable dispute window, and an active builder.)
    function isApprovedFeed(bytes32 feedId, address agent) external view returns (bool) {
        Registry.Feed memory f = REGISTRY.getFeed(feedId);
        return f.exists && approvedAgent[agent] && approvedResolver[f.resolver] && f.resolver != agent;
    }

    function getMarket(bytes32 marketId) external view returns (Market memory) {
        return _markets[marketId];
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
    /// it is resolvable. The keeper's single source of truth for what to do next.
    function settlementState(bytes32 marketId) external view returns (Settlement state, int256 value) {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        return _settlement(ATTESTATION, m.feedId, m.agent, m.expiry);
    }

    function priceOf(bytes32 marketId, Outcome outcome) external view returns (uint256) {
        Market memory m = _markets[marketId];
        uint256 total = m.yesReserve + m.noReserve;
        if (total == 0) return 0;
        uint256 other = outcome == Outcome.Yes ? m.noReserve : m.yesReserve;
        return (other * 1e18) / total;
    }
}
