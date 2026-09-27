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

/// Late income (audit 2026-09-27, owner decision): a team's escrow released after
/// months is credited to the epochs it was EARNED in and taxed there, as if it had
/// been paid on time. claimFor pays whatever of an ended epoch is unpaid, taxed
/// incrementally: tax(all income of the epoch) - tax(what was already paid).
contract BuilderFundLateTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    SeasonPool pool;
    BuilderFund fund;

    address treasury = makeAddr("protocolTreasury");
    address alice = makeAddr("alice");
    address late = makeAddr("escrow");
    uint256 aliceId;
    uint256 T0;
    uint256 constant EPOCH = 30 days;
    uint256 constant U = 1e6;

    function setUp() public {
        vm.warp(1_800_000_000);
        T0 = block.timestamp;
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        pool = new SeasonPool(ledger, builders, caretakers, address(this));
        fund = new BuilderFund(ledger, builders, caretakers, pool, treasury, address(this), EPOCH, LaunchSchedule.brackets());
        pool.grantRole(pool.FUNDER_ROLE(), address(fund));
        fund.grantRole(fund.MARKETS_ROLE(), address(this));
        fund.grantRole(fund.LATE_ROLE(), late);
        vm.prank(alice);
        (aliceId,) = builders.registerBuilderWithProject("", "github:alice/app");
        usdc.mint(address(this), 10_000_000 * U);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(10_000_000 * U);
        ledger.internalTransfer(late, 1_000_000 * U);
    }

    function _tax(uint256 gross) internal view returns (uint256) {
        return fund.progressiveTax(gross, LaunchSchedule.brackets());
    }

    function _earn(uint256 amount) internal {
        ledger.internalTransfer(address(fund), amount);
        fund.credit(aliceId, amount);
    }

    function _late(uint256 epoch, uint256 amount) internal {
        vm.startPrank(late);
        ledger.internalTransfer(address(fund), amount);
        fund.creditLate(aliceId, epoch, amount);
        vm.stopPrank();
    }

    function _paid() internal view returns (uint256) {
        return ledger.balanceOf(alice);
    }

    function test_lateIncomeIntoAnUnclaimedEpoch_isTaxedWithThatEpochsIncome() public {
        _earn(5_000 * U); // epoch 0
        vm.warp(T0 + 3 * EPOCH);
        _late(0, 5_000 * U);
        uint256 net = fund.claimFor(0, aliceId);
        uint256 tax = _tax(10_000 * U);
        uint256 fee = (10_000 * U - tax) / 100;
        assertEq(net, 10_000 * U - tax - fee);
        assertTrue(fund.claimed(0, aliceId));
        assertEq(fund.outstanding(), 0);
    }

    function test_lateIncomeIntoAClaimedEpoch_paysOnlyTheIncrement_taxedAtTheMargin() public {
        _earn(5_000 * U);
        vm.warp(T0 + EPOCH);
        uint256 first = fund.claimFor(0, aliceId);
        assertTrue(fund.claimed(0, aliceId));
        vm.warp(T0 + 4 * EPOCH);
        _late(0, 5_000 * U);
        assertFalse(fund.claimed(0, aliceId), "unpaid income again");
        uint256 second = fund.claimFor(0, aliceId);
        // together exactly as if the 10k had been claimed at once
        uint256 tax = _tax(10_000 * U);
        uint256 fee = (10_000 * U - tax) / 100;
        assertApproxEqAbs(first + second, 10_000 * U - tax - fee, 1, "no extra tax from paying in two parts");
        assertEq(fund.paidGross(0, aliceId), 10_000 * U);
        vm.expectRevert(BuilderFund.AlreadyClaimed.selector);
        fund.claimFor(0, aliceId);
    }

    function test_sixMonthsReleasedLate_payTheSameTaxAsPaidOnTime() public {
        // on time: 10k per epoch, each claimed after its epoch
        uint256 onTimeTax = 6 * _tax(10_000 * U);
        // late: all six credited in epoch 7 to their own epochs
        vm.warp(T0 + 7 * EPOCH);
        uint256 before = _paid();
        for (uint256 e; e < 6; e++) _late(e, 10_000 * U);
        uint256 seasonBefore = ledger.balanceOf(address(pool));
        for (uint256 e; e < 6; e++) fund.claimFor(e, aliceId);
        assertEq(ledger.balanceOf(address(pool)) - seasonBefore, onTimeTax, "taxed per epoch earned");
        assertGt(_paid(), before);
    }

    function test_creditLate_onlyForEndedEpochs_andOnlyTheLateRole() public {
        vm.warp(T0 + 2 * EPOCH + 1);
        vm.startPrank(late);
        ledger.internalTransfer(address(fund), 3 * U);
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.creditLate(aliceId, 2, 1 * U); // the current epoch
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.creditLate(aliceId, 9, 1 * U);
        vm.stopPrank();
        ledger.internalTransfer(address(fund), 1 * U);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), fund.LATE_ROLE()));
        fund.creditLate(aliceId, 0, 1 * U);
    }

    function test_creditLate_mustBeFunded() public {
        vm.warp(T0 + 2 * EPOCH);
        vm.prank(late);
        vm.expectRevert(BuilderFund.Unfunded.selector);
        fund.creditLate(aliceId, 0, 1 * U);
    }

    function test_sweepFrozen_movesOnlyTheUnpaidPart() public {
        _earn(5_000 * U);
        vm.warp(T0 + EPOCH);
        fund.claimFor(0, aliceId);
        vm.warp(T0 + 3 * EPOCH);
        _late(0, 2_000 * U);
        builders.setActive(aliceId, false);
        uint256 poolBefore = ledger.balanceOf(address(pool));
        fund.sweepFrozen(0, aliceId);
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 2_000 * U);
        assertEq(fund.outstanding(), 0);
        assertTrue(fund.claimed(0, aliceId));
    }

    function test_skim_sendsOnlyTheStrayBalanceToTheSeasonPool() public {
        _earn(1_000 * U);
        ledger.internalTransfer(address(fund), 7 * U); // a donation, credited to nobody
        uint256 poolBefore = ledger.balanceOf(address(pool));
        assertEq(fund.skim(), 7 * U);
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 7 * U);
        assertEq(ledger.balanceOf(address(fund)), fund.outstanding());
        assertEq(fund.skim(), 0);
    }

    function test_aScheduleAlwaysGetsTwoFullEpochsOfNotice() public {
        BuilderFund.Bracket[] memory b = LaunchSchedule.brackets();
        // announced at the last second of epoch 0
        vm.warp(T0 + EPOCH - 1);
        fund.setSchedule(b);
        (uint256 effective,) = fund.scheduleAt(fund.scheduleCount() - 1);
        assertGe(fund.epochEnd(effective - 1) - block.timestamp, 2 * EPOCH, "at least two full epochs");
        // a replacement is announced no sooner than two full epochs ahead either
        vm.warp(T0 + EPOCH + EPOCH - 1);
        fund.setSchedule(b);
        (uint256 effective2,) = fund.scheduleAt(fund.scheduleCount() - 1);
        assertGe(fund.epochEnd(effective2 - 1) - block.timestamp, 2 * EPOCH);
    }
}
