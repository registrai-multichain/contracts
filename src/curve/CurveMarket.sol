// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CurveMarket
/// @notice Parimutuel scalar forecast pools. Traders stake USDC on a bucket of
///         a normalized outcome range; on resolution the pot is split by how
///         close each bucket was, with a leverage-capped jackpot for the exact
///         bucket.
///
/// Ported from the Hedgents Solana program (`scarcity-exchange`), whose kernel
/// this reproduces exactly:
///
///   distance(b) = |b - winningBucket|
///   weight(b)   = bucketCount - distance(b)
///
/// Post-fee collateral is split into a jackpot for the exact bucket and an
/// accuracy pool distributed proportional to `stake * weight`. The jackpot is
/// capped at `exactStake * min(10, bucketCount - 1)` so that spraying dust
/// across every bucket cannot farm a fixed prize; any unused jackpot falls back
/// into the accuracy pool.
///
/// Two safety properties are carried over deliberately, because they are what
/// make the pool solvent:
///   1. Liabilities are computed from RECORDED STAKE, never from the token
///      balance, so an unsolicited transfer cannot inflate payouts.
///   2. `totalClaimed <= payoutPool` is enforced on every claim.
///
/// WHAT IS NEW HERE: the Solana version made positions non-transferable with no
/// secondary market. This contract adds an exit path, because a forecast you
/// cannot leave is a forecast you will not enter:
///
///   - while the market is OPEN   -> `withdraw` at par, no fee
///   - while it is CLOSED but unresolved -> `withdraw` is disabled, but
///     positions can be TRANSFERRED and SOLD through escrowed asks
///
/// That closed-but-unresolved window is the whole point. It is where the
/// outcome is still unknown, withdrawal is off, and a position genuinely has a
/// market price. Selling there is the only way out, so the contract provides it
/// natively rather than assuming an external orderbook exists.
contract CurveMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------ constants */

    uint8 public constant MIN_BUCKETS = 3;
    uint8 public constant MAX_BUCKETS = 41;
    /// Normalized outcome range is [-VALUE_SCALE, +VALUE_SCALE] == [-1, 1].
    int256 public constant VALUE_SCALE = 1_000_000;
    uint16 public constant MAX_JACKPOT_BPS = 5_000;
    uint16 public constant MAX_FEE_BPS = 500;
    uint8 public constant MAX_JACKPOT_LEVERAGE = 10;
    uint8 public constant KERNEL_VERSION = 1;
    /// After this long past `resolveAfter`, anyone may force the market invalid
    /// so stakes are refundable. It can never select an outcome.
    uint256 public constant RESOLVER_RECOVERY_DELAY = 7 days;

    /* ---------------------------------------------------------------- types */

    enum Status {
        Unresolved,
        Resolved,
        Invalid
    }

    struct Market {
        address creator;
        address resolver;
        address feeRecipient;
        uint64 opensAt;
        uint64 closesAt;
        uint64 resolveAfter;
        uint64 resolvedAt;
        bytes32 metricHash;
        bytes32 rulesHash;
        bytes32 resolutionReportHash;
        Status status;
        uint8 bucketCount;
        uint8 winningBucket;
        uint8 jackpotLeverageCap;
        uint16 jackpotBps;
        uint16 feeBps;
        int256 normalizedOutcome;
        uint256 totalStaked;
        uint256 protocolFee;
        uint256 payoutPool;
        uint256 jackpotPool;
        uint256 curvePool;
        uint256 exactStake;
        uint256 weightedStake;
        uint256 totalClaimed;
        uint256[MAX_BUCKETS] bucketStakes;
    }

    struct Listing {
        address seller;
        bytes32 marketId;
        uint8 bucket;
        uint256 stake;
        uint256 price;
        bool active;
    }

    /* -------------------------------------------------------------- storage */

    IERC20 public immutable collateral;

    mapping(bytes32 => Market) private _markets;
    /// marketId => bucket => owner => stake
    mapping(bytes32 => mapping(uint8 => mapping(address => uint256))) public stakeOf;
    /// marketId => bucket => owner => claimed
    mapping(bytes32 => mapping(uint8 => mapping(address => bool))) public claimed;
    /// owner => operator => approved (ERC-20-allowance-style, matching MarketsV3)
    mapping(address => mapping(address => bool)) public isOperator;

    mapping(bytes32 => Listing) public listings;

    /* --------------------------------------------------------------- events */

    event MarketCreated(
        bytes32 indexed marketId,
        address indexed creator,
        address resolver,
        uint8 bucketCount,
        uint16 jackpotBps,
        uint16 feeBps,
        uint64 opensAt,
        uint64 closesAt,
        uint64 resolveAfter
    );
    event Staked(bytes32 indexed marketId, address indexed owner, uint8 indexed bucket, uint256 amount, uint256 newStake);
    event Withdrawn(bytes32 indexed marketId, address indexed owner, uint8 indexed bucket, uint256 amount, uint256 newStake);
    event PositionTransferred(
        bytes32 indexed marketId, uint8 indexed bucket, address indexed from, address to, uint256 amount
    );
    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    event Listed(bytes32 indexed listingId, bytes32 indexed marketId, address indexed seller, uint8 bucket, uint256 stake, uint256 price);
    event ListingCancelled(bytes32 indexed listingId);
    event ListingFilled(bytes32 indexed listingId, address indexed buyer, uint256 stake, uint256 price);
    event Resolved(bytes32 indexed marketId, int256 normalizedOutcome, uint8 winningBucket, uint256 payoutPool, uint256 jackpotPool);
    event Invalidated(bytes32 indexed marketId);
    event Claimed(bytes32 indexed marketId, address indexed owner, uint8 indexed bucket, uint256 payout);

    /* --------------------------------------------------------------- errors */

    error MarketExists();
    error UnknownMarket();
    error InvalidBucketCount();
    error InvalidBucket();
    error InvalidSchedule();
    error InvalidCommitment();
    error JackpotTooHigh();
    error FeeTooHigh();
    error ZeroAmount();
    error ZeroAddress();
    error NotOpen();
    error NotClosedYet();
    error AlreadyResolved();
    error NotResolved();
    error MarketClosed();
    error InsufficientStake();
    error NotResolver();
    error TooEarly();
    error AlreadyClaimed();
    error PayoutExceedsLiability();
    error OutcomeOutOfRange();
    error NotSeller();
    error ListingInactive();
    error ListingExists();
    error NotAuthorized();

    constructor(address _collateral) {
        if (_collateral == address(0)) revert ZeroAddress();
        collateral = IERC20(_collateral);
    }

    /* ----------------------------------------------------------- view utils */

    function getMarket(bytes32 marketId)
        external
        view
        returns (
            Status status,
            uint8 bucketCount,
            uint8 winningBucket,
            uint256 totalStaked,
            uint256 payoutPool,
            uint64 opensAt,
            uint64 closesAt,
            uint64 resolveAfter,
            int256 normalizedOutcome
        )
    {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        return (
            m.status,
            m.bucketCount,
            m.winningBucket,
            m.totalStaked,
            m.payoutPool,
            m.opensAt,
            m.closesAt,
            m.resolveAfter,
            m.normalizedOutcome
        );
    }

    function bucketStakes(bytes32 marketId) external view returns (uint256[MAX_BUCKETS] memory) {
        return _markets[marketId].bucketStakes;
    }

    /// @notice Bucket a normalized value lands in. Ties round toward the higher
    ///         bucket, matching the Solana implementation exactly.
    function bucketForValue(int256 normalizedValue, uint8 bucketCount) public pure returns (uint8) {
        _validateBucketCount(bucketCount);
        if (normalizedValue < -VALUE_SCALE || normalizedValue > VALUE_SCALE) revert OutcomeOutOfRange();

        uint256 shifted = uint256(normalizedValue + VALUE_SCALE);
        uint256 intervals = uint256(bucketCount - 1);
        uint256 span = uint256(VALUE_SCALE * 2);
        // +span/2 gives round-half-up, i.e. exact midpoints go to the higher bucket.
        return uint8((shifted * intervals + span / 2) / span);
    }

    /// @notice Accuracy weight of a bucket given the winner. Full support: every
    ///         bucket earns something, closer earns more.
    function weightOf(uint8 bucket, uint8 winningBucket, uint8 bucketCount) public pure returns (uint256) {
        if (bucket >= bucketCount || winningBucket >= bucketCount) revert InvalidBucket();
        uint8 distance = bucket > winningBucket ? bucket - winningBucket : winningBucket - bucket;
        return uint256(bucketCount - distance);
    }

    /// @notice What a position would pay out right now. Zero until resolution.
    function previewPayout(bytes32 marketId, uint8 bucket, address owner) public view returns (uint256) {
        Market storage m = _markets[marketId];
        uint256 held = stakeOf[marketId][bucket][owner];
        if (held == 0 || claimed[marketId][bucket][owner]) return 0;

        if (m.status == Status.Invalid) return held;
        if (m.status != Status.Resolved) return 0;

        uint256 payout;
        if (m.weightedStake > 0) {
            uint256 w = weightOf(bucket, m.winningBucket, m.bucketCount);
            payout = (m.curvePool * (held * w)) / m.weightedStake;
        }
        if (bucket == m.winningBucket && m.exactStake > 0) {
            payout += (m.jackpotPool * held) / m.exactStake;
        }
        return payout;
    }

    /* --------------------------------------------------------- market setup */

    function createMarket(
        bytes32 marketId,
        bytes32 metricHash,
        bytes32 rulesHash,
        address resolver,
        address feeRecipient,
        uint8 bucketCount,
        uint16 jackpotBps,
        uint16 feeBps,
        uint64 opensAt,
        uint64 closesAt,
        uint64 resolveAfter
    ) external {
        if (marketId == bytes32(0)) revert InvalidCommitment();
        if (_markets[marketId].bucketCount != 0) revert MarketExists();
        if (metricHash == bytes32(0) || rulesHash == bytes32(0)) revert InvalidCommitment();
        if (resolver == address(0) || feeRecipient == address(0)) revert ZeroAddress();
        if (opensAt >= closesAt || closesAt > resolveAfter) revert InvalidSchedule();
        if (jackpotBps > MAX_JACKPOT_BPS) revert JackpotTooHigh();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        _validateBucketCount(bucketCount);

        Market storage m = _markets[marketId];
        m.creator = msg.sender;
        m.resolver = resolver;
        m.feeRecipient = feeRecipient;
        m.metricHash = metricHash;
        m.rulesHash = rulesHash;
        m.status = Status.Unresolved;
        m.bucketCount = bucketCount;
        m.winningBucket = type(uint8).max;
        m.jackpotBps = jackpotBps;
        m.feeBps = feeBps;
        m.jackpotLeverageCap = MAX_JACKPOT_LEVERAGE < bucketCount - 1 ? MAX_JACKPOT_LEVERAGE : bucketCount - 1;
        m.opensAt = opensAt;
        m.closesAt = closesAt;
        m.resolveAfter = resolveAfter;

        emit MarketCreated(
            marketId, msg.sender, resolver, bucketCount, jackpotBps, feeBps, opensAt, closesAt, resolveAfter
        );
    }

    /* ------------------------------------------------------------- staking */

    function stake(bytes32 marketId, uint8 bucket, uint256 amount) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        if (amount == 0) revert ZeroAmount();
        if (bucket >= m.bucketCount) revert InvalidBucket();
        _requireOpen(m);

        collateral.safeTransferFrom(msg.sender, address(this), amount);

        m.bucketStakes[bucket] += amount;
        m.totalStaked += amount;
        uint256 newStake = stakeOf[marketId][bucket][msg.sender] + amount;
        stakeOf[marketId][bucket][msg.sender] = newStake;

        emit Staked(marketId, msg.sender, bucket, amount, newStake);
    }

    /// @notice Exit at par while the market is still open. Free, no fee.
    /// @dev Disabled once `closesAt` passes — after that the only exit is a sale.
    function withdraw(bytes32 marketId, uint8 bucket, uint256 amount) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        if (amount == 0) revert ZeroAmount();
        _requireOpen(m);

        uint256 current = stakeOf[marketId][bucket][msg.sender];
        if (current < amount) revert InsufficientStake();

        unchecked {
            stakeOf[marketId][bucket][msg.sender] = current - amount;
            m.bucketStakes[bucket] -= amount;
            m.totalStaked -= amount;
        }
        collateral.safeTransfer(msg.sender, amount);

        emit Withdrawn(marketId, msg.sender, bucket, amount, current - amount);
    }

    /* ------------------------------------------- transfers & secondary sale */

    function setOperator(address operator, bool approved) external {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
    }

    /// @notice Move part of a position to another address.
    /// @dev Allowed right up to resolution — including the closed-but-unresolved
    ///      window, which is exactly when a position has a price and no other
    ///      exit. Bucket and market totals are untouched: only ownership moves,
    ///      so pool accounting and solvency are unaffected.
    function transferPosition(bytes32 marketId, uint8 bucket, address from, address to, uint256 amount)
        public
        nonReentrant
    {
        _transferPosition(marketId, bucket, from, to, amount);
    }

    function _transferPosition(bytes32 marketId, uint8 bucket, address from, address to, uint256 amount) internal {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        if (m.status != Status.Unresolved) revert AlreadyResolved();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (from != msg.sender && !isOperator[from][msg.sender]) revert NotAuthorized();
        if (claimed[marketId][bucket][from]) revert AlreadyClaimed();

        uint256 current = stakeOf[marketId][bucket][from];
        if (current < amount) revert InsufficientStake();

        unchecked {
            stakeOf[marketId][bucket][from] = current - amount;
        }
        stakeOf[marketId][bucket][to] += amount;

        emit PositionTransferred(marketId, bucket, from, to, amount);
    }

    /// @notice Offer part of a position for sale at a fixed USDC price.
    /// @dev The stake is escrowed into the contract's own book so it cannot be
    ///      double-sold or withdrawn out from under a buyer. Works both while
    ///      open and during the closed-but-unresolved window.
    function list(bytes32 listingId, bytes32 marketId, uint8 bucket, uint256 stakeAmount, uint256 price)
        external
        nonReentrant
    {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        if (m.status != Status.Unresolved) revert AlreadyResolved();
        if (listingId == bytes32(0)) revert InvalidCommitment();
        if (listings[listingId].seller != address(0)) revert ListingExists();
        if (stakeAmount == 0 || price == 0) revert ZeroAmount();
        if (claimed[marketId][bucket][msg.sender]) revert AlreadyClaimed();

        uint256 current = stakeOf[marketId][bucket][msg.sender];
        if (current < stakeAmount) revert InsufficientStake();

        // Escrow the stake in the contract itself.
        unchecked {
            stakeOf[marketId][bucket][msg.sender] = current - stakeAmount;
        }
        stakeOf[marketId][bucket][address(this)] += stakeAmount;

        listings[listingId] =
            Listing({seller: msg.sender, marketId: marketId, bucket: bucket, stake: stakeAmount, price: price, active: true});

        emit Listed(listingId, marketId, msg.sender, bucket, stakeAmount, price);
    }

    function cancelListing(bytes32 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingInactive();
        if (l.seller != msg.sender) revert NotSeller();

        l.active = false;
        unchecked {
            stakeOf[l.marketId][l.bucket][address(this)] -= l.stake;
        }
        stakeOf[l.marketId][l.bucket][msg.sender] += l.stake;

        emit ListingCancelled(listingId);
    }

    /// @notice Buy a listed position. Price is whatever the seller asked; this
    ///         contract expresses no opinion on what a position is worth.
    function buyListing(bytes32 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingInactive();
        Market storage m = _markets[l.marketId];
        // A sale after resolution would be a trade on a known outcome.
        if (m.status != Status.Unresolved) revert AlreadyResolved();

        l.active = false;
        collateral.safeTransferFrom(msg.sender, l.seller, l.price);

        unchecked {
            stakeOf[l.marketId][l.bucket][address(this)] -= l.stake;
        }
        stakeOf[l.marketId][l.bucket][msg.sender] += l.stake;

        emit ListingFilled(listingId, msg.sender, l.stake, l.price);
    }

    /* ------------------------------------------------------------ resolution */

    function resolve(bytes32 marketId, int256 normalizedOutcome, bytes32 resolutionReportHash) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        if (msg.sender != m.resolver) revert NotResolver();
        if (m.status != Status.Unresolved) revert AlreadyResolved();
        if (block.timestamp < m.resolveAfter) revert TooEarly();
        if (normalizedOutcome < -VALUE_SCALE || normalizedOutcome > VALUE_SCALE) revert OutcomeOutOfRange();

        uint8 winner = bucketForValue(normalizedOutcome, m.bucketCount);

        uint256 fee = (m.totalStaked * m.feeBps) / 10_000;
        uint256 postFee = m.totalStaked - fee;

        uint256 targetJackpot = (postFee * m.jackpotBps) / 10_000;
        uint256 exactStake = m.bucketStakes[winner];
        // Leverage cap: dust in the exact bucket cannot capture a fixed prize.
        uint256 jackpotCeiling = exactStake * m.jackpotLeverageCap;
        uint256 jackpot = targetJackpot < jackpotCeiling ? targetJackpot : jackpotCeiling;

        uint256 weighted;
        for (uint8 b = 0; b < m.bucketCount; ++b) {
            weighted += m.bucketStakes[b] * weightOf(b, winner, m.bucketCount);
        }

        m.status = Status.Resolved;
        m.resolvedAt = uint64(block.timestamp);
        m.normalizedOutcome = normalizedOutcome;
        m.winningBucket = winner;
        m.resolutionReportHash = resolutionReportHash;
        m.protocolFee = fee;
        m.exactStake = exactStake;
        m.weightedStake = weighted;
        m.jackpotPool = jackpot;
        // Unused jackpot falls back into the accuracy pool rather than stranding.
        m.curvePool = postFee - jackpot;
        m.payoutPool = postFee;

        if (fee > 0) collateral.safeTransfer(m.feeRecipient, fee);

        emit Resolved(marketId, normalizedOutcome, winner, m.payoutPool, jackpot);
    }

    /// @notice Void the market; every stake becomes refundable 1:1 and no fee is taken.
    function resolveInvalid(bytes32 marketId) external {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        if (msg.sender != m.resolver) revert NotResolver();
        if (m.status != Status.Unresolved) revert AlreadyResolved();
        _invalidate(m, marketId);
    }

    /// @notice If the resolver never acts, anyone may void the market after the
    ///         recovery delay. This can ONLY invalidate — it can never pick an
    ///         outcome, so a stalled resolver cannot be turned into a rug.
    function forceInvalid(bytes32 marketId) external {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        if (m.status != Status.Unresolved) revert AlreadyResolved();
        if (block.timestamp < uint256(m.resolveAfter) + RESOLVER_RECOVERY_DELAY) revert TooEarly();
        _invalidate(m, marketId);
    }

    function _invalidate(Market storage m, bytes32 marketId) internal {
        m.status = Status.Invalid;
        m.resolvedAt = uint64(block.timestamp);
        m.payoutPool = m.totalStaked;
        emit Invalidated(marketId);
    }

    /* ---------------------------------------------------------------- claim */

    function claim(bytes32 marketId, uint8 bucket) external nonReentrant returns (uint256 payout) {
        Market storage m = _markets[marketId];
        if (m.bucketCount == 0) revert UnknownMarket();
        if (m.status == Status.Unresolved) revert NotResolved();
        if (claimed[marketId][bucket][msg.sender]) revert AlreadyClaimed();

        payout = previewPayout(marketId, bucket, msg.sender);
        claimed[marketId][bucket][msg.sender] = true;

        uint256 newTotal = m.totalClaimed + payout;
        // Liabilities come from recorded stake, never the token balance.
        if (newTotal > m.payoutPool) revert PayoutExceedsLiability();
        m.totalClaimed = newTotal;

        if (payout > 0) collateral.safeTransfer(msg.sender, payout);
        emit Claimed(marketId, msg.sender, bucket, payout);
    }

    /* ------------------------------------------------------------ internals */

    function _requireOpen(Market storage m) internal view {
        if (m.status != Status.Unresolved) revert AlreadyResolved();
        if (block.timestamp < m.opensAt) revert NotOpen();
        if (block.timestamp >= m.closesAt) revert MarketClosed();
    }

    function _validateBucketCount(uint8 bucketCount) internal pure {
        // Odd so that zero always has a canonical centre bucket.
        if (bucketCount < MIN_BUCKETS || bucketCount > MAX_BUCKETS || bucketCount % 2 == 0) {
            revert InvalidBucketCount();
        }
    }
}
