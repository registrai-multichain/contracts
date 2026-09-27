// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {NanoLedger} from "../nanopay/NanoLedger.sol";
import {BuilderRegistry} from "./BuilderRegistry.sol";
import {CaretakerRegistry} from "./CaretakerRegistry.sol";
import {SeasonPool} from "./SeasonPool.sol";

/// @title BuilderFund. Builder income from the Perennial markets, taxed
/// progressively per epoch.
/// @notice MarketsPerennial (MARKETS_ROLE) pays the 50% builder leg of every
/// trading fee into this contract's NanoLedger account and `credit`s it to the
/// builder the market is about, for the current epoch. Epochs are time-based
/// (`(t - START) / EPOCH_LENGTH`); nothing closes them.
///
/// Once an epoch has ended, anyone may `claimFor(epoch, builderId)`; it pays what
/// of that epoch's income is still unpaid:
///   unpaid = income of the builder in that epoch - what was already paid
///   tax    = progressiveTax(income) - progressiveTax(paid)      -> SeasonPool
///   fee    = 1% of (unpaid - tax)                               -> PROTOCOL_TREASURY
///   net    = unpaid - tax - fee        -> CaretakerRegistry.payoutOf(builderId)
/// Late income (LATE_ROLE: the WonderEscrow releasing a team's escrow) is credited
/// to the ENDED epoch it was earned in, so it is taxed under that epoch's brackets
/// together with the rest of that epoch's income, as if paid on time (audit
/// 2026-09-27); an epoch already claimed is then claimable again for the rest,
/// taxed at the margin.
/// The payout resolves at claim time, so the owner-change fallback of the
/// CaretakerRegistry applies (a recovered builder is never paid to an address
/// the old key chose).
///
/// A deactivated builder's claim reverts; the Safe (GOVERNOR) may then
/// `sweepFrozen` that income to the SeasonPool, or reactivate the builder.
///
/// Tax schedule: up to MAX_BRACKETS marginal brackets (upTo, rateBps) on a
/// builder's income per epoch. A new schedule takes effect in epoch
/// currentEpoch + SCHEDULE_DELAY + 1, so it is always announced at least
/// SCHEDULE_DELAY (2) FULL epochs ahead, whenever in an epoch it is set. Only a
/// schedule pending for that same epoch can be replaced (the replacement gets the
/// same full notice); one announced earlier is final. Bounds: 1..8 brackets, `upTo` strictly
/// increasing with the last at type(uint128).max, rates non-decreasing and
/// <= MAX_RATE_BPS (40%), the first bracket 0% up to at least MIN_FREE_UPTO.
///
/// Solvency: `outstanding` is income credited and not yet claimed or swept;
/// the fund's ledger balance always covers it (checked on every credit).
contract BuilderFund is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MARKETS_ROLE = keccak256("MARKETS_ROLE");
    /// @notice May credit income to an ended epoch (the WonderEscrow, releasing a
    /// team's escrow to the epochs it was earned in).
    bytes32 public constant LATE_ROLE = keccak256("LATE_ROLE");

    /// @notice Registrai's 1% of every builder payout (of the after-tax income).
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BRACKETS = 8;
    uint256 public constant MAX_RATE_BPS = 4000;
    /// @notice The first bracket must be tax-free up to at least $100.
    uint256 public constant MIN_FREE_UPTO = 100e6;
    /// @notice Full epochs of notice for a new schedule (it applies from epoch e + SCHEDULE_DELAY + 1).
    uint256 public constant SCHEDULE_DELAY = 2;

    NanoLedger public immutable LEDGER;
    BuilderRegistry public immutable BUILDERS;
    CaretakerRegistry public immutable CARETAKERS;
    address public immutable PROTOCOL_TREASURY;
    SeasonPool public immutable SEASON_POOL;
    uint256 public immutable START;
    uint256 public immutable EPOCH_LENGTH;

    struct Bracket {
        uint128 upTo; // upper bound of the income slice (6-dec USDC); last = type(uint128).max
        uint16 rateBps; // marginal rate on the slice
    }

    /// @notice epoch => builderId => income credited in that epoch.
    mapping(uint256 => mapping(uint256 => uint256)) public incomeOf;
    /// @notice epoch => builderId => income already paid out (claimed or swept).
    mapping(uint256 => mapping(uint256 => uint256)) public paidGross;
    /// @notice Income credited and not yet claimed or swept.
    uint256 public outstanding;

    /// Schedule history, ascending by effective epoch; entry 0 is the launch
    /// schedule (effective from epoch 0).
    uint256[] internal _effectiveFrom;
    mapping(uint256 => Bracket[]) internal _brackets; // history index => brackets

    event IncomeCredited(uint256 indexed epoch, uint256 indexed builderId, uint256 amount);
    event SeasonCredited(uint256 amount);
    event Claimed(
        uint256 indexed epoch,
        uint256 indexed builderId,
        uint256 gross,
        uint256 tax,
        uint256 fee,
        uint256 net,
        address payout
    );
    event FrozenSwept(uint256 indexed epoch, uint256 indexed builderId, uint256 gross);
    event LateIncomeCredited(uint256 indexed epoch, uint256 indexed builderId, uint256 amount);
    event Skimmed(uint256 amount);
    event ScheduleSet(uint256 indexed effectiveEpoch);

    error ZeroAddress();
    error ZeroEpochLength();
    error Unfunded();
    error EpochNotEnded();
    error AlreadyClaimed();
    error NoIncome();
    error BuilderInactive();
    error BuilderActive();
    error BadBracketCount();
    error BracketsNotIncreasing();
    error LastBracketNotMax();
    error RatesDecreasing();
    error RateTooHigh();
    error BadFirstBracket();

    constructor(
        NanoLedger ledger_,
        BuilderRegistry builders_,
        CaretakerRegistry caretakers_,
        SeasonPool seasonPool_,
        address protocolTreasury_,
        address admin,
        uint256 epochLength_,
        Bracket[] memory launchSchedule
    ) {
        if (
            address(ledger_) == address(0) || address(builders_) == address(0) || address(caretakers_) == address(0)
                || address(seasonPool_) == address(0) || protocolTreasury_ == address(0) || admin == address(0)
        ) revert ZeroAddress();
        if (epochLength_ == 0) revert ZeroEpochLength();
        LEDGER = ledger_;
        BUILDERS = builders_;
        CARETAKERS = caretakers_;
        SEASON_POOL = seasonPool_;
        PROTOCOL_TREASURY = protocolTreasury_;
        START = block.timestamp;
        EPOCH_LENGTH = epochLength_;
        _validate(launchSchedule);
        _effectiveFrom.push(0);
        _store(0, launchSchedule);
        emit ScheduleSet(0);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ───────────────────────────── income ─────────────────────────────

    /// @notice Attribute `amount`, already moved to this contract's ledger
    /// account by the caller, to `builderId`'s income for the current epoch.
    /// Never reverts on the builder's status: trading must not stop because a
    /// builder was deactivated (its income is then frozen, see sweepFrozen).
    function credit(uint256 builderId, uint256 amount) external onlyRole(MARKETS_ROLE) {
        if (amount == 0) return;
        uint256 epoch = currentEpoch();
        incomeOf[epoch][builderId] += amount;
        outstanding += amount;
        if (LEDGER.balanceOf(address(this)) < outstanding) revert Unfunded();
        emit IncomeCredited(epoch, builderId, amount);
    }

    /// @notice Attribute `amount`, already moved to this contract's ledger account
    /// by the caller, to `builderId`'s income for the ENDED epoch `epoch` (a team's
    /// escrow released to the epochs it was earned in). LATE_ROLE only.
    function creditLate(uint256 builderId, uint256 epoch, uint256 amount) external onlyRole(LATE_ROLE) {
        if (amount == 0) return;
        if (block.timestamp < epochEnd(epoch)) revert EpochNotEnded();
        incomeOf[epoch][builderId] += amount;
        outstanding += amount;
        if (LEDGER.balanceOf(address(this)) < outstanding) revert Unfunded();
        emit LateIncomeCredited(epoch, builderId, amount);
    }

    /// @notice Forward `amount`, already moved to this contract's ledger account
    /// by the caller, to the SeasonPool (a voided market's unclaimed agent escrow).
    function creditSeason(uint256 amount) external onlyRole(MARKETS_ROLE) {
        if (amount == 0) return;
        if (LEDGER.balanceOf(address(this)) < outstanding + amount) revert Unfunded();
        _toSeason(amount);
        emit SeasonCredited(amount);
    }

    // ───────────────────────────── claims ─────────────────────────────

    /// @notice Pay a builder's income of an ended epoch: tax to the SeasonPool,
    /// 1% of the rest to the protocol treasury, the net to the builder's payout.
    /// Permissionless, once per (epoch, builder). Returns the net.
    function claimFor(uint256 epoch, uint256 builderId) external returns (uint256 net) {
        if (block.timestamp < epochEnd(epoch)) revert EpochNotEnded();
        uint256 income = incomeOf[epoch][builderId];
        if (income == 0) revert NoIncome();
        uint256 paid = paidGross[epoch][builderId];
        if (paid == income) revert AlreadyClaimed();
        if (!BUILDERS.isActiveBuilderId(builderId)) revert BuilderInactive();
        address payout = CARETAKERS.payoutOf(builderId);
        if (payout == address(0)) revert BuilderInactive();

        uint256 gross = income - paid;
        uint256 tax;
        uint256 fee;
        (tax, fee, net) = _splitIncrement(income, paid, epoch);
        paidGross[epoch][builderId] = income;
        outstanding -= gross;

        if (net > 0) LEDGER.internalTransfer(payout, net);
        if (fee > 0) LEDGER.internalTransfer(PROTOCOL_TREASURY, fee);
        if (tax > 0) _toSeason(tax);
        emit Claimed(epoch, builderId, gross, tax, fee, net, payout);
    }

    /// @notice Move a deactivated builder's unclaimed income of an ended epoch,
    /// untaxed and whole, to the SeasonPool. GOVERNOR only.
    function sweepFrozen(uint256 epoch, uint256 builderId) external onlyRole(GOVERNOR_ROLE) {
        if (BUILDERS.isActiveBuilderId(builderId)) revert BuilderActive();
        if (block.timestamp < epochEnd(epoch)) revert EpochNotEnded();
        uint256 income = incomeOf[epoch][builderId];
        if (income == 0) revert NoIncome();
        uint256 paid = paidGross[epoch][builderId];
        if (paid == income) revert AlreadyClaimed();
        uint256 gross = income - paid;
        paidGross[epoch][builderId] = income;
        outstanding -= gross;
        _toSeason(gross);
        emit FrozenSwept(epoch, builderId, gross);
    }

    /// @notice Send the fund's stray balance (anything above `outstanding`, which
    /// no credit accounted for: a donation, a builder paying itself here) to the
    /// SeasonPool. Permissionless; never touches owed income.
    function skim() external returns (uint256 amount) {
        uint256 bal = LEDGER.balanceOf(address(this));
        if (bal <= outstanding) return 0;
        amount = bal - outstanding;
        _toSeason(amount);
        emit Skimmed(amount);
    }

    /// @notice True when `builderId`'s income of `epoch` has been fully paid out
    /// (claimed or swept) and nothing is unpaid; late income makes it false again.
    function claimed(uint256 epoch, uint256 builderId) external view returns (bool) {
        uint256 income = incomeOf[epoch][builderId];
        return income > 0 && paidGross[epoch][builderId] == income;
    }

    function _toSeason(uint256 amount) internal {
        LEDGER.internalTransfer(address(SEASON_POOL), amount);
        SEASON_POOL.fund(amount);
    }

    function _split(uint256 gross, uint256 epoch) internal view returns (uint256 tax, uint256 fee, uint256 net) {
        return _splitIncrement(gross, 0, epoch);
    }

    /// @dev The split of the unpaid part (income - paid) of an epoch's income: the
    /// tax is the marginal tax of that slice on top of what was already paid.
    function _splitIncrement(uint256 income, uint256 paid, uint256 epoch)
        internal
        view
        returns (uint256 tax, uint256 fee, uint256 net)
    {
        Bracket[] memory b = _brackets[_scheduleIndex(epoch)];
        uint256 unpaid = income - paid;
        tax = progressiveTax(income, b) - progressiveTax(paid, b);
        if (tax > unpaid) tax = unpaid; // per-slice flooring can never tax beyond the slice
        fee = ((unpaid - tax) * PROTOCOL_FEE_BPS) / BPS;
        net = unpaid - tax - fee;
    }

    // ───────────────────────────── schedule ─────────────────────────────

    /// @notice Set the tax schedule for currentEpoch() + SCHEDULE_DELAY + 1 onward:
    /// at least SCHEDULE_DELAY full epochs of notice. Replaces a schedule still
    /// pending for that same epoch; one announced for an earlier epoch is final.
    function setSchedule(Bracket[] calldata brackets) external onlyRole(GOVERNOR_ROLE) {
        Bracket[] memory b = brackets;
        _validate(b);
        uint256 effective = currentEpoch() + SCHEDULE_DELAY + 1;
        uint256 last = _effectiveFrom.length - 1;
        if (_effectiveFrom[last] == effective) {
            delete _brackets[last];
            _store(last, b);
        } else {
            _effectiveFrom.push(effective);
            _store(last + 1, b);
        }
        emit ScheduleSet(effective);
    }

    function _store(uint256 index, Bracket[] memory b) internal {
        Bracket[] storage s = _brackets[index];
        for (uint256 i; i < b.length; i++) {
            s.push(b[i]);
        }
    }

    function _validate(Bracket[] memory b) internal pure {
        uint256 n = b.length;
        if (n == 0 || n > MAX_BRACKETS) revert BadBracketCount();
        if (b[0].rateBps != 0 || b[0].upTo < MIN_FREE_UPTO) revert BadFirstBracket();
        if (b[n - 1].upTo != type(uint128).max) revert LastBracketNotMax();
        for (uint256 i; i < n; i++) {
            if (b[i].rateBps > MAX_RATE_BPS) revert RateTooHigh();
            if (i > 0) {
                if (b[i].upTo <= b[i - 1].upTo) revert BracketsNotIncreasing();
                if (b[i].rateBps < b[i - 1].rateBps) revert RatesDecreasing();
            }
        }
    }

    /// @dev History index of the schedule in force in `epoch`.
    function _scheduleIndex(uint256 epoch) internal view returns (uint256 i) {
        i = _effectiveFrom.length - 1;
        while (_effectiveFrom[i] > epoch) i--; // entry 0 is effective from epoch 0
    }

    /// @notice Marginal tax on `gross` under `brackets`: each rate applies only
    /// to the slice of income inside its bracket (floored per slice). Income
    /// above the last `upTo` is taxed at the last rate.
    function progressiveTax(uint256 gross, Bracket[] memory brackets) public pure returns (uint256 tax) {
        uint256 lower;
        uint256 n = brackets.length;
        for (uint256 i; i < n && gross > lower; i++) {
            uint256 upper = i == n - 1 ? type(uint256).max : brackets[i].upTo;
            uint256 top = gross < upper ? gross : upper;
            tax += ((top - lower) * brackets[i].rateBps) / BPS;
            lower = upper;
        }
    }

    // ───────────────────────────── views ─────────────────────────────

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - START) / EPOCH_LENGTH;
    }

    /// @notice First second after `epoch`: its income is claimable from then on.
    function epochEnd(uint256 epoch) public view returns (uint256) {
        return START + (epoch + 1) * EPOCH_LENGTH;
    }

    /// @notice The tax schedule of `epoch` (as announced; a future epoch's may
    /// still change while it is pending, see setSchedule).
    function scheduleFor(uint256 epoch) external view returns (Bracket[] memory) {
        return _brackets[_scheduleIndex(epoch)];
    }

    /// @notice Number of schedules in the history (the launch schedule is #0).
    function scheduleCount() external view returns (uint256) {
        return _effectiveFrom.length;
    }

    /// @notice Schedule #`index` of the history and the epoch it applies from.
    function scheduleAt(uint256 index) external view returns (uint256 effectiveEpoch, Bracket[] memory brackets) {
        return (_effectiveFrom[index], _brackets[index]);
    }

    /// @notice What claimFor(epoch, builderId) would split the builder's unpaid
    /// income of `epoch` into (independent of whether the epoch has ended yet).
    function quote(uint256 epoch, uint256 builderId)
        external
        view
        returns (uint256 gross, uint256 tax, uint256 fee, uint256 net)
    {
        uint256 income = incomeOf[epoch][builderId];
        uint256 paid = paidGross[epoch][builderId];
        gross = income - paid;
        (tax, fee, net) = _splitIncrement(income, paid, epoch);
    }
}
