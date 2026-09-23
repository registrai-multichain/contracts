// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";
import {NanoLedger} from "./NanoLedger.sol";
import {BuilderRegistry} from "../perennial/BuilderRegistry.sol";

/// @title MarketsPerennial. Builder-milestone prediction markets that fund a
///        shared commons.
/// @notice Same constant-product binary market as MarketsV4 (settled entirely on
///         NanoLedger), specialized for the Perennial funding model:
///           - each market is tagged to a `builderId` it is about;
///           - the per-trade fee uses a GOVERNABLE split (default creator 20 /
///             treasury 35 / agent 15 bps, total 70);
///           - the CREATOR leg pays whoever opened the market (incentive);
///           - the TREASURY leg routes to a `commons` address (the ProgressPool)
///             rather than to the builder the market is about, so attention fills
///             the commons but never captures it;
///           - the AGENT leg pays the bonded oracle that settles.
///         Fees are paid as direct ledger internalTransfers (value-independent,
///         no per-market pool, no source registration needed). Real USDC only
///         crosses at NanoLedger.deposit/withdraw. Oracle-resolved via Attestation.
contract MarketsPerennial is AccessControl, ReentrancyGuard {
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
        Resolved
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
    uint256 public constant FEE_BPS_TOTAL = 70;
    uint256 private constant BPS = 10_000;

    // governable split (must sum to FEE_BPS_TOTAL); defaults per spec.
    uint256 public creatorBps = 20;
    uint256 public treasuryBps = 35; // -> commons
    uint256 public agentBps = 15;
    address public commons; // ProgressPool / commons ledger account

    mapping(bytes32 => Market) internal _markets;
    mapping(bytes32 => mapping(address => uint256)) public yesBalance;
    mapping(bytes32 => mapping(address => uint256)) public noBalance;
    mapping(address => uint256) public createdBy;
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    mapping(bytes32 => uint256) public totalLpShares;
    mapping(bytes32 => uint256) public lpPotAtResolution;

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
    event FeeSplitSet(uint256 creatorBps, uint256 treasuryBps, uint256 agentBps);
    event CommonsSet(address commons);

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
    error AttestationNotFound();
    error AttestationNotFinalized();
    error BadSplit();
    error ZeroAddress();
    error BuilderInactive();

    constructor(
        NanoLedger ledger_,
        Registry registry_,
        Attestation attestation_,
        BuilderRegistry builders_,
        address admin,
        address commons_
    ) {
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
        uint256 fee = (collateralIn * FEE_BPS_TOTAL) / BPS;
        uint256 effectiveIn = collateralIn - fee;
        _payFees(marketId, m, fee);

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
        if (sharesOut < minSharesOut) revert SlippageExceeded();
        emit Bought(marketId, msg.sender, outcome, collateralIn, sharesOut, fee);
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
        uint256 grossOut = (sumAB - Math.sqrt(disc)) / 2;

        uint256 fee = (grossOut * FEE_BPS_TOTAL) / BPS;
        collateralOut = grossOut - fee;
        if (collateralOut < minCollateralOut) revert SlippageExceeded();

        m.yesReserve = yesPostSell - grossOut;
        m.noReserve = noPostSell - grossOut;

        _payFees(marketId, m, fee);
        if (collateralOut > 0) LEDGER.internalTransfer(msg.sender, collateralOut);
        emit Sold(marketId, msg.sender, outcome, sharesIn, collateralOut, fee);
    }

    /// @dev Split the fee three ways by the current governable bps and pay each
    /// leg as a direct internal transfer. Commons (treasury leg) goes to the
    /// shared pool, never to the builder the market is about. Remainder to
    /// commons so rounding never strands wei.
    function _payFees(bytes32 marketId, Market storage m, uint256 fee) internal {
        if (fee == 0) return;
        uint256 cFee = (fee * creatorBps) / FEE_BPS_TOTAL;
        uint256 aFee = (fee * agentBps) / FEE_BPS_TOTAL;
        uint256 tFee = fee - cFee - aFee; // commons gets the remainder
        if (cFee > 0) LEDGER.internalTransfer(m.creator, cFee);
        if (aFee > 0) LEDGER.internalTransfer(m.agent, aFee);
        if (tFee > 0) LEDGER.internalTransfer(commons, tFee);
        emit FeesPaid(marketId, cFee, tFee, aFee);
    }

    // ───────────────────────── resolve / claim ─────────────────────────

    function resolve(bytes32 marketId) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase == Phase.Resolved) revert AlreadyResolved();
        if (block.timestamp < m.expiry) revert MarketNotExpired();

        (int256 value, bool finalized) = ATTESTATION.valueAt(m.feedId, m.agent, m.expiry);
        if (value == 0 && !finalized) revert AttestationNotFound();
        if (!finalized) revert AttestationNotFinalized();

        bool yesWon = _evaluate(value, m.threshold, m.comparator);
        m.yesWon = yesWon;
        m.phase = Phase.Resolved;
        lpPotAtResolution[marketId] = yesWon ? m.yesReserve : m.noReserve;
        emit Resolved(marketId, yesWon, value);
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
        if (m.phase != Phase.Resolved) revert NotResolved();
        if (m.yesWon) {
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
        if (m.phase != Phase.Resolved) revert NotResolved();
        uint256 myShares = lpShares[marketId][msg.sender];
        if (myShares == 0) revert NoLPShares();
        payout = (myShares * lpPotAtResolution[marketId]) / totalLpShares[marketId];
        lpShares[marketId][msg.sender] = 0;
        if (payout > 0) LEDGER.internalTransfer(msg.sender, payout);
        emit LPClaimed(marketId, msg.sender, payout);
    }

    // ──────────────────────────── governor ────────────────────────────

    function setFeeSplit(uint256 creatorBps_, uint256 treasuryBps_, uint256 agentBps_)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        if (creatorBps_ + treasuryBps_ + agentBps_ != FEE_BPS_TOTAL) revert BadSplit();
        creatorBps = creatorBps_;
        treasuryBps = treasuryBps_;
        agentBps = agentBps_;
        emit FeeSplitSet(creatorBps_, treasuryBps_, agentBps_);
    }

    function setCommons(address commons_) external onlyRole(GOVERNOR_ROLE) {
        if (commons_ == address(0)) revert ZeroAddress();
        commons = commons_;
        emit CommonsSet(commons_);
    }

    // ───────────────────────────── views ─────────────────────────────

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
