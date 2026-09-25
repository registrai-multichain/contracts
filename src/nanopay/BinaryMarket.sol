// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";
import {NanoLedger} from "./NanoLedger.sol";
import {SettlementPolicy} from "./SettlementPolicy.sol";

/// @title BinaryMarket. The one binary-market engine behind MarketsPerennial and
/// MarketsV4: constant-product YES/NO trading, settlement on a bonded agent's
/// attestation, void, redemption and the LP claim — all on NanoLedger.
/// @notice Each market is a constant-product pool over YES and NO. A buy of
/// `collateralIn` pays the 1% trading fee, mints the rest as a full YES + NO set
/// and swaps it along the curve; a sell swaps shares back and burns a full set
/// (the gross curve amount), the seller receiving it less the fee. Trading
/// closes at expiry. Positions are not transferable: they exit through the
/// pool or at settlement.
///
/// Fees: TRADE_FEE_BPS of every trade, split 30% creator (paid now), 20% agent
/// (escrowed per market until it settles) and 50% to the contract's payee
/// (`_payFeeLegs`: the builder via the BuilderFund, or the treasury).
///
/// Settlement (SettlementPolicy): resolve pays 1 per winning share and the LP the
/// winning reserve (exactly C between them) and releases the escrow to the agent.
/// Void refunds every trader its net cost (pro rata when earlier sellers took more
/// profit than the LP seed), the LP the rest, and hands the escrow to the
/// successful challenger or the contract's sink (`_voidEscrow`).
///
/// Invariants while trading: YES supply == NO supply == collateralOf; the
/// contract's ledger balance == sum over markets of collateralOf + agentEscrow.
/// After settlement a market owes `unpaid` to `claimsLeft` claimants; once every
/// claimant has claimed, whatever rounding left behind is swept to the sink.
abstract contract BinaryMarket is AccessControl, ReentrancyGuard, SettlementPolicy {
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

    /// @dev The engine's view of a market. Each contract exposes its own
    /// `Market` struct through `getMarket`.
    struct Core {
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

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    uint256 public constant MIN_LIQUIDITY = 5e6;
    /// @notice Every market expires on this contract's grid (1 hour by default).
    /// The agent reads a feed once for all markets whose windows open together, as
    /// of their expiry; with expiries on a grid no finer than the agent's tick,
    /// markets on one feed that expire between two ticks share an expiry, so no
    /// market can be opened a moment before another to make the shared reading be
    /// taken as of the wrong time. A contract whose agent ticks faster overrides it.
    function EXPIRY_GRID() public pure virtual returns (uint256) {
        return 1 hours;
    }
    /// @notice The trading fee: 1% of every buy and every sell.
    uint256 public constant TRADE_FEE_BPS = 100;
    /// @notice Shares of each trading fee (of BPS); the payee takes the rest.
    uint256 public constant CREATOR_SHARE_BPS = 3000;
    uint256 public constant AGENT_SHARE_BPS = 2000;
    uint256 public constant BPS = 10_000;

    NanoLedger public immutable LEDGER;
    Registry public immutable REGISTRY;
    Attestation public immutable ATTESTATION;

    mapping(bytes32 => Core) internal _markets;
    mapping(bytes32 => mapping(address => uint256)) public yesBalance;
    mapping(bytes32 => mapping(address => uint256)) public noBalance;
    mapping(address => uint256) public createdBy;
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    mapping(bytes32 => uint256) public totalLpShares;
    /// @notice The LP's pot once settled: the winning reserve, or C less the
    /// traders' share on void.
    mapping(bytes32 => uint256) public lpPotAtResolution;

    /// @notice C: all collateral backing a market (== YES supply == NO supply).
    mapping(bytes32 => uint256) public collateralOf;
    /// @notice What a trader has put in after fees and not yet taken out (never
    /// below 0; the LP seed is not a trader cost).
    mapping(bytes32 => mapping(address => uint256)) public netCost;
    /// @notice Sum of every trader's netCost.
    mapping(bytes32 => uint256) public totalNetCost;
    /// @notice The agent's 20% of every trading fee, held until the market settles.
    mapping(bytes32 => uint256) public agentEscrow;
    /// @notice At void: what traders share, and the totalNetCost it is shared over.
    mapping(bytes32 => uint256) public voidTraderPool;
    mapping(bytes32 => uint256) public voidNetCostTotal;

    /// @notice After settlement: collateral still owed to claimants, and how many
    /// claimants (winning holders or refundable traders, plus the LP) have not
    /// claimed yet. When claimsLeft reaches 0, `unpaid` is rounding dust.
    mapping(bytes32 => uint256) public unpaid;
    mapping(bytes32 => uint256) public claimsLeft;

    /// @dev Holders with a nonzero YES / NO balance, and traders with a nonzero
    /// netCost, while trading: frozen into claimsLeft at settlement.
    mapping(bytes32 => uint256) internal _yesHolders;
    mapping(bytes32 => uint256) internal _noHolders;
    mapping(bytes32 => uint256) internal _costHolders;

    /// @notice Governor allowlist of dispute resolvers a market's feed may name.
    /// A feed's resolver is fixed at Registry.createFeed (no setter) and Dispute
    /// snapshots it per challenge, so checking it once at market creation is sound.
    mapping(address => bool) public approvedResolver;

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
    event Resolved(bytes32 indexed marketId, bool yesWon, int256 value);
    event Redeemed(bytes32 indexed marketId, address indexed holder, uint256 payout);
    event LPClaimed(bytes32 indexed marketId, address indexed lp, uint256 payout);
    event MarketVoided(bytes32 indexed marketId);
    event AgentFeeReleased(bytes32 indexed marketId, address indexed agent, uint256 amount);
    event ResolverApprovalSet(address indexed resolver, bool approved);
    event DustSwept(bytes32 indexed marketId, uint256 amount);

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
    error ExpiryOffGrid();
    error AgentNotRegistered();
    error SlippageExceeded();
    error InsufficientShares();
    error NoLPShares();
    error ZeroAddress();
    error ReserveDepleted();
    error ResolverNotApproved();
    error SelfResolvedFeed();
    error DeadlineExpired();
    error ClaimsOutstanding();
    error NothingToSweep();

    constructor(
        NanoLedger ledger_,
        Registry registry_,
        Attestation attestation_,
        address admin,
        uint256 settlementWindow_,
        uint256 resolutionGrace_
    ) SettlementPolicy(settlementWindow_, resolutionGrace_) {
        if (
            address(ledger_) == address(0) || address(registry_) == address(0)
                || address(attestation_) == address(0) || admin == address(0)
        ) revert ZeroAddress();
        LEDGER = ledger_;
        REGISTRY = registry_;
        ATTESTATION = attestation_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ───────────────────────────── hooks ─────────────────────────────

    /// @dev Pay the payee's leg of a trading fee and emit the contract's
    /// FeesPaid. The creator leg is already paid and the agent leg escrowed.
    function _payFeeLegs(bytes32 marketId, uint256 creatorFee, uint256 payeeFee, uint256 agentFee) internal virtual;

    /// @dev A voided market's escrow: to `challenger` when there is one, else to
    /// the contract's sink. Emits the contract's VoidFeesPaid.
    function _voidEscrow(bytes32 marketId, uint256 escrow, address challenger) internal virtual;

    /// @dev Where a settled market's rounding dust goes.
    function _sweepDust(uint256 amount) internal virtual;

    // ───────────────────────────── create ─────────────────────────────

    /// @dev Checks shared by every market, pulls the seed and stores the market.
    function _open(
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    ) internal returns (bytes32 marketId) {
        if (expiry <= block.timestamp) revert BadExpiry();
        if (expiry % EXPIRY_GRID() != 0) revert ExpiryOffGrid();
        if (liquidity < MIN_LIQUIDITY) revert LiquidityTooLow();
        if (!REGISTRY.isActiveAgent(feedId, agent)) revert AgentNotRegistered();
        _requireApprovedOracle(feedId, agent);
        _requireSettleableFeed(REGISTRY, feedId);

        uint256 nonce = createdBy[msg.sender]++;
        marketId = keccak256(abi.encode(msg.sender, nonce, feedId, agent, threshold, comparator, expiry));
        if (_markets[marketId].createdAt != 0) revert MarketExists();

        LEDGER.transferFromInternal(msg.sender, address(this), liquidity);

        _markets[marketId] = Core({
            feedId: feedId,
            agent: agent,
            threshold: threshold,
            comparator: comparator,
            expiry: expiry,
            creator: msg.sender,
            yesReserve: liquidity,
            noReserve: liquidity,
            phase: Phase.Trading,
            yesWon: false,
            createdAt: block.timestamp
        });
        lpShares[marketId][msg.sender] = liquidity;
        totalLpShares[marketId] = liquidity;
        collateralOf[marketId] = liquidity;
    }

    /// @dev Refuse a market whose feed names an unvetted dispute resolver, or its
    /// own agent as resolver (a feed it would attest AND adjudicate). Checked at
    /// creation only: the resolver cannot change afterwards, and revoking an
    /// approval must not strand open markets. Overridable to vet more.
    function _requireApprovedOracle(bytes32 feedId, address agent) internal view virtual {
        address resolver = REGISTRY.getFeed(feedId).resolver;
        if (!approvedResolver[resolver]) revert ResolverNotApproved();
        if (resolver == agent) revert SelfResolvedFeed();
    }

    // ───────────────────────────── trade ─────────────────────────────

    /// @notice Buy `outcome` with `collateralIn` of your ledger balance (approve
    /// this contract on the ledger first). Reverts past `deadline` or when fewer
    /// than `minSharesOut` shares would come out.
    function buy(bytes32 marketId, Outcome outcome, uint256 collateralIn, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        Core storage m = _trading(marketId);
        if (collateralIn == 0) revert LiquidityTooLow();
        LEDGER.transferFromInternal(msg.sender, address(this), collateralIn);

        uint256 fee;
        uint256 yesAfter;
        uint256 noAfter;
        (sharesOut, fee, yesAfter, noAfter) = _buyMath(m.yesReserve, m.noReserve, outcome, collateralIn);
        if (sharesOut == 0) revert AmountTooLow();
        if (yesAfter == 0 || noAfter == 0) revert ReserveDepleted();
        if (sharesOut < minSharesOut) revert SlippageExceeded();

        uint256 effectiveIn = collateralIn - fee;
        m.yesReserve = yesAfter;
        m.noReserve = noAfter;
        collateralOf[marketId] += effectiveIn;
        if (netCost[marketId][msg.sender] == 0) _costHolders[marketId]++;
        netCost[marketId][msg.sender] += effectiveIn;
        totalNetCost[marketId] += effectiveIn;
        if (outcome == Outcome.Yes) {
            if (yesBalance[marketId][msg.sender] == 0) _yesHolders[marketId]++;
            yesBalance[marketId][msg.sender] += sharesOut;
        } else {
            if (noBalance[marketId][msg.sender] == 0) _noHolders[marketId]++;
            noBalance[marketId][msg.sender] += sharesOut;
        }
        _chargeFee(marketId, m, fee);
        emit Bought(marketId, msg.sender, outcome, collateralIn, sharesOut, fee);
    }

    /// @notice Sell `sharesIn` of `outcome` back to the pool. Reverts past
    /// `deadline`, when less than `minCollateralOut` would come out, or when the
    /// curve would pay nothing for them.
    function sell(bytes32 marketId, Outcome outcome, uint256 sharesIn, uint256 minCollateralOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 collateralOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        Core storage m = _trading(marketId);
        if (sharesIn == 0) revert LiquidityTooLow();
        if (outcome == Outcome.Yes) {
            uint256 bal = yesBalance[marketId][msg.sender];
            if (bal < sharesIn) revert InsufficientShares();
            yesBalance[marketId][msg.sender] = bal - sharesIn;
            if (bal == sharesIn) _yesHolders[marketId]--;
        } else {
            uint256 bal = noBalance[marketId][msg.sender];
            if (bal < sharesIn) revert InsufficientShares();
            noBalance[marketId][msg.sender] = bal - sharesIn;
            if (bal == sharesIn) _noHolders[marketId]--;
        }

        uint256 grossOut;
        uint256 fee;
        uint256 yesAfter;
        uint256 noAfter;
        (grossOut, fee, yesAfter, noAfter) = _sellMath(m.yesReserve, m.noReserve, outcome, sharesIn);
        // Shares the curve values at 0 are not burned for nothing.
        if (grossOut == 0) revert AmountTooLow();
        if (yesAfter == 0 || noAfter == 0) revert ReserveDepleted();
        collateralOut = grossOut - fee; // >= 1: the fee floors to 0 below 100 units
        if (collateralOut < minCollateralOut) revert SlippageExceeded();

        m.yesReserve = yesAfter;
        m.noReserve = noAfter;
        _recordSell(marketId, grossOut);
        _chargeFee(marketId, m, fee);
        LEDGER.internalTransfer(msg.sender, collateralOut);
        emit Sold(marketId, msg.sender, outcome, sharesIn, collateralOut, fee);
    }

    /// @dev The buy curve: the fee comes off `collateralIn`, the rest mints a full
    /// YES + NO set, and the pool pays out the bought side down to k. Rounds the
    /// remaining reserve up, so k never decreases.
    function _buyMath(uint256 y, uint256 n, Outcome outcome, uint256 collateralIn)
        internal
        pure
        returns (uint256 sharesOut, uint256 fee, uint256 yesAfter, uint256 noAfter)
    {
        fee = (collateralIn * TRADE_FEE_BPS) / BPS;
        uint256 effectiveIn = collateralIn - fee;
        uint256 yesAfterMint = y + effectiveIn;
        uint256 noAfterMint = n + effectiveIn;
        uint256 k = y * n;
        if (outcome == Outcome.Yes) {
            yesAfter = Math.ceilDiv(k, noAfterMint);
            sharesOut = yesAfterMint - yesAfter;
            noAfter = noAfterMint;
        } else {
            noAfter = Math.ceilDiv(k, yesAfterMint);
            sharesOut = noAfterMint - noAfter;
            yesAfter = yesAfterMint;
        }
    }

    /// @dev The sell curve: the shares go into the pool, which burns `grossOut` of
    /// each side, solving (a - x)(b - x) = k. Rounds in the protocol's favour:
    /// ceiling the root and flooring the halving can only pay less, so k never
    /// decreases on a sell (a floored root could pay 1 unit over the curve).
    function _sellMath(uint256 y, uint256 n, Outcome outcome, uint256 sharesIn)
        internal
        pure
        returns (uint256 grossOut, uint256 fee, uint256 yesAfter, uint256 noAfter)
    {
        uint256 a = outcome == Outcome.Yes ? y + sharesIn : y;
        uint256 b = outcome == Outcome.No ? n + sharesIn : n;
        uint256 sum = a + b;
        uint256 disc = sum * sum - 4 * (a * b - y * n);
        grossOut = (sum - Math.sqrt(disc, Math.Rounding.Ceil)) / 2;
        fee = (grossOut * TRADE_FEE_BPS) / BPS;
        yesAfter = a - grossOut;
        noAfter = b - grossOut;
    }

    function _trading(bytes32 marketId) internal view returns (Core storage m) {
        m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert NotTrading();
        if (block.timestamp >= m.expiry) revert MarketExpired();
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
            if (d == nc) _costHolders[marketId]--;
        }
    }

    /// @dev Split one trading fee: creator 30% paid now, agent 20% escrowed for
    /// the market, the payee the rounding remainder (so no unit is stranded).
    function _chargeFee(bytes32 marketId, Core storage m, uint256 fee) internal {
        uint256 creatorFee = (fee * CREATOR_SHARE_BPS) / BPS;
        uint256 agentFee = (fee * AGENT_SHARE_BPS) / BPS;
        uint256 payeeFee = fee - creatorFee - agentFee;
        if (agentFee > 0) agentEscrow[marketId] += agentFee; // stays in this contract's ledger balance
        _pay(m.creator, creatorFee);
        _payFeeLegs(marketId, creatorFee, payeeFee, agentFee);
    }

    function _pay(address to, uint256 amount) internal {
        if (amount > 0) LEDGER.internalTransfer(to, amount);
    }

    // ───────────────────────── resolve / void ─────────────────────────

    /// @notice Settle a market on its agent's first valid reading after expiry.
    /// Anyone may call it once SettlementPolicy says Resolvable.
    function resolve(bytes32 marketId) external nonReentrant {
        Core storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert AlreadyResolved();
        if (block.timestamp < m.expiry) revert MarketNotExpired();

        (Settlement state, int256 value) = _settlement(ATTESTATION, m.feedId, m.agent, m.expiry);
        if (state != Settlement.Resolvable) revert SettlementPending();

        bool yesWon = _evaluate(value, m.threshold, m.comparator);
        m.yesWon = yesWon;
        m.phase = Phase.Resolved;

        lpPotAtResolution[marketId] = yesWon ? m.yesReserve : m.noReserve;
        unpaid[marketId] = collateralOf[marketId];
        claimsLeft[marketId] = (yesWon ? _yesHolders[marketId] : _noHolders[marketId]) + 1; // + the LP
        emit Resolved(marketId, yesWon, value);

        uint256 escrow = agentEscrow[marketId];
        if (escrow > 0) {
            agentEscrow[marketId] = 0;
            LEDGER.internalTransfer(m.agent, escrow);
        }
        emit AgentFeeReleased(marketId, m.agent, escrow);
    }

    /// @notice Close a market that can no longer be settled. Anyone may call it.
    /// @dev Nothing is charged. Traders share traderPool = min(totalNetCost, C),
    /// each pro rata to its net cost (so each gets its net cost back unless
    /// earlier sellers took more profit than the LP seed); the LP gets the rest.
    /// Solvent by construction: the payouts sum to at most C.
    function voidMarket(bytes32 marketId) external nonReentrant {
        Core storage m = _markets[marketId];
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
        unpaid[marketId] = c;
        claimsLeft[marketId] = _costHolders[marketId] + 1; // + the LP
        emit MarketVoided(marketId);

        uint256 escrow = agentEscrow[marketId];
        agentEscrow[marketId] = 0;
        _voidEscrow(marketId, escrow, _challengerOf(ATTESTATION, m.feedId, m.agent, m.expiry));
    }

    function _evaluate(int256 value, int256 threshold, Comparator c) internal pure returns (bool) {
        if (c == Comparator.GreaterThan) return value > threshold;
        if (c == Comparator.GreaterOrEqual) return value >= threshold;
        if (c == Comparator.LessThan) return value < threshold;
        return value <= threshold;
    }

    // ───────────────────────────── claims ─────────────────────────────

    /// @notice Collect a settled market: 1 per winning share, or your refund on
    /// void. Reverts for an address with nothing to claim.
    function redeem(bytes32 marketId) external nonReentrant returns (uint256 payout) {
        Core storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase == Phase.Trading) revert NotResolved();
        bool claimant = m.phase == Phase.Resolved
            ? (m.yesWon ? yesBalance[marketId][msg.sender] : noBalance[marketId][msg.sender]) > 0
            : netCost[marketId][msg.sender] > 0;
        if (!claimant) revert InsufficientShares();
        payout = _redeemable(marketId, m, msg.sender);
        yesBalance[marketId][msg.sender] = 0;
        noBalance[marketId][msg.sender] = 0;
        netCost[marketId][msg.sender] = 0;
        unpaid[marketId] -= payout;
        claimsLeft[marketId]--;
        _pay(msg.sender, payout); // a void refund may floor to 0 on a dust net cost
        emit Redeemed(marketId, msg.sender, payout);
    }

    /// @notice Collect the LP's pot of a settled market.
    function claimLP(bytes32 marketId) external nonReentrant returns (uint256 payout) {
        Core storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase == Phase.Trading) revert NotResolved();
        uint256 myShares = lpShares[marketId][msg.sender];
        if (myShares == 0) revert NoLPShares();
        payout = (myShares * lpPotAtResolution[marketId]) / totalLpShares[marketId];
        lpShares[marketId][msg.sender] = 0;
        unpaid[marketId] -= payout;
        claimsLeft[marketId]--;
        _pay(msg.sender, payout);
        emit LPClaimed(marketId, msg.sender, payout);
    }

    /// @notice Once every claimant of a settled market has claimed, move the
    /// rounding dust left behind to the contract's sink. Anyone may call it.
    function sweepDust(bytes32 marketId) external nonReentrant returns (uint256 amount) {
        Core storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase == Phase.Trading) revert NotResolved();
        if (claimsLeft[marketId] != 0) revert ClaimsOutstanding();
        amount = unpaid[marketId];
        if (amount == 0) revert NothingToSweep();
        unpaid[marketId] = 0;
        _sweepDust(amount);
        emit DustSwept(marketId, amount);
    }

    /// @dev Resolved: 1 per winning share. Voided: net cost
    /// * voidTraderPool / voidNetCostTotal. Trading: 0.
    function _redeemable(bytes32 marketId, Core storage m, address who) internal view returns (uint256) {
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
        Core storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        return _settlement(ATTESTATION, m.feedId, m.agent, m.expiry);
    }

    /// @notice What `buy(marketId, outcome, collateralIn, ...)` would give now:
    /// the shares and the fee. (0, 0) when the market is not trading, the amount
    /// is 0, or the buy would revert on the curve. Same math as `buy`.
    function quoteBuy(bytes32 marketId, Outcome outcome, uint256 collateralIn)
        external
        view
        returns (uint256 sharesOut, uint256 fee)
    {
        Core storage m = _markets[marketId];
        if (!_isTrading(m) || collateralIn == 0) return (0, 0);
        uint256 yesAfter;
        uint256 noAfter;
        (sharesOut, fee, yesAfter, noAfter) = _buyMath(m.yesReserve, m.noReserve, outcome, collateralIn);
        if (sharesOut == 0 || yesAfter == 0 || noAfter == 0) return (0, 0);
    }

    /// @notice What `sell(marketId, outcome, sharesIn, ...)` would pay now: the
    /// seller's collateral and the fee. (0, 0) when the market is not trading,
    /// the amount is 0, or the curve pays nothing (the sell would revert). Same
    /// math as `sell`; it does not check the caller's balance.
    function quoteSell(bytes32 marketId, Outcome outcome, uint256 sharesIn)
        external
        view
        returns (uint256 collateralOut, uint256 fee)
    {
        Core storage m = _markets[marketId];
        if (!_isTrading(m) || sharesIn == 0) return (0, 0);
        (uint256 grossOut, uint256 f, uint256 yesAfter, uint256 noAfter) =
            _sellMath(m.yesReserve, m.noReserve, outcome, sharesIn);
        if (grossOut == 0 || yesAfter == 0 || noAfter == 0) return (0, 0);
        return (grossOut - f, f);
    }

    function _isTrading(Core storage m) internal view returns (bool) {
        return m.createdAt != 0 && m.phase == Phase.Trading && block.timestamp < m.expiry;
    }

    function priceOf(bytes32 marketId, Outcome outcome) external view returns (uint256) {
        Core storage m = _markets[marketId];
        uint256 total = m.yesReserve + m.noReserve;
        if (total == 0) return 0;
        uint256 other = outcome == Outcome.Yes ? m.noReserve : m.yesReserve;
        return (other * 1e18) / total;
    }
}
