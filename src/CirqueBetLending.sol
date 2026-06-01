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
///   Approach: mark collateral at the continuous depth-capped AMM mark while
///   trading, liquidate on health breach, and let ANYONE force-liquidate in the
///   final window before expiry regardless of health.
///
///   HONEST LIMIT (do not overstate this): the 5% bonus makes force-close
///   self-executing only for IN-THE-MONEY positions (live collateral value >
///   owed×1.05). A position that has gone OUT-OF-THE-MONEY before expiry has no
///   profitable liquidator — paying `owed` for sub-`owed` collateral is a loss —
///   so it is NOT closed, it resolves, and the pool absorbs the shortfall. The
///   cliff guard does not ELIMINATE that loss; it BOUNDS it and makes it
///   HONEST: (1) origination LTV ≤ 40% and the depth cap (principal ≤ ~4% of
///   the opposite reserve) keep the per-loan loss small and the per-user cap
///   (1,000 USDC) caps it absolutely; (2) writeOffBadDebt realizes the loss
///   immediately and socializes it pro-rata, so no late withdrawer escapes it.
///   This is ordinary under-collateralized-lending risk on a volatile binary
///   asset, bounded by design — not an eliminated risk.
///
/// ⚠️ STATUS: v0.9 RESEARCH — NOT YET DEPLOYED. CRITICAL mitigated +
///   fuzz-validated; both HIGHs fixed; MEDIUM cluster addressed. A full
///   re-review surfaced one economic-model HIGH (cliff loss on out-of-the-money
///   loans is bounded, not eliminated — see "HONEST LIMIT" above) and two
///   MEDIUMs (a keeper foot-gun and a share-inflation vector); all are now
///   fixed and a verification pass on those fixes is clean (idleUSDC accounting,
///   resolved-loser routing, bounded-loss invariants all confirmed). No
///   fund-drain-at-rest. Per-user cap (1,000 USDC), 40% LTV, depth cap and a
///   running keeper bound the residual risk. A professional audit is still
///   warranted before this holds real funds; do not deploy until then.
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
///   2. [HIGH — ADDRESSED, with an honest residual] Force-close was
///      UNINCENTIVISED. FIX: the liquidator receives shares worth (owed × 1.05)
///      — a real, share-denominated reward that makes force-close
///      self-executing FOR IN-THE-MONEY POSITIONS. RESIDUAL (re-review): for
///      OUT-OF-THE-MONEY positions the bonus cannot make liquidation profitable,
///      so the pool absorbs a bounded shortfall at resolution (see "HONEST
///      LIMIT" above) — this is the one economic-model HIGH and is bounded by
///      LTV + depth cap + per-user cap + writeOffBadDebt, not eliminated. The
///      keeper (agent/src/bet-keeper.ts) writes off resolved-losers for free
///      and force-closes only profitable positions; it never liquidates at a
///      loss.
///   3. [HIGH — FIXED] Liquidator used to take the WHOLE position for `owed` —
///      in the force window this let a healthy borrower's upside be seized.
///      FIX: liquidation is now SPLIT — the liquidator gets only the shares
///      worth (owed × 1.05), and the surplus shares are returned to the
///      borrower (see liquidateBet). Crucially the split is sized off a FIXED
///      reference — markValueAtBorrow, the depth-capped value recorded at
///      origination — NOT live priceOf. A first-cut fix sized it from spot,
///      which a re-review caught as exploitable: a liquidator could crash the
///      AMM spot in the same tx to inflate their share count past the whole
///      position and seize the surplus anyway. Using the origination reference
///      makes the split unmanipulable within the liquidation tx. Proven by
///      test_forceLiquidate_inExpiryWindow_evenIfHealthy,
///      test_liquidation_paysBonus_returnsSurplus, and
///      test_liquidator_cannotManipulateSpot_toStealSurplus.
///   4. [MEDIUM — ADDRESSED] Pool value was bad-debt-blind. ROOT CAUSE: a
///      resolved-LOSER loan (collateral worth $0, no liquidator will pay owed)
///      kept its principal counted in pool value, letting a late withdrawer
///      exit at an inflated share price and dump the loss on the rest. FIX:
///      permissionless writeOffBadDebt removes the lost principal the moment
///      the loss exists, socializing it pro-rata and closing the withdraw race;
///      the keeper polls isWriteOffable. Interest realize-vs-accrue reconciles
///      (every mutating entrypoint rolls first, accrual is linear, subtractions
///      are underflow-clamped) and liquidation is value-neutral to the pool
///      (liquidator pays full owed in cash), so there is no discrete jump to
///      game on the supply side.
///   5. [MEDIUM — addressed in MarketsV3 docs] operator approval is
///      unlimited/all-markets — scope risk documented on setShareOperator.
///   6. [MEDIUM — FIXED, re-review] liquidateBet accepted a resolved-LOSER loan,
///      letting a naive keeper pay full `owed` for $0 collateral (a donation to
///      the pool, a loss to the caller). FIX: liquidateBet now reverts
///      UseWriteOff on resolved-losers and routes them to writeOffBadDebt.
///   7. [MEDIUM — FIXED, re-review] first-depositor / ERC4626 share-inflation:
///      pool value read USDC.balanceOf(this), so a direct token donation could
///      skew the share price and grief a later supplier. FIX: pool value now
///      reads an INTERNAL idleUSDC accumulator updated on every USDC flow, so a
///      donation cannot move the share price. (test_donationCannotInflateShares)
///
///   The depth-cap (finding 1) is the load-bearing safety result and is the
///   answer to "how do we make binary-bet collateral safe." Findings 2-3 were
///   liquidation-incentive/fairness work (split liquidation off a fixed mark).
///   No fund-drain-at-rest. DO NOT deploy or wire to the frontend until a
///   further review pass on this v0.9 is clean.
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

    /// @notice Mainnet eligibility floor. The ACTUAL gate is the immutable
    /// MIN_POOL_DEPTH set at construction — a testnet deployment may scale it
    /// down to match play-money liquidity WITHOUT weakening the manipulation
    /// defense, which is ratio-based (COLLATERAL_DEPTH_BPS + MAX_LTV_BPS) and
    /// independent of the absolute floor. Mainnet deployments MUST pass
    /// DEFAULT_MIN_POOL_DEPTH (or larger).
    uint256 public constant DEFAULT_MIN_POOL_DEPTH = 1000e6; // 1,000 USDC per side

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
    /// @notice Per-side liquidity a market must have to be borrowable. Set at
    /// deploy; see DEFAULT_MIN_POOL_DEPTH (mainnet value). Lowering it on
    /// testnet does not touch the ratio-based manipulation defense.
    uint256 public immutable MIN_POOL_DEPTH;

    // ─────────────────────────── State ────────────────────────────

    struct Loan {
        bytes32 marketId;
        bool betYes;          // outcome of the collateral position
        uint256 shares;       // collateral shares held by this contract
        uint256 principal;    // USDC borrowed
        uint256 borrowedAt;
        bool active;
        // Depth-capped mark value of the FULL position at origination. Used to
        // split collateral on liquidation at a FIXED, manipulation-resistant
        // reference — never the live AMM spot, which a liquidator could push
        // down in-tx to over-seize the borrower's surplus.
        uint256 markValueAtBorrow;
    }
    mapping(address => Loan) public loans;

    // USDC supply side (mirrors CirqueLending).
    mapping(address => uint256) public shares;       // supplier LP shares
    uint256 public totalShares;
    uint256 public totalBorrowedPrincipal;
    uint256 public accruedInterestUSDC;
    uint256 public lastAccrualAt;
    /// @notice Cumulative principal written off as bad debt (transparency only).
    /// A non-zero value means suppliers absorbed a loss via reduced pool value.
    uint256 public totalBadDebtRealizedUSDC;
    /// @notice Idle USDC tracked by INTERNAL accounting, not USDC.balanceOf.
    /// Pool value reads this so a direct token donation cannot inflate the
    /// share price (the classic first-depositor / ERC4626 inflation attack).
    /// Updated on every supply/withdraw/borrow/repay/liquidate USDC flow.
    uint256 public idleUSDC;

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
    event BadDebtWrittenOff(address indexed user, uint256 principal, uint256 interest);

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
    error NotWriteOffable();
    error UseWriteOff();

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    constructor(IERC20 usdc, MarketsV3 markets, address owner, uint256 minPoolDepth) {
        if (minPoolDepth == 0) revert ZeroAmount();
        USDC = usdc;
        MARKETS = markets;
        OWNER = owner;
        MIN_POOL_DEPTH = minPoolDepth;
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
        idleUSDC += amount;
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(msg.sender, amount, sharesMinted);
    }

    function withdrawUSDC(uint256 shareAmount) external nonReentrant returns (uint256 usdcOut) {
        if (shareAmount == 0) revert ZeroAmount();
        if (shareAmount > shares[msg.sender]) revert InsufficientShares();
        _rollAccrual();
        uint256 pv = _totalPoolValueUSDC();
        usdcOut = (shareAmount * pv) / totalShares;
        if (usdcOut == 0) revert ZeroAmount();
        if (idleUSDC < usdcOut) revert InsufficientUSDCLiquidity();
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        // Realize this withdrawer's pro-rata slice of accrued (uncollected)
        // interest out of the counter so remaining suppliers don't double-count
        // it when borrowers later repay. Clamped against underflow.
        uint256 interestShare = pv == 0 ? 0 : (usdcOut * accruedInterestUSDC) / pv;
        if (interestShare > accruedInterestUSDC) interestShare = accruedInterestUSDC;
        accruedInterestUSDC -= interestShare;
        idleUSDC -= usdcOut;
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
        if (idleUSDC < usdcAmount) revert InsufficientUSDCLiquidity();

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
            active: true,
            markValueAtBorrow: _markValue(marketId, betYes, collateralShares)
        });
        totalBorrowedPrincipal += usdcAmount;

        openingHealthBps = _healthBps(loans[msg.sender]);
        if (openingHealthBps > MAX_LTV_BPS) revert LTVTooHigh();

        idleUSDC -= usdcAmount;
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
        idleUSDC += owed;

        USDC.safeTransferFrom(msg.sender, address(this), owed);

        // Return the collateral position.
        Markets.Outcome outcome = loan.betYes ? Markets.Outcome.Yes : Markets.Outcome.No;
        MARKETS.transferSharesFrom(loan.marketId, outcome, address(this), msg.sender, loan.shares);

        emit BetRepaid(msg.sender, loan.principal, interest, loan.shares);
    }

    /// @notice Liquidate a position that is either unhealthy (mark-based LTV >
    /// LIQ_LTV_BPS) OR within FORCE_CLOSE_WINDOW of expiry (the cliff guard —
    /// regardless of health). The liquidator repays debt + interest in USDC.
    ///
    /// FAIRNESS + INCENTIVE (HIGH fixes): the liquidator does NOT seize the
    /// whole position. They receive only enough shares to cover their payment
    /// plus a LIQ_BONUS_BPS (5%) reward; the SURPLUS is returned to the
    /// borrower. So:
    ///   - a profitable liquidation (collateral worth > owed×1.05) is always
    ///     attractive — the 5% bonus is the force-close incentive, no keeper
    ///     subsidy needed for in-the-money positions; and
    ///   - a healthy borrower force-closed near expiry keeps their upside —
    ///     they only forfeit owed + a 5% service fee, not the whole bet.
    ///
    /// Share valuation: while the market is Trading, value at the AMM mark
    /// (depth-cap-protected). Once Resolved, value at the ACTUAL payout
    /// (winning share = 1 USDC, losing = 0) — never the meaningless
    /// post-resolution priceOf.
    function liquidateBet(address borrower) external nonReentrant {
        Loan memory loan = loans[borrower];
        if (!loan.active) revert NoActiveLoan();
        _rollAccrual();

        Markets.Market memory m = MARKETS.getMarket(loan.marketId);
        bool resolved = m.phase == Markets.Phase.Resolved;
        // A resolved-LOSER position is worth $0 — liquidating it means paying
        // full `owed` in cash for worthless shares, a pure loss to the caller.
        // Route it to the (free, permissionless) writeOffBadDebt path instead,
        // so an automated keeper can never be tricked into donating `owed`.
        if (resolved && m.yesWon != loan.betYes) revert UseWriteOff();
        bool forced = block.timestamp + FORCE_CLOSE_WINDOW >= m.expiry || resolved;
        if (!forced && _healthBps(loan) <= LIQ_LTV_BPS) revert NotLiquidatable();

        uint256 interest = _interestOwed(loan);
        uint256 owed = loan.principal + interest;

        delete loans[borrower];
        totalBorrowedPrincipal -= loan.principal;
        accruedInterestUSDC = interest > accruedInterestUSDC ? 0 : accruedInterestUSDC - interest;
        idleUSDC += owed;

        USDC.safeTransferFrom(msg.sender, address(this), owed);

        // Split the collateral: the liquidator gets shares worth (owed + 5%
        // bonus); the borrower gets the surplus back.
        //
        // The valuation reference is FIXED, never the live AMM spot. Sizing the
        // liquidator's cut from `priceOf` would let the liquidator push the
        // collateral's spot price down in the same tx (buy the opposite
        // outcome), inflate their share count past the whole position, and
        // seize the borrower's surplus for the cost of AMM fees — defeating the
        // fairness this split exists to provide. Instead:
        //   • Resolved: winners redeem 1:1 USDC (Markets pays `balance` USDC per
        //     winning share, no haircut), so `reward` USDC == `reward` shares.
        //     Losers are worthless → liquidator takes the whole position (the
        //     accepted bad-debt/backstop case).
        //   • Trading: use markValueAtBorrow — the depth-capped value recorded
        //     at origination. It cannot be moved within the liquidation tx, so
        //     the split is manipulation-proof. shares-for-reward =
        //     reward × shares / markValueAtBorrow.
        Markets.Outcome outcome = loan.betYes ? Markets.Outcome.Yes : Markets.Outcome.No;
        uint256 reward = (owed * (BPS_DENOMINATOR + LIQ_BONUS_BPS)) / BPS_DENOMINATOR;
        uint256 liquidatorShares = _liquidatorShareCut(loan, reward, resolved, m.yesWon);
        if (liquidatorShares > loan.shares) liquidatorShares = loan.shares;
        uint256 borrowerShares = loan.shares - liquidatorShares;

        if (liquidatorShares > 0) {
            MARKETS.transferSharesFrom(loan.marketId, outcome, address(this), msg.sender, liquidatorShares);
        }
        if (borrowerShares > 0) {
            MARKETS.transferSharesFrom(loan.marketId, outcome, address(this), borrower, borrowerShares);
        }

        emit BetLiquidated(borrower, msg.sender, owed, liquidatorShares, forced);
    }

    /// @notice Realize an unrecoverable loan as bad debt, socializing the loss
    /// across suppliers via a reduced pool value. Permissionless (it only
    /// recognizes a loss that already exists — there is nothing to extract).
    ///
    /// WHY THIS EXISTS (MEDIUM finding #4 — bad-debt-blind pool value):
    /// `_totalPoolValueUSDC` counts `totalBorrowedPrincipal` at FACE value. For
    /// every healthy/winning/in-the-money loan that is fine — the depth cap,
    /// force-close window and keeper guarantee it is liquidated for full `owed`
    /// in cash before resolution, so principal is genuinely recoverable. The
    /// one exception is a loan whose market RESOLVES and whose side LOSES: the
    /// collateral is now worth exactly $0, so no liquidator will ever pay `owed`
    /// to seize it, yet the principal keeps counting as pool value. Left
    /// unaddressed, that phantom value lets a late withdrawer exit at an
    /// inflated share price and dump the loss on the remaining suppliers.
    ///
    /// This function writes the lost principal out of `totalBorrowedPrincipal`
    /// (and drops its accrued interest), so the pool value immediately and
    /// honestly reflects the loss for ALL suppliers pro-rata — closing the
    /// withdraw-race surface. The keeper calls it as soon as such a loss exists.
    ///
    /// Only resolved-LOSER loans qualify. Trading loans must go through normal
    /// liquidation; resolved-WINNER loans are valuable and a liquidator will
    /// profitably close them (pay `owed`, redeem shares at $1).
    function writeOffBadDebt(address borrower) external nonReentrant {
        Loan memory loan = loans[borrower];
        if (!loan.active) revert NoActiveLoan();
        if (!_isWriteOffable(loan)) revert NotWriteOffable();
        _rollAccrual();

        uint256 interest = _interestOwed(loan);
        delete loans[borrower];
        totalBorrowedPrincipal -= loan.principal;
        accruedInterestUSDC = interest > accruedInterestUSDC ? 0 : accruedInterestUSDC - interest;
        totalBadDebtRealizedUSDC += loan.principal;

        // The worthless collateral simply remains in this contract (redeemable
        // for $0). We stop counting the lost principal; the loss is socialized
        // across suppliers, who bore the lending risk.
        emit BadDebtWrittenOff(borrower, loan.principal, interest);
    }

    function _isWriteOffable(Loan memory loan) internal view returns (bool) {
        Markets.Market memory m = MARKETS.getMarket(loan.marketId);
        // Resolved AND the borrower's side lost → collateral worth $0.
        return m.phase == Markets.Phase.Resolved && (m.yesWon != loan.betYes);
    }

    /// @notice True if `borrower`'s loan is unrecoverable and should be written
    /// off (the keeper polls this alongside force-close liquidations).
    function isWriteOffable(address borrower) external view returns (bool) {
        Loan memory loan = loans[borrower];
        if (!loan.active) return false;
        return _isWriteOffable(loan);
    }

    /// @dev How many of the loan's shares the liquidator receives for a reward
    /// of `rewardUSDC`. Uses a FIXED reference (resolution payout, or the
    /// origination depth-capped mark) so it cannot be manipulated within the
    /// liquidation tx. The caller clamps the result to `loan.shares`.
    function _liquidatorShareCut(
        Loan memory loan,
        uint256 rewardUSDC,
        bool resolved,
        bool yesWon
    ) internal pure returns (uint256) {
        if (resolved) {
            bool won = (yesWon == loan.betYes);
            // Winning shares redeem 1:1 for USDC (both 6-dp), so shares needed
            // == rewardUSDC. Losing shares are worthless → no finite count
            // covers the reward; signal "take all" via max (clamped by caller).
            return won ? rewardUSDC : type(uint256).max;
        }
        // Trading: split against the origination value. value-per-share =
        // markValueAtBorrow / shares ⇒ shares for `rewardUSDC` =
        // rewardUSDC × shares / markValueAtBorrow. markValueAtBorrow is taken
        // at borrow time and never re-reads live spot, so a liquidator cannot
        // shift it. (markValueAtBorrow ≥ principal/0.4 > 0 by the LTV check at
        // origination, so the divide is safe.)
        return (rewardUSDC * loan.shares) / loan.markValueAtBorrow;
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
        return idleUSDC;
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

    /// @dev Pool value = idle cash + principal out on loan + interest accrued
    /// but not yet collected. Idle cash is the INTERNAL `idleUSDC` accumulator,
    /// never `USDC.balanceOf(this)` — a direct token donation must not be able
    /// to inflate the share price (first-depositor / ERC4626 inflation attack).
    /// `totalBorrowedPrincipal` is counted at face value; this is correct
    /// because every recoverable loan is liquidated for full `owed` in cash
    /// before resolution, and the ONE unrecoverable case — a resolved-loser
    /// loan — is removed from `totalBorrowedPrincipal` by writeOffBadDebt the
    /// moment the loss exists. So this figure carries no phantom value.
    function _totalPoolValueUSDC() internal view returns (uint256) {
        return idleUSDC + totalBorrowedPrincipal + accruedInterestUSDC;
    }
}
