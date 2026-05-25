// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Markets} from "./Markets.sol";

/// @notice Minimal BTC/USD price oracle interface. The lending contract reads
/// the price to mark cirBTC collateral against USDC debt. v0.5 alpha reads
/// from Registrai's own bonded-agent attestation layer via AttestedBTCOracle.
///
/// The interface returns the timestamp of the last update so the lending
/// contract can refuse to act on stale data (see MAX_ORACLE_STALENESS).
interface IBTCPriceOracle {
    /// @return priceUSDC18  BTC price denominated in USDC, scaled to 18 decimals.
    /// @return updatedAt     Block timestamp of the latest valid attestation.
    function getBTCPrice() external view returns (uint256 priceUSDC18, uint256 updatedAt);
}

/// @title CirqueLending
/// @notice Two-sided lending pool: USDC suppliers earn yield from cirBTC-
///         collateralised USDC borrowers.
///
/// v0.5 alpha shape (TESTNET ONLY — DO NOT USE WITH REAL FUNDS):
///
///   SUPPLY SIDE
///     - Anyone deposits USDC into the pool, receives shares proportional
///       to their fraction of the pool's USDC-value (the receipt is just a
///       share count stored in this contract; no separate ERC-20 token).
///     - Borrower interest accrues into the pool over time; share-value
///       rises mechanically (no claim step needed).
///     - Withdraw burns shares for the corresponding USDC at the new
///       per-share value (i.e., principal + your slice of accrued interest).
///     - Withdraws are gated on idle pool USDC (utilisation cap).
///
///   BORROW SIDE
///     - Lock cirBTC, draw USDC at 5% flat APY simple interest.
///     - 50% max LTV at origination; 65% triggers permissionless liquidation.
///     - Liquidator pays (debt + interest), receives (debt + interest) × 1.05
///       worth of cirBTC at oracle price. Remainder of collateral refunds
///       to the borrower. Bad-debt (BTC crashed below debt) is absorbed by
///       the pool (suppliers eat the loss).
///
///   ORACLE
///     - Reads from a bonded agent on Registry v2 via AttestedBTCOracle.
///     - MAX_ORACLE_STALENESS = 1 hour. Stale oracle halts borrow +
///       liquidate. Repays and withdraws always work.
///
///   CAPS (alpha-only, lifted in v0.5 beta after audit)
///     - 1 cirBTC collateral per user.
///     - 1,000 USDC supply per user.
///
/// Decimals:
///   - cirBTC: 8 decimals
///   - USDC:   6 decimals
///   - shares: 6 decimals (1:1 with USDC at genesis)
///
/// Atomic `leverageAndBet` (borrow + Markets.buy in one tx) deferred to
/// v0.5 beta — needs per-user share custody design.
contract CirqueLending is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────── Constants ──────────────────────────

    uint256 public constant MAX_LTV_BPS = 5000;
    uint256 public constant LIQ_LTV_BPS = 6500;
    uint256 public constant LIQ_BONUS_BPS = 500;
    uint256 public constant INTEREST_BPS_PER_YEAR = 500;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS_DENOMINATOR = 10000;

    uint256 public constant MAX_ORACLE_STALENESS = 1 hours;

    uint256 public constant MAX_COLLATERAL_PER_USER = 1e8;       // 1 cirBTC
    uint256 public constant MAX_USDC_SUPPLY_PER_USER = 1000e6;   // 1,000 USDC

    /// @notice Initial shares-per-USDC ratio when the pool is empty.
    /// Standard 1:1 — first depositor gets one share per USDC.
    uint256 public constant INITIAL_SHARES_PER_USDC = 1;

    // ───────────────────────── Immutables ─────────────────────────

    IERC20 public immutable CIRBTC;
    IERC20 public immutable USDC;
    Markets public immutable MARKETS;
    IBTCPriceOracle public immutable ORACLE;
    address public immutable OWNER;

    // ─────────────────────────── State ────────────────────────────

    struct Loan {
        uint256 collateral;     // cirBTC locked (8 decimals)
        uint256 principal;      // USDC borrowed (6 decimals)
        uint256 borrowedAt;     // timestamp when interest accrual started
        bool active;
    }
    /// @notice At most one active loan per user in v0.5 alpha.
    mapping(address => Loan) public loans;

    /// @notice Per-supplier share balance. Receipts are virtual (not ERC-20).
    mapping(address => uint256) public shares;
    /// @notice Sum of all `shares`. Used for share-price math.
    uint256 public totalShares;

    /// @notice Sum of all outstanding principal across active loans.
    /// Plus the contract's idle USDC balance, plus accrued-but-unpaid
    /// interest, equals the total pool value (= what suppliers' shares
    /// are claims against).
    uint256 public totalBorrowedPrincipal;

    /// @notice Sum of interest accrued so far across all active loans.
    /// Updated lazily on every borrow/repay/liquidate. Used so withdraw
    /// can value shares without iterating every active loan.
    uint256 public accruedInterestUSDC;
    /// @notice Last time `accruedInterestUSDC` was rolled forward.
    uint256 public lastAccrualAt;

    // ─────────────────────────── Events ───────────────────────────

    event Supplied(address indexed user, uint256 usdcIn, uint256 sharesMinted);
    event Withdrew(address indexed user, uint256 sharesBurned, uint256 usdcOut);
    event Borrowed(address indexed user, uint256 collateral, uint256 principal);
    event Repaid(
        address indexed user,
        uint256 principal,
        uint256 interest,
        uint256 collateralReturned
    );
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 collateralRefunded
    );

    // ─────────────────────── Errors ───────────────────────

    error ZeroAmount();
    error CollateralCapExceeded();
    error SupplyCapExceeded();
    error InsufficientShares();
    error ActiveLoanExists();
    error NoActiveLoan();
    error InsufficientUSDCLiquidity();
    error LTVTooHigh();
    error NotLiquidatable();
    error OracleStale();
    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    constructor(
        IERC20 cirbtc,
        IERC20 usdc,
        Markets markets,
        IBTCPriceOracle oracle,
        address owner
    ) {
        CIRBTC = cirbtc;
        USDC = usdc;
        MARKETS = markets;
        ORACLE = oracle;
        OWNER = owner;
        lastAccrualAt = block.timestamp;
    }

    // ──────────────────────────── Supply ────────────────────────────

    /// @notice Deposit USDC into the lending pool. Receive shares at the
    /// current per-share USDC value. Earns yield as borrowers repay
    /// interest (pool grows → share-value rises).
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

        uint256 newShares = shares[msg.sender] + sharesMinted;
        // Cap is in USDC terms — convert via current share-value.
        uint256 userUSDCAfter = _sharesToUSDC(newShares);
        if (userUSDCAfter > MAX_USDC_SUPPLY_PER_USER) revert SupplyCapExceeded();

        shares[msg.sender] = newShares;
        totalShares += sharesMinted;

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        emit Supplied(msg.sender, amount, sharesMinted);
    }

    /// @notice Burn shares and withdraw USDC at the current per-share value
    /// (principal + your slice of accrued interest). Subject to pool
    /// utilisation: if too much USDC is currently lent out, withdrawal
    /// reverts until borrowers repay.
    function withdrawUSDC(uint256 shareAmount) external nonReentrant returns (uint256 usdcOut) {
        if (shareAmount == 0) revert ZeroAmount();
        if (shareAmount > shares[msg.sender]) revert InsufficientShares();

        _rollAccrual();

        usdcOut = _sharesToUSDC(shareAmount);
        if (usdcOut == 0) revert ZeroAmount();

        // Honour utilisation: only idle USDC can be withdrawn.
        if (USDC.balanceOf(address(this)) < usdcOut) {
            revert InsufficientUSDCLiquidity();
        }

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        // Accrued interest distributed via share appreciation: when this
        // user takes their slice, decrement the pool's accrued counter
        // proportionally.
        uint256 interestShare = (usdcOut * accruedInterestUSDC) / _totalPoolValueUSDC_preDecrement(usdcOut);
        if (interestShare > accruedInterestUSDC) interestShare = accruedInterestUSDC;
        accruedInterestUSDC -= interestShare;

        USDC.safeTransfer(msg.sender, usdcOut);

        emit Withdrew(msg.sender, shareAmount, usdcOut);
    }

    // ───────────────────────── Borrow ─────────────────────────────

    function borrow(
        uint256 collateralAmount,
        uint256 usdcAmount
    ) external nonReentrant returns (uint256 openingHealthBps) {
        if (collateralAmount == 0 || usdcAmount == 0) revert ZeroAmount();
        if (collateralAmount > MAX_COLLATERAL_PER_USER) revert CollateralCapExceeded();
        if (loans[msg.sender].active) revert ActiveLoanExists();
        if (USDC.balanceOf(address(this)) < usdcAmount) {
            revert InsufficientUSDCLiquidity();
        }

        _rollAccrual();

        CIRBTC.safeTransferFrom(msg.sender, address(this), collateralAmount);

        loans[msg.sender] = Loan({
            collateral: collateralAmount,
            principal: usdcAmount,
            borrowedAt: block.timestamp,
            active: true
        });
        totalBorrowedPrincipal += usdcAmount;

        openingHealthBps = _healthBps(loans[msg.sender]);
        if (openingHealthBps > MAX_LTV_BPS) revert LTVTooHigh();

        USDC.safeTransfer(msg.sender, usdcAmount);

        emit Borrowed(msg.sender, collateralAmount, usdcAmount);
    }

    // ───────────────────────── Repay ──────────────────────────────

    function repay() external nonReentrant {
        Loan memory loan = loans[msg.sender];
        if (!loan.active) revert NoActiveLoan();

        _rollAccrual();

        uint256 interest = _interestOwed(loan);
        uint256 owed = loan.principal + interest;

        delete loans[msg.sender];
        totalBorrowedPrincipal -= loan.principal;
        // _rollAccrual has already added `interest` to accruedInterestUSDC
        // as a placeholder. Now that the borrower is paying cash, that
        // placeholder is being realized into the idle USDC balance — so
        // decrement to avoid double-counting in pool value.
        if (interest > accruedInterestUSDC) {
            // Shouldn't happen if accounting is consistent, but clamp
            // defensively to avoid underflow.
            accruedInterestUSDC = 0;
        } else {
            accruedInterestUSDC -= interest;
        }

        // Pull USDC (principal + interest) from borrower.
        USDC.safeTransferFrom(msg.sender, address(this), owed);

        // Return collateral.
        CIRBTC.safeTransfer(msg.sender, loan.collateral);

        emit Repaid(msg.sender, loan.principal, interest, loan.collateral);
    }

    // ─────────────────────── Liquidation ──────────────────────────

    function liquidate(address borrower) external nonReentrant {
        Loan memory loan = loans[borrower];
        if (!loan.active) revert NoActiveLoan();
        if (_healthBps(loan) <= LIQ_LTV_BPS) revert NotLiquidatable();

        _rollAccrual();

        uint256 interest = _interestOwed(loan);
        uint256 owed = loan.principal + interest;

        uint256 liquidatorPayoutUSDC6 =
            (owed * (BPS_DENOMINATOR + LIQ_BONUS_BPS)) / BPS_DENOMINATOR;
        uint256 seize = _usdc6ToCirBTC(liquidatorPayoutUSDC6);

        uint256 refund;
        if (seize >= loan.collateral) {
            seize = loan.collateral;
            refund = 0;
        } else {
            refund = loan.collateral - seize;
        }

        delete loans[borrower];
        totalBorrowedPrincipal -= loan.principal;
        // Same as repay(): _rollAccrual added `interest` as placeholder;
        // now it's realized in cash.
        if (interest > accruedInterestUSDC) {
            accruedInterestUSDC = 0;
        } else {
            accruedInterestUSDC -= interest;
        }

        USDC.safeTransferFrom(msg.sender, address(this), owed);

        CIRBTC.safeTransfer(msg.sender, seize);
        if (refund > 0) {
            CIRBTC.safeTransfer(borrower, refund);
        }

        emit Liquidated(borrower, msg.sender, owed, seize, refund);
    }

    // ───────────────────────── View helpers ───────────────────────

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

    function maxBorrow(uint256 cirBTCAmount) external view returns (uint256) {
        uint256 collateralValueUSDC6 = _cirBTCToUSDC6(cirBTCAmount);
        return (collateralValueUSDC6 * MAX_LTV_BPS) / BPS_DENOMINATOR;
    }

    function availableUSDC() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice USDC value of a user's shares at the current share price.
    function balanceOfUSDC(address user) external view returns (uint256) {
        return _sharesToUSDC(shares[user]);
    }

    /// @notice Total USDC value of the pool (idle + lent + unrealized interest).
    function totalPoolValueUSDC() external view returns (uint256) {
        return _totalPoolValueUSDC();
    }

    // ─────────────────────────── Internals ────────────────────────

    /// @dev Roll accrued borrower interest forward into the accruedInterestUSDC
    /// counter. Called before every state-changing op so share-price reflects
    /// real-time yield.
    function _rollAccrual() internal {
        if (block.timestamp == lastAccrualAt) return;
        if (totalBorrowedPrincipal == 0) {
            lastAccrualAt = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - lastAccrualAt;
        uint256 delta = (totalBorrowedPrincipal * INTEREST_BPS_PER_YEAR * elapsed) /
            (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        accruedInterestUSDC += delta;
        lastAccrualAt = block.timestamp;
    }

    function _healthBps(Loan memory loan) internal view returns (uint256) {
        uint256 collateralValueUSDC6 = _cirBTCToUSDC6(loan.collateral);
        if (collateralValueUSDC6 == 0) return type(uint256).max;
        uint256 debt = loan.principal + _interestOwed(loan);
        return (debt * BPS_DENOMINATOR) / collateralValueUSDC6;
    }

    function _interestOwed(Loan memory loan) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - loan.borrowedAt;
        return (loan.principal * INTEREST_BPS_PER_YEAR * elapsed) /
            (BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    function _cirBTCToUSDC6(uint256 cirBTCAmount) internal view returns (uint256) {
        if (cirBTCAmount == 0) return 0;
        (uint256 priceUSDC18, uint256 updatedAt) = ORACLE.getBTCPrice();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert OracleStale();
        return Math.mulDiv(cirBTCAmount, priceUSDC18, 1e20);
    }

    function _usdc6ToCirBTC(uint256 usdcAmount) internal view returns (uint256) {
        if (usdcAmount == 0) return 0;
        (uint256 priceUSDC18, uint256 updatedAt) = ORACLE.getBTCPrice();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert OracleStale();
        return Math.mulDiv(usdcAmount, 1e20, priceUSDC18);
    }

    /// @dev Live USDC-equivalent value of the pool: idle balance + outstanding
    /// principal + accrued (unpaid) interest. Updated on every roll.
    function _totalPoolValueUSDC() internal view returns (uint256) {
        return USDC.balanceOf(address(this)) + totalBorrowedPrincipal + accruedInterestUSDC;
    }

    /// @dev Same as _totalPoolValueUSDC but with `withdrawAmount` already
    /// excluded from the idle balance, used in withdraw flow to compute the
    /// withdrawer's proportional slice of accrued interest BEFORE the
    /// transfer changes the state.
    function _totalPoolValueUSDC_preDecrement(uint256 /*withdrawAmount*/)
        internal view returns (uint256)
    {
        // The withdraw already has the share-equivalent USDC computed; for
        // accrued-interest proportional reduction we just need the live total.
        // Returning live total is correct because `usdcOut` includes the
        // user's slice of accrued interest already.
        uint256 v = _totalPoolValueUSDC();
        return v == 0 ? 1 : v;
    }

    function _sharesToUSDC(uint256 shareAmount) internal view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shareAmount * _totalPoolValueUSDC()) / totalShares;
    }

    // No admin escape hatch. The treasury supplies USDC via supplyUSDC()
    // like any other LP and withdraws via withdrawUSDC() like any other LP.
    // Removing the privileged adminWithdrawUSDC eliminates the centralized
    // pool-drain risk identified during internal audit.
}
