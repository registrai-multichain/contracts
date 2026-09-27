// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {LaunchSchedule} from "../../script/lib/LaunchSchedule.sol";
import {FundKit} from "./FundKit.sol";

/// BuilderFund: income credited per builder per epoch by the markets, claimed
/// after the epoch with the progressive tax (to the SeasonPool), the 1% protocol
/// fee (of the after-tax income) and the net to the builder's payout. The test
/// contract plays MarketsPerennial (MARKETS_ROLE) and the Safe (GOVERNOR).
contract BuilderFundTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    SeasonPool pool;
    BuilderFund fund;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");
    uint256 aliceId;
    uint256 bobId;
    uint256 start;

    uint256 constant EPOCH = 30 days;
    uint256 constant U = 1e6;

    event IncomeCredited(uint256 indexed epoch, uint256 indexed builderId, uint256 amount);
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
    event ScheduleSet(uint256 indexed effectiveEpoch);
    event SeasonCredited(uint256 amount);

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        vm.prank(alice);
        (aliceId,) = builders.registerBuilderWithProject("", "github:alice/app");
        vm.prank(bob);
        (bobId,) = builders.registerBuilderWithProject("", "domain:bob.xyz");
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, treasury, EPOCH);
        FundKit.wire(fund, address(this));
        start = fund.START();

        usdc.mint(address(this), 10_000_000 * U);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(10_000_000 * U);
    }

    /// What MarketsPerennial does on a trade: pay the fund, then credit it.
    function _earn(uint256 id, uint256 amount) internal {
        ledger.internalTransfer(address(fund), amount);
        fund.credit(id, amount);
    }

    function _toEpochEnd(uint256 epoch) internal {
        vm.warp(fund.epochEnd(epoch));
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger insolvent");
        assertGe(ledger.balanceOf(address(fund)), fund.outstanding(), "fund below outstanding income");
        assertGe(ledger.balanceOf(address(pool)), pool.unallocated() + pool.reserved(), "pool below accounted");
    }

    function _b(uint128 upTo, uint16 rate) internal pure returns (BuilderFund.Bracket memory) {
        return BuilderFund.Bracket({upTo: upTo, rateBps: rate});
    }

    // ───────────────────────────── credit ─────────────────────────────

    function test_credit_onlyMarkets() public {
        bytes32 role = fund.MARKETS_ROLE();
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        fund.credit(aliceId, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        fund.creditSeason(1);
        vm.stopPrank();
        // only a MARKETS_ROLE holder (the admin grants it; the deploy script gives it to MarketsPerennial alone)
        FundKit.wire(fund, stranger);
        vm.prank(stranger);
        fund.credit(aliceId, 0);
    }

    function test_credit_attributesToCurrentEpochAndBuilder() public {
        ledger.internalTransfer(address(fund), 5 * U);
        vm.expectEmit(address(fund));
        emit IncomeCredited(0, aliceId, 5 * U);
        fund.credit(aliceId, 5 * U);
        _earn(aliceId, 2 * U);
        _earn(bobId, 1 * U);
        assertEq(fund.incomeOf(0, aliceId), 7 * U);
        assertEq(fund.incomeOf(0, bobId), 1 * U);
        assertEq(fund.outstanding(), 8 * U);
        assertEq(ledger.balanceOf(address(fund)), 8 * U);
        _solvent();
    }

    function test_credit_mustBeFunded() public {
        vm.expectRevert(BuilderFund.Unfunded.selector);
        fund.credit(aliceId, 1);
        _earn(aliceId, 10 * U);
        // creditSeason cannot dip into builders' income
        vm.expectRevert(BuilderFund.Unfunded.selector);
        fund.creditSeason(1);
        fund.credit(aliceId, 0); // zero is a no-op
        fund.creditSeason(0);
        assertEq(fund.outstanding(), 10 * U);
    }

    function test_creditSeason_forwardsToThePool() public {
        ledger.internalTransfer(address(fund), 3 * U);
        vm.expectEmit(address(fund));
        emit SeasonCredited(3 * U);
        fund.creditSeason(3 * U);
        assertEq(ledger.balanceOf(address(fund)), 0);
        assertEq(ledger.balanceOf(address(pool)), 3 * U);
        assertEq(pool.unallocated(), 3 * U);
        _solvent();
    }

    /// Trading must not stop because a builder was deactivated: its income
    /// still accrues, frozen until reactivated or swept.
    function test_credit_inactiveBuilderStillAccrues() public {
        builders.setActive(aliceId, false);
        _earn(aliceId, 4 * U);
        assertEq(fund.incomeOf(0, aliceId), 4 * U);
    }

    // ───────────────────────────── epochs ─────────────────────────────

    function test_epochBoundaries() public {
        assertEq(start, block.timestamp);
        assertEq(fund.EPOCH_LENGTH(), EPOCH);
        assertEq(fund.currentEpoch(), 0);
        assertEq(fund.epochEnd(0), start + EPOCH);
        assertEq(fund.epochEnd(4), start + 5 * EPOCH);

        vm.warp(start + EPOCH - 1);
        assertEq(fund.currentEpoch(), 0);
        _earn(aliceId, 1 * U); // last second of epoch 0
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.claimFor(0, aliceId);

        vm.warp(start + EPOCH);
        assertEq(fund.currentEpoch(), 1);
        _earn(aliceId, 2 * U); // first second of epoch 1
        assertEq(fund.incomeOf(0, aliceId), 1 * U);
        assertEq(fund.incomeOf(1, aliceId), 2 * U);
        fund.claimFor(0, aliceId); // epoch 0 has ended
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.claimFor(1, aliceId);

        vm.warp(start + 7 * EPOCH + 3);
        assertEq(fund.currentEpoch(), 7);
        fund.claimFor(1, aliceId); // no deadline on claims
    }

    function test_constructor_guards() public {
        BuilderFund.Bracket[] memory s = LaunchSchedule.brackets();
        vm.expectRevert(BuilderFund.ZeroEpochLength.selector);
        new BuilderFund(ledger, builders, caretakers, pool, treasury, address(this), 0, s);
        vm.expectRevert(BuilderFund.ZeroAddress.selector);
        new BuilderFund(ledger, builders, caretakers, pool, address(0), address(this), EPOCH, s);
        vm.expectRevert(BuilderFund.ZeroAddress.selector);
        new BuilderFund(ledger, builders, caretakers, SeasonPool(address(0)), treasury, address(this), EPOCH, s);
        s[0].rateBps = 1;
        vm.expectRevert(BuilderFund.BadFirstBracket.selector);
        new BuilderFund(ledger, builders, caretakers, pool, treasury, address(this), EPOCH, s);
    }

    // ───────────────────────────── tax ─────────────────────────────

    function test_tax_spec_examples() public view {
        BuilderFund.Bracket[] memory s = fund.scheduleFor(0);
        assertEq(fund.progressiveTax(800 * U, s), 0, "$800 -> $0");
        assertEq(fund.progressiveTax(60_000 * U, s), 11_900 * U, "$60,000 -> $11,900");
    }

    function test_tax_exactBracketEdges() public view {
        BuilderFund.Bracket[] memory s = fund.scheduleFor(0);
        assertEq(fund.progressiveTax(0, s), 0);
        assertEq(fund.progressiveTax(1_000 * U, s), 0, "top of the free bracket");
        assertEq(fund.progressiveTax(1_000 * U + 10, s), 1, "10 units at 10%");
        assertEq(fund.progressiveTax(10_000 * U, s), 900 * U, "9,000 at 10%");
        assertEq(fund.progressiveTax(10_000 * U + 10, s), 900 * U + 2, "10 units at 20%");
        assertEq(fund.progressiveTax(50_000 * U, s), 8_900 * U, "900 + 8,000");
        assertEq(fund.progressiveTax(50_000 * U + 10, s), 8_900 * U + 3, "10 units at 30%");
        assertEq(fund.progressiveTax(1_050_000 * U, s), 308_900 * U, "30% on the top slice");
        // floored per slice
        assertEq(fund.progressiveTax(1_000 * U + 9, s), 0);
    }

    /// Marginal: earning more never lowers take-home, and the average rate
    /// never exceeds the top marginal rate.
    function testFuzz_tax_monotonicTakeHome(uint256 a, uint256 b) public view {
        a = bound(a, 0, 10_000_000 * U);
        b = bound(b, a, 10_000_000 * U);
        BuilderFund.Bracket[] memory s = fund.scheduleFor(0);
        uint256 ta = fund.progressiveTax(a, s);
        uint256 tb = fund.progressiveTax(b, s);
        assertLe(ta, tb, "tax non-decreasing");
        assertLe(a - ta, b - tb, "take-home non-decreasing");
        assertLe(ta, (a * 3000) / 10_000, "average <= top rate");
    }

    // ───────────────────────────── claims ─────────────────────────────

    function test_claim_60k_taxFeeNet() public {
        _earn(aliceId, 60_000 * U);
        (uint256 g, uint256 t, uint256 f, uint256 n) = fund.quote(0, aliceId);
        assertEq(g, 60_000 * U);
        assertEq(t, 11_900 * U, "tax");
        assertEq(f, 481 * U, "1% of 48,100");
        assertEq(n, 47_619 * U, "net");
        _toEpochEnd(0);

        vm.expectEmit(address(fund));
        emit Claimed(0, aliceId, 60_000 * U, 11_900 * U, 481 * U, 47_619 * U, alice);
        vm.prank(stranger); // anyone may crank; the money goes to the builder
        uint256 net = fund.claimFor(0, aliceId);
        assertEq(net, 47_619 * U);
        assertEq(ledger.balanceOf(alice), 47_619 * U, "net to payout");
        assertEq(ledger.balanceOf(treasury), 481 * U, "fee to the protocol treasury");
        assertEq(ledger.balanceOf(address(pool)), 11_900 * U, "tax to the season pool");
        assertEq(pool.unallocated(), 11_900 * U, "and accounted there");
        assertEq(ledger.balanceOf(stranger), 0);
        assertEq(ledger.balanceOf(address(fund)), 0);
        assertEq(fund.outstanding(), 0);
        assertTrue(fund.claimed(0, aliceId));
        _solvent();
    }

    function test_claim_800_untaxed_onlyTheFee() public {
        _earn(bobId, 800 * U);
        _toEpochEnd(0);
        fund.claimFor(0, bobId);
        assertEq(ledger.balanceOf(bob), 792 * U);
        assertEq(ledger.balanceOf(treasury), 8 * U);
        assertEq(ledger.balanceOf(address(pool)), 0);
        assertEq(pool.unallocated(), 0);
    }

    function test_claim_dust_everyUnitAccounted() public {
        _earn(aliceId, 1);
        _earn(bobId, 1_000 * U + 99);
        _toEpochEnd(0);
        assertEq(fund.claimFor(0, aliceId), 1, "1 unit: no fee rounds out");
        fund.claimFor(0, bobId);
        uint256 paid = ledger.balanceOf(alice) + ledger.balanceOf(bob) + ledger.balanceOf(treasury)
            + ledger.balanceOf(address(pool));
        assertEq(paid, 1_000 * U + 100, "gross fully split");
        _solvent();
    }

    function test_claim_perEpochSeparately() public {
        _earn(aliceId, 10_000 * U); // epoch 0: tax 900
        vm.warp(fund.epochEnd(0));
        _earn(aliceId, 10_000 * U); // epoch 1: its own brackets, tax 900 again
        _toEpochEnd(1);
        fund.claimFor(0, aliceId);
        fund.claimFor(1, aliceId);
        assertEq(ledger.balanceOf(address(pool)), 1_800 * U, "brackets reset every epoch");
    }

    function test_claim_payoutRouting_setPayout_and_ownerChangeFallback() public {
        address cold = makeAddr("aliceCold");
        vm.prank(alice);
        caretakers.setPayout(aliceId, cold);
        _earn(aliceId, 100 * U);
        vm.warp(fund.epochEnd(0));
        _earn(aliceId, 100 * U);
        fund.claimFor(0, aliceId);
        assertEq(ledger.balanceOf(cold), 99 * U, "payout set by the owner");

        // alice transfers the builder to carol: the payout alice set is no longer
        // honoured; the claim falls back to the current owner
        vm.prank(alice);
        builders.proposeOwner(carol);
        vm.prank(carol);
        builders.acceptOwnership(aliceId);
        _toEpochEnd(1);
        vm.expectEmit(address(fund));
        emit Claimed(1, aliceId, 100 * U, 0, 1 * U, 99 * U, carol);
        fund.claimFor(1, aliceId);
        assertEq(ledger.balanceOf(carol), 99 * U, "fallback to the new owner");
        assertEq(ledger.balanceOf(cold), 99 * U, "old payout got nothing more");
    }

    function test_claim_refusals() public {
        _earn(aliceId, 5 * U);
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.claimFor(0, aliceId);
        _toEpochEnd(0);
        vm.expectRevert(BuilderFund.NoIncome.selector);
        fund.claimFor(0, bobId);
        vm.expectRevert(BuilderFund.NoIncome.selector);
        fund.claimFor(0, 99);
        fund.claimFor(0, aliceId);
        vm.expectRevert(BuilderFund.AlreadyClaimed.selector);
        fund.claimFor(0, aliceId);
    }

    // ───────────────────────── frozen builders ─────────────────────────

    function test_inactiveBuilder_claimReverts_sweepFrozen() public {
        _earn(aliceId, 60_000 * U);
        builders.setActive(aliceId, false);
        _toEpochEnd(0);
        vm.expectRevert(BuilderFund.BuilderInactive.selector);
        fund.claimFor(0, aliceId);

        bytes32 gov = fund.GOVERNOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, gov));
        fund.sweepFrozen(0, aliceId);

        vm.expectEmit(address(fund));
        emit FrozenSwept(0, aliceId, 60_000 * U);
        fund.sweepFrozen(0, aliceId);
        assertEq(ledger.balanceOf(address(pool)), 60_000 * U, "whole gross, untaxed, to the pool");
        assertEq(pool.unallocated(), 60_000 * U);
        assertEq(ledger.balanceOf(alice) + ledger.balanceOf(treasury), 0);
        assertTrue(fund.claimed(0, aliceId));
        vm.expectRevert(BuilderFund.AlreadyClaimed.selector);
        fund.sweepFrozen(0, aliceId);

        builders.setActive(aliceId, true); // reactivated: the swept epoch stays swept
        vm.expectRevert(BuilderFund.AlreadyClaimed.selector);
        fund.claimFor(0, aliceId);
        _solvent();
    }

    function test_sweepFrozen_refusals() public {
        _earn(aliceId, 5 * U);
        _earn(bobId, 5 * U);
        vm.expectRevert(BuilderFund.BuilderActive.selector);
        fund.sweepFrozen(0, aliceId);
        builders.setActive(aliceId, false);
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.sweepFrozen(0, aliceId);
        _toEpochEnd(0);
        vm.expectRevert(BuilderFund.NoIncome.selector);
        fund.sweepFrozen(0, 99); // never registered: inactive, no income
        fund.claimFor(0, bobId);
        builders.setActive(bobId, false);
        vm.expectRevert(BuilderFund.AlreadyClaimed.selector);
        fund.sweepFrozen(0, bobId);
    }

    function test_inactiveBuilder_reactivated_canClaim() public {
        _earn(aliceId, 5 * U);
        builders.setActive(aliceId, false);
        _toEpochEnd(0);
        vm.expectRevert(BuilderFund.BuilderInactive.selector);
        fund.claimFor(0, aliceId);
        builders.setActive(aliceId, true);
        fund.claimFor(0, aliceId);
        assertEq(ledger.balanceOf(alice), 495 * U / 100);
    }

    // ───────────────────────────── schedule ─────────────────────────────

    function _flat(uint16 topRate) internal pure returns (BuilderFund.Bracket[] memory s) {
        s = new BuilderFund.Bracket[](2);
        s[0] = BuilderFund.Bracket({upTo: 100e6, rateBps: 0});
        s[1] = BuilderFund.Bracket({upTo: type(uint128).max, rateBps: topRate});
    }

    function test_schedule_launchIsEpoch0_andSpecDefaults() public view {
        assertEq(fund.scheduleCount(), 1);
        (uint256 eff, BuilderFund.Bracket[] memory s) = fund.scheduleAt(0);
        assertEq(eff, 0);
        assertEq(s.length, 4);
        assertEq(s[0].upTo, 1_000e6);
        assertEq(s[0].rateBps, 0);
        assertEq(s[1].upTo, 10_000e6);
        assertEq(s[1].rateBps, 1000);
        assertEq(s[2].upTo, 50_000e6);
        assertEq(s[2].rateBps, 2000);
        assertEq(s[3].upTo, type(uint128).max);
        assertEq(s[3].rateBps, 3000);
        assertEq(fund.scheduleFor(1_000_000).length, 4);
    }

    function test_schedule_validation_everyRule() public {
        BuilderFund.Bracket[] memory s;

        s = new BuilderFund.Bracket[](0);
        vm.expectRevert(BuilderFund.BadBracketCount.selector);
        fund.setSchedule(s);

        s = new BuilderFund.Bracket[](9);
        for (uint256 i; i < 9; i++) {
            s[i] = _b(uint128(100e6 * (i + 1)), 0);
        }
        s[8].upTo = type(uint128).max;
        vm.expectRevert(BuilderFund.BadBracketCount.selector);
        fund.setSchedule(s);

        s = _flat(1000);
        s[0].rateBps = 1; // first bracket must be 0%
        vm.expectRevert(BuilderFund.BadFirstBracket.selector);
        fund.setSchedule(s);

        s = _flat(1000);
        s[0].upTo = 100e6 - 1; // first bracket must reach $100
        vm.expectRevert(BuilderFund.BadFirstBracket.selector);
        fund.setSchedule(s);

        s = _flat(1000);
        s[1].upTo = 1_000_000e6; // last must be max
        vm.expectRevert(BuilderFund.LastBracketNotMax.selector);
        fund.setSchedule(s);

        s = new BuilderFund.Bracket[](3);
        s[0] = _b(1_000e6, 0);
        s[1] = _b(1_000e6, 1000); // not strictly increasing
        s[2] = _b(type(uint128).max, 2000);
        vm.expectRevert(BuilderFund.BracketsNotIncreasing.selector);
        fund.setSchedule(s);

        s[1] = _b(500e6, 1000); // decreasing threshold
        vm.expectRevert(BuilderFund.BracketsNotIncreasing.selector);
        fund.setSchedule(s);

        s[1] = _b(5_000e6, 2000);
        s[2] = _b(type(uint128).max, 1000); // rate decreases
        vm.expectRevert(BuilderFund.RatesDecreasing.selector);
        fund.setSchedule(s);

        s = _flat(4001); // above 40%
        vm.expectRevert(BuilderFund.RateTooHigh.selector);
        fund.setSchedule(s);

        // the bounds themselves are allowed: 8 brackets, 40% top, a one-bracket 0% schedule
        s = new BuilderFund.Bracket[](8);
        for (uint256 i; i < 8; i++) {
            s[i] = _b(uint128(100e6 * (i + 1)), uint16(i * 500 > 4000 ? 4000 : i * 500));
        }
        s[7].upTo = type(uint128).max;
        fund.setSchedule(s);
        s = new BuilderFund.Bracket[](1);
        s[0] = _b(type(uint128).max, 0);
        fund.setSchedule(s);

        bytes32 gov = fund.GOVERNOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, gov));
        fund.setSchedule(s);
    }

    /// Two epochs' notice: a schedule set in epoch e applies from e + 2; the
    /// income of every earlier epoch keeps the schedule it was earned under.
    function test_schedule_twoEpochDelay_andHistoryFixed() public {
        vm.expectEmit(address(fund));
        emit ScheduleSet(3);
        fund.setSchedule(_flat(4000)); // in epoch 0 -> from epoch 3 (two FULL epochs of notice)
        assertEq(fund.scheduleFor(0)[1].rateBps, 1000, "epoch 0: launch");
        assertEq(fund.scheduleFor(2)[1].rateBps, 1000, "epoch 2: launch");
        assertEq(fund.scheduleFor(3)[1].rateBps, 4000, "epoch 3: new");
        assertEq(fund.scheduleFor(99)[1].rateBps, 4000);

        _earn(aliceId, 2_000 * U); // epoch 0, launch: 10% of 1,000
        vm.warp(fund.epochEnd(0));
        _earn(aliceId, 2_000 * U); // epoch 1, launch
        vm.warp(fund.epochEnd(2));
        _earn(aliceId, 2_000 * U); // epoch 3, new: 40% of 1,900

        vm.warp(fund.epochEnd(3));
        fund.setSchedule(_flat(0)); // epoch 4 -> from 7; history untouched
        assertEq(fund.scheduleFor(3)[1].rateBps, 4000, "epoch 3 kept its schedule");
        (,, uint256 f0,) = fund.quote(0, aliceId);
        (, uint256 t0,,) = fund.quote(0, aliceId);
        (, uint256 t1,,) = fund.quote(1, aliceId);
        (, uint256 t3,,) = fund.quote(3, aliceId);
        assertEq(t0, 100 * U);
        assertEq(f0, 19 * U);
        assertEq(t1, 100 * U);
        assertEq(t3, 760 * U);
        fund.claimFor(3, aliceId);
        assertEq(ledger.balanceOf(address(pool)), 760 * U);
        assertEq(fund.scheduleCount(), 3);
        (uint256 eff,) = fund.scheduleAt(2);
        assertEq(eff, 7);
    }

    /// A second setSchedule in the same epoch replaces the pending one; one
    /// already announced for the next epoch is final and stays.
    function test_schedule_pendingReplacement() public {
        fund.setSchedule(_flat(2000)); // epoch 0 -> 3
        fund.setSchedule(_flat(2500)); // epoch 0 -> 3: replaces
        assertEq(fund.scheduleCount(), 2, "replaced, not appended");
        assertEq(fund.scheduleFor(3)[1].rateBps, 2500);
        assertEq(fund.scheduleFor(3).length, 2);

        // replacing with a longer schedule leaves no stale brackets
        fund.setSchedule(LaunchSchedule.brackets());
        assertEq(fund.scheduleFor(3).length, 4);
        fund.setSchedule(_flat(2500));
        assertEq(fund.scheduleFor(3).length, 2);

        vm.warp(fund.epochEnd(0)); // epoch 1: the epoch-3 schedule is now final
        fund.setSchedule(_flat(3500)); // -> 4, appended
        assertEq(fund.scheduleCount(), 3);
        assertEq(fund.scheduleFor(2)[1].rateBps, 1000, "epoch 2: launch");
        assertEq(fund.scheduleFor(3)[1].rateBps, 2500, "epoch 3: final");
        assertEq(fund.scheduleFor(4)[1].rateBps, 3500, "epoch 4: pending");
        fund.setSchedule(_flat(3000)); // same epoch: replaces the epoch-4 one only
        assertEq(fund.scheduleCount(), 3);
        assertEq(fund.scheduleFor(3)[1].rateBps, 2500);
        assertEq(fund.scheduleFor(4)[1].rateBps, 3000);
    }
}
