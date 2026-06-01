// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarketsV3} from "./MarketsV3.sol";
import {Markets} from "./Markets.sol";

/// @title CirqueBetLending
/// @notice Borrow USDC against a prediction-market position you already hold.
///         The "dead capital → liquid" primitive: a YES/NO position is locked
///         in mid-bet, USDC is lent against its live AMM mark, and the position
///         is returned on repay. Only possible on a protocol that owns the
///         markets layer — MarketsV3's share-transfer primitive lets this
///         contract custody the collateral.
///
/// THE CLIFF-PAYOFF PROBLEM (and how this contract avoids it):
///   A YES share trades at, say, 60¢ on the AMM but resolves to exactly $1 or
///   $0 at expiry — a discontinuity. You cannot margin-call a binary option:
///   by the time the oracle says "NO won", YES collateral is already worthless,
///   so a post-resolution liquidation can't protect the pool.
///   Solution: positions MUST be closed or liquidated BEFORE the market
///   expires. We mark collateral at the continuous AMM mid-price while trading,
///   liquidate on health breach, and let ANYONE force-liquidate in the final
///   window before expiry regardless of health. A loan can never survive into
///   resolution, so the pool is never exposed to the cliff.
///
/// ⚠️ STATUS: v0.6 RESEARCH — NOT YET DEPLOYED. The CRITICAL is mitigated +
///   fuzz-validated; two HIGHs remain before this can hold real funds.
///
///   1. [CRITICAL — MITIGATED] Spot AMM-mark manipulation. Collateral was
///      marked at priceOf (instantaneous AMM mid); on a thin CPMM a borrower
///      could spike the mark, over-borrow, and unwind for ~0.7% fee. FIX: a
///      DEPTH CAP (_markValue) — collateral is never valued above
///      COLLATERAL_DEPTH_BPS (10%) of the pool's live opposite reserve, plus
///      a MIN_POOL_DEPTH eligibility gate and 40% max LTV. A position's real
///      recoverable value is bounded by what the pool can pay out on
///      liquidation, not by the manipulable spot mark × share count.
///      VALIDATED: test/CirqueBetFuzz.t.sol runs the full attack against the
///      real contracts over 5,000 randomized (depth, manipulation, position)
///      runs — 0 pool drains. Manipulation actually LOWERS the borrow limit
///      (spiking the mark shrinks the opposite reserve the cap keys off), so
///      the attack is net-negative.
///   2. [HIGH — OPEN] Force-close is permissionless but UNINCENTIVISED — a
///      loan can strand past expiry if no liquidator acts. Needs a funded
///      keeper + real liquidation bonus, and an explicit Resolved-phase
///      branch (redeem winners / write off losers) instead of relying on
///      post-resolution priceOf.
///   3. [HIGH — OPEN] Liquidator takes the WHOLE position for `owed` — in the
///      force window this lets a healthy borrower's upside be seized. Should
///      return surplus above (owed + capped bonus) to the borrower.
///   4. [MEDIUM — OPEN] Pool value is bad-debt-blind; interest realize-vs-
///      accrue can diverge; supplier withdraw could be gamed.
///   5. [MEDIUM — addressed in MarketsV3 docs] operator approval is
///      unlimited/all-markets — scope risk documented on setShareOperator.
///
///   The depth-cap (finding 1) is the load-bearing safety result and is the
///   answer to "how do we make binary-bet collateral safe." Findings 2-3 are
///   liquidation-incentive work, not a fund-drain at rest. DO NOT deploy or
///   wire to the frontend until 2-3 are resolved and re-reviewed.
///
/// v0.6 alpha design intent (TESTNET ONLY — DO NOT USE WITH REAL FUNDS):
///   - Collateral: YES or NO shares on a MarketsV3 market.
///   - Debt: USDC at 5% flat APY simple interest.
///   - 50% max LTV at origination (tighter than cirBTC product — binary
///     collateral is more volatile). 60% liquidation threshold.
///   - FORCE_CLOSE_WINDOW before expiry: anyone can liquidate regardless of
///     health, so no loan reaches resolution.
///   - Single open loan per user. Per-user borrow cap.
///   - USDC suppliers earn yield via share-price appreciation (same model as
///     CirqueLending).
contract CirqueBetLending is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────── Constants ──────────────────────────

    uint256 public constant MAX_LTV_BPS = 4000;       // 40% at origination (cover-ratio margin)
    uint256 public constant LIQ_LTV_BPS = 6000;       // 60% triggers liquidation
    uint256 public constant LIQ_BONUS_BPS = 500;      // 5% — informational; liquidator gets the whole position

    /// @notice Manipulation defenses (derived from CPMM math, validated by the
    /// adversarial fuzz test in test/CirqueBetFuzz.t.sol):
    ///   - Collateral is NEVER valued above COLLATERAL_DEPTH_BPS of the pool's
    ///     live opposite-side reserve. A position's real recoverable value is
    ///     bounded by what the pool can pay out on liquidation, NOT by the
    ///     (manipulable) spot mark × share count. This makes spot-mark
    ///     manipulation net-negative and keeps liquidation always whole.
    ///   - Markets must have at least MIN_POOL_DEPTH liquidity to be eligible,
    ///     so the percentage cap isn't dominated by the 5-USDC MIN_LIQUIDITY
    ///     floor / integer rounding.
    uint256 public constant COLLATERAL_DEPTH_BPS = 1000; // ≤10% of opposite reserve
    uint256 public constant MIN_POOL_DEPTH = 1000e6;     // 1,000 USDC per side, eligibility gate

    uint256 public constant INTEREST_BPS_PER_YEAR = 500;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Window before market expiry within which ANY loan is
    /// force-liquidatable regardless of health. This is the cliff guard:
    /// no position may survive into resolution.
    uint256 public constant FORCE_CLOSE_WINDOW = 2 hours;

    uint256 public constant MAX_BORROW_PER_USER = 1000e6; // 1,000 USDC (alpha)
    uint256 public constant INITIAL_SHARES_PER_USDC = 1;

    // ───────────────────────── Immutables ─────────────────────────

    IERC20 public immutable USDC;
    MarketsV3 public immutable MARKETS;
    address public immutable OWNER;

    // ─────────────────────────── State ────────────────────────────

    struct Loan {
        bytes32 marketId;
        bool betYes;          // outcome of the collateral position
        uint256 shares;       // collateral shares held by this contract
        uint256 principal;    // USDC borrowed
        uint256 borrowedAt;
        bool active;
    }
    mapping(address => Loan) public loans;

    // USDC supply side (mirrors CirqueLending).
    mapping(address => uint256) public shares;       // supplier LP shares
    uint256 public totalShares;
    uint256 public totalBorrowedPrincipal;
    uint256 public accruedInterestUSDC;
    uint256 public lastAccrualAt;

    // ─────────────────────────── Events ───────────────────────────

    event Supplied(address indexed user, uint256 usdcIn, uint256 sharesMinted);
    event Withdrew(address indexed user, uint256 sharesBurned, uint256 usdcOut);
    event BetBorrowed(
        address indexed user,
        bytes32 indexed marketId,
        bool betYes,
        uint256 collateralShares,
        uint256 principal
    );
    event BetRepaid(address indexed user, uint256 principal, uint256 interest, uint256 sharesReturned);
    event BetLiquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 sharesSeized,
        bool forced
    );

    // ─────────────────────── Errors ───────────────────────

    error ZeroAmount();
    error ActiveLoanExists();
    error NoActiveLoan();
    error InsufficientUSDCLiquidity();
    error InsufficientShares();
    error BorrowCapExceeded();
    error LTVTooHigh();
    error NotLiquidatable();
    error MarketResolvedOrExpired();
    error MarketGone();
    error PoolTooShallow();
    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    constructor(IERC20 usdc, MarketsV3 markets, address owner) {
        USDC = usdc;
        MARKETS = markets;
        OWNER = owner;
        lastAccrualAt = block.timestamp;
    }

    // ──────────────────────────── Supply ────────────────────────────

    function supplyUSDC(uint256 amount) external nonReentrant returns (uint256 sharesMinted) {
        if (amount == 0) revert ZeroAmount();
        _rollAccrual();
        uint256 totalValue = _totalPoolValueUSDC();
        if (totalShares == 0 || totalValue == 0) {
            sharesMinted = amount * INITIAL_SHARES_PER_USDC;
        } else {
            sharesMinted = (amount * totalShares) / totalValue;
        }
        if (sharesMinted == 0) revert ZeroAmount();
        shares[msg.sender] += sharesMinted;
        totalShares += sharesMinted;
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(msg.sender, amount, sharesMinted);
    }

    function withdrawUSDC(uint256 shareAmount) external nonReentrant returns (uint256 usdcOut) {
        if (shareAmount == 0) revert ZeroAmount();
        if (shareAmount > shares[msg.sender]) revert InsufficientShares();
        _rollAccrual();
        usdcOut = (shareAmount * _totalPoolValueUSDC()) / totalShares;
        if (usdcOut == 0) revert ZeroAmount();
        if (USDC.balanceOf(address(this)) < usdcOut) revert InsufficientUSDCLiquidity();
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        // Realize this withdrawer's slice of accrued interest out of the counter.
        uint256 pv = _totalPoolValueUSDC();
        uint256 interestShare = pv == 0 ? 0 : (usdcOut * accruedInterestUSDC) / pv;
        if (interestShare > accruedInterestUSDC) interestShare = accruedInterestUSDC;
        accruedInterestUSDC -= interestShare;
        USDC.safeTransfer(msg.sender, usdcOut);
        emit Withdrew(msg.sender, shareAmount, usdcOut);
    }

    // ──────────────────── Borrow against a held bet ────────────────────

    /// @notice Lock a YES/NO position you already hold and borrow USDC against
    /// its live AMM mark. Caller must have approved this contract as a share
    /// operator on MarketsV3 (setShareOperator) first.
    function borrowAgainstBet(
        bytes32 marketId,
        bool betYes,
        uint256 collateralShares,
        uint256 usdcAmount
    ) external nonReentrant returns (uint256 openingHealthBps) {
        if (collateralShares == 0 || usdcAmount == 0) revert ZeroAmount();
        if (usdcAmount > MAX_BORROW_PER_USER) revert BorrowCapExceeded();
        if (loans[msg.sender].active) revert ActiveLoanExists();
        if (USDC.balanceOf(address(this)) < usdcAmount) revert InsufficientUSDCLiquidity();

        // Market must be live with room before expiry — never lend into the
        // force-close window (the position couldn't be safely held).
        Markets.Market memory m = MARKETS.getMarket(marketId);
        if (m.createdAt == 0) revert MarketGone();
        if (m.phase != Markets.Phase.Trading || block.timestamp + FORCE_CLOSE_WINDOW >= m.expiry) {
            revert MarketResolvedOrExpired();
        }
        // Eligibility gate: both reserves must clear MIN_POOL_DEPTH so the
        // depth-cap percentage is meaningful (not dominated by the 5-USDC
        // MIN_LIQUIDITY floor / integer rounding) and manipulation is costly.
        if (m.yesReserve < MIN_POOL_DEPTH || m.noReserve < MIN_POOL_DEPTH) {
            revert PoolTooShallow();
        }

        _rollAccrual();

        // Pull the position in as collateral (reverts if not approved / no balance).
        Markets.Outcome outcome = betYes ? Markets.Outcome.Yes : Markets.Outcome.No;
        MARKETS.transferSharesFrom(marketId, outcome, msg.sender, address(this), collateralShares);

        loans[msg.sender] = Loan({
            marketId: marketId,
            betYes: betYes,
            shares: collateralShares,
            principal: usdcAmount,
            borrowedAt: block.timestamp,
            active: true
        });
        totalBorrowedPrincipal += usdcAmount;

        openingHealthBps = _healthBps(loans[msg.sender]);
        if (openingHealthBps > MAX_LTV_BPS) revert LTVTooHigh();

        USDC.safeTransfer(msg.sender, usdcAmount);
        emit BetBorrowed(msg.sender, marketId, betYes, collateralShares, usdcAmount);
    }

    /// @notice Repay principal + interest, get your position back.
    function repayBet() external nonReentrant {
        Loan memory loan = loans[msg.sender];
        if (!loan.active) revert NoActiveLoan();
        _rollAccrual();

        uint256 interest = _interestOwed(loan);
        uint256 owed = loan.principal + interest;

        delete loans[msg.sender];
        totalBorrowedPrincipal -= loan.principal;
        accruedInterestUSDC = interest > accruedInterestUSDC ? 0 : accruedInterestUSDC - interest;

        USDC.safeTransferFrom(msg.sender, address(this), owed);

        // Return the collateral position.
        Markets.Outcome outcome = loan.betYes ? Markets.Outcome.Yes : Markets.Outcome.No;
        MARKETS.transferSharesFrom(loan.marketId, outcome, address(this), msg.sender, loan.shares);

        emit BetRepaid(msg.sender, loan.principal, interest, loan.shares);
    }

    /// @notice Liquidate a position that is either unhealthy (mark-based LTV >
    /// LIQ_LTV_BPS) OR within FORCE_CLOSE_WINDOW of expiry (the cliff guard —
    /// regardless of health). Liquidator repays the debt + interest in USDC and
    /// receives the entire share collateral, which they can sell or redeem.
    function liquidateBet(address borrower) external nonReentrant {
        Loan memory loan = loans[borrower];
        if (!loan.active) revert NoActiveLoan();
        _rollAccrual();

        Markets.Market memory m = MARKETS.getMarket(loan.marketId);
        bool forced = block.timestamp + FORCE_CLOSE_WINDOW >= m.expiry;
        if (!forced && _healthBps(loan) <= LIQ_LTV_BPS) revert NotLiquidatable();

        uint256 interest = _interestOwed(loan);
        uint256 owed = loan.principal + interest;

        delete loans[borrower];
        totalBorrowedPrincipal -= loan.principal;
        accruedInterestUSDC = interest > accruedInterestUSDC ? 0 : accruedInterestUSDC - interest;

        USDC.safeTransferFrom(msg.sender, address(this), owed);

        // Liquidator takes the whole position (their incentive: it's worth more
        // than `owed` while health < 100%, and they can ride it to resolution).
        Markets.Outcome outcome = loan.betYes ? Markets.Outcome.Yes : Markets.Outcome.No;
        MARKETS.transferSharesFrom(loan.marketId, outcome, address(this), msg.sender, loan.shares);

        emit BetLiquidated(borrower, msg.sender, owed, loan.shares, forced);
    }

    // ───────────────────────── Views ───────────────────────

    function healthBps(address user) external view returns (uint256) {
        Loan memory loan = loans[user];
        if (!loan.active) return 0;
        return _healthBps(loan);
    }

    function interestOwed(address user) external view returns (uint256) {
        Loan memory loan = loans[user];
        if (!loan.active) return 0;
        return _interestOwed(loan);
    }

    /// @notice Live USDC mark of a position's collateral = shares × AMM mid.
    function collateralValueUSDC(address user) external view returns (uint256) {
        Loan memory loan = loans[user];
        if (!loan.active) return 0;
        return _collateralValue(loan);
    }

    function maxBorrow(bytes32 marketId, bool betYes, uint256 collateralShares)
        external view returns (uint256)
    {
        uint256 v = _markValue(marketId, betYes, collateralShares);
        return (v * MAX_LTV_BPS) / BPS_DENOMINATOR;
    }

    function availableUSDC() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    function totalPoolValueUSDC() external view returns (uint256) {
        return _totalPoolValueUSDC();
    }

    function balanceOfUSDC(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * _totalPoolValueUSDC()) / totalShares;
    }

    // ─────────────────────────── Internals ────────────────────────

    function _markValue(bytes32 marketId, bool betYes, uint256 sharesAmt) internal view returns (uint256) {
        // Spot mark: priceOf returns USDC-per-share scaled 1e18. shares are
        // 6-dp (USDC scale). value(6dp) = shares × price / 1e18.
        uint256 price = MARKETS.priceOf(marketId, betYes ? Markets.Outcome.Yes : Markets.Outcome.No);
        uint256 spotValue = (sharesAmt * price) / 1e18;

        // DEPTH CAP (the manipulation defense): a position's real recoverable
        // value is bounded by what the pool can pay out on liquidation, not by
        // the manipulable spot mark. Liquidating a YES position sells YES into
        // the pool and can extract at most the opposite (NO) reserve. We
        // recognize at most COLLATERAL_DEPTH_BPS of that opposite reserve.
        // Even if an attacker spends ~2×depth to spike the spot mark, the cap
        // holds collateral value to a small slice of real depth, so the
        // over-borrow is smaller than the fee paid to move the price → the
        // manipulation is net-negative, and liquidation stays whole.
        Markets.Market memory m = MARKETS.getMarket(marketId);
        uint256 oppositeReserve = betYes ? m.noReserve : m.yesReserve;
        uint256 depthCap = (oppositeReserve * COLLATERAL_DEPTH_BPS) / BPS_DENOMINATOR;

        return spotValue < depthCap ? spotValue : depthCap;
    }

    function _collateralValue(Loan memory loan) internal view returns (uint256) {
        return _markValue(loan.marketId, loan.betYes, loan.shares);
    }

    function _healthBps(Loan memory loan) internal view returns (uint256) {
        uint256 cv = _collateralValue(loan);
        if (cv == 0) return type(uint256).max; // worthless mark → max unhealthy
        uint256 debt = loan.principal + _interestOwed(loan);
        return (debt * BPS_DENOMINATOR) / cv;
    }

    function _interestOwed(Loan memory loan) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - loan.borrowedAt;
        return (loan.principal * INTEREST_BPS_PER_YEAR * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    function _rollAccrual() internal {
        if (block.timestamp == lastAccrualAt) return;
        if (totalBorrowedPrincipal == 0) { lastAccrualAt = block.timestamp; return; }
        uint256 elapsed = block.timestamp - lastAccrualAt;
        accruedInterestUSDC += (totalBorrowedPrincipal * INTEREST_BPS_PER_YEAR * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        lastAccrualAt = block.timestamp;
    }

    function _totalPoolValueUSDC() internal view returns (uint256) {
        return USDC.balanceOf(address(this)) + totalBorrowedPrincipal + accruedInterestUSDC;
    }
}
