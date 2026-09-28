// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {LaunchSchedule} from "../../script/lib/LaunchSchedule.sol";

/// Shared phase-2 stack: Safe = admin/REGISTRAR/GOVERNOR/ISSUER everywhere,
/// operator = caretaker + badge STATUS (runbook layout); `markets` stands in for
/// MarketsPerennial (the fund's MARKETS_ROLE).
abstract contract BuilderStack is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    VerifiedBuilderBadge badge;
    SeasonPool pool;
    BuilderFund fund;

    address safe = makeAddr("safe");
    address operator = makeAddr("operator");
    address markets = makeAddr("markets");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant EPOCH = 7 days;

    function _deployStack() internal {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(safe);
        caretakers = new CaretakerRegistry(builders, safe);
        badge = new VerifiedBuilderBadge(builders, safe, operator, "Arc", "img/", "ext/");
        pool = new SeasonPool(ledger, builders, caretakers, safe);
        fund = new BuilderFund(ledger, builders, caretakers, pool, treasury, safe, EPOCH, 0, LaunchSchedule.brackets());
        vm.startPrank(safe);
        pool.grantRole(pool.FUNDER_ROLE(), address(fund));
        fund.grantRole(fund.MARKETS_ROLE(), markets);
        vm.stopPrank();
        usdc.mint(markets, 10_000_000e6);
        vm.startPrank(markets);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(10_000_000e6);
        vm.stopPrank();
    }

    /// The builder leg of a market's fees, as MarketsPerennial pays it.
    function _earn(uint256 id, uint256 amount) internal {
        vm.startPrank(markets);
        ledger.internalTransfer(address(fund), amount);
        fund.credit(id, amount);
        vm.stopPrank();
    }

    function _onboard(uint256 id) internal returns (uint256 serial) {
        vm.startPrank(safe);
        caretakers.setCaretaker(id, operator);
        serial = badge.issue(id);
        vm.stopPrank();
    }

    function _endEpoch() internal {
        vm.warp(fund.epochEnd(fund.currentEpoch()));
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
        assertGe(ledger.balanceOf(address(fund)), fund.outstanding(), "fund below income");
    }
}

contract BuilderIdKeyedTest is BuilderStack {
    uint256 aliceId;
    uint256 bobId;

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

    function setUp() public {
        _deployStack();
        vm.prank(alice);
        (aliceId,) = builders.registerBuilderWithProject("", "github:alice/app");
        vm.prank(bob);
        (bobId,) = builders.registerBuilderWithProject("", "domain:bob.xyz");
        vm.startPrank(safe);
        caretakers.setCaretaker(aliceId, operator);
        caretakers.setCaretaker(bobId, operator);
        vm.stopPrank();
    }

    function test_income_byBuilderId_events() public {
        vm.prank(markets);
        ledger.internalTransfer(address(fund), 7e6);
        vm.expectEmit(address(fund));
        emit IncomeCredited(0, aliceId, 7e6);
        vm.prank(markets);
        fund.credit(aliceId, 7e6);
        assertEq(fund.incomeOf(0, aliceId), 7e6);
        assertEq(fund.incomeOf(0, bobId), 0);
    }

    /// The caretaker is not an input to the money: changing it (or having
    /// none) changes neither income nor payout.
    function test_caretakerIsNotAMoneyInput() public {
        _earn(aliceId, 100e6);
        vm.prank(safe);
        caretakers.setCaretaker(aliceId, makeAddr("otherOp"));
        address dave = makeAddr("dave");
        vm.prank(dave);
        (uint256 noCareId,) = builders.registerBuilderWithProject("", "github:dave/x"); // no caretaker at all
        _earn(noCareId, 50e6);
        _endEpoch();
        fund.claimFor(0, aliceId);
        fund.claimFor(0, noCareId);
        assertEq(ledger.balanceOf(alice), 99e6);
        assertEq(ledger.balanceOf(dave), 495e5);
        assertEq(ledger.balanceOf(operator) + ledger.balanceOf(makeAddr("otherOp")), 0);
    }

    function test_ownerChange_doesNotTouchIncome() public {
        _earn(aliceId, 5e6);
        vm.prank(alice);
        builders.proposeOwner(carol);
        vm.prank(carol);
        builders.acceptOwnership(aliceId);
        _earn(aliceId, 1e6); // the market names the id: the owner change is irrelevant
        assertEq(fund.incomeOf(0, aliceId), 6e6);
    }

    function test_claimFor_byId_anyone() public {
        _earn(aliceId, 750e6);
        _earn(bobId, 250e6);
        _endEpoch();
        (,,, uint256 netA) = fund.quote(0, aliceId);
        assertEq(netA, 7425e5);

        vm.expectEmit(address(fund));
        emit Claimed(0, aliceId, 750e6, 0, 75e5, 7425e5, alice);
        vm.prank(makeAddr("anyone"));
        uint256 a = fund.claimFor(0, aliceId);
        assertEq(a, 7425e5);
        assertTrue(fund.claimed(0, aliceId));
        assertEq(ledger.balanceOf(alice), 7425e5);
        vm.expectRevert(BuilderFund.AlreadyClaimed.selector);
        fund.claimFor(0, aliceId);
        vm.expectRevert(BuilderFund.NoIncome.selector);
        fund.claimFor(0, 99);
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.claimFor(1, aliceId);

        vm.prank(bob);
        assertEq(fund.claimFor(0, bobId), 2475e5);
        assertEq(ledger.balanceOf(bob), 2475e5);
        assertEq(ledger.balanceOf(treasury), 10e6);
        _solvent();
    }

    function test_claimFor_paysCurrentPayout_afterTransfer() public {
        _earn(aliceId, 100e6);
        _endEpoch();
        vm.prank(alice);
        caretakers.setPayout(aliceId, makeAddr("aliceCold"));
        vm.prank(alice);
        builders.proposeOwner(carol);
        vm.prank(carol);
        builders.acceptOwnership(aliceId);

        vm.prank(alice); // the old owner can still crank, but not for itself
        fund.claimFor(0, aliceId);
        assertEq(ledger.balanceOf(carol), 99e6, "old owner's payout is not honoured");
        assertEq(ledger.balanceOf(makeAddr("aliceCold")), 0);
    }

    function test_claimFor_honoursPayoutSetByCurrentOwner() public {
        _earn(aliceId, 100e6);
        _endEpoch();
        address cold = makeAddr("aliceCold");
        vm.prank(alice);
        caretakers.setPayout(aliceId, cold);
        fund.claimFor(0, aliceId);
        assertEq(ledger.balanceOf(cold), 99e6);
    }
}

/// End to end: a builder with two projects, a stolen key, a Safe recovery, the
/// badge following the builder, and the next claims paying the new owner.
contract BuilderRecoveryE2ETest is BuilderStack {
    event OwnerChanged(uint256 indexed builderId, address indexed from, address indexed to, bool recovered);

    function setUp() public {
        _deployStack();
    }

    function test_e2e_twoProjects_stolenKey_recovery_badgeSync_claimToNewOwner() public {
        vm.warp(1_800_000_000);
        // 1. register with a github project, add a domain project
        vm.prank(alice);
        (uint256 id, uint256 p1) = builders.registerBuilderWithProject("https://alice.dev", "github:alice/app");
        vm.prank(alice);
        uint256 p2 = builders.addProject("domain:alice.dev");
        assertEq(builders.projectsOf(id).length, 2);
        assertEq(builders.activeProjectCount(id), 2);
        (, string memory s1,,) = builders.projects(p1);
        (, string memory s2,,) = builders.projects(p2);
        assertEq(s1, "github:alice/app");
        assertEq(s2, "domain:alice.dev");

        // 2. onboarding: caretaker + one badge for the builder
        uint256 serial = _onboard(id);
        assertEq(badge.ownerOf(serial), alice);
        uint64 issued = badge.issuedAt(serial);

        // 3. income from markets on both projects in epoch e0
        uint256 e0 = fund.currentEpoch();
        _earn(id, 400e6);
        _earn(id, 600e6);
        _endEpoch();

        // 4. the key is stolen: the thief points payouts at itself
        address thief = makeAddr("thief");
        vm.prank(alice);
        caretakers.setPayout(id, thief);
        assertEq(caretakers.payoutOf(id), thief);
        vm.prank(operator); // the keeper's status flag, kept through the recovery
        badge.setLapsed(id, true);

        // 5. the Safe recovers to a fresh wallet; not before 7 days
        address fresh = makeAddr("aliceFresh");
        vm.prank(safe);
        builders.startRecovery(id, fresh);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(BuilderRegistry.RecoveryNotReady.selector);
        builders.finishRecovery(id);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(builders));
        emit OwnerChanged(id, alice, fresh, true);
        builders.finishRecovery(id);
        assertEq(builders.ownerOf(id), fresh);
        assertEq(builders.builderIdOf(alice), 0);
        assertEq(caretakers.payoutOf(id), fresh, "thief payout ignored");
        assertEq(builders.activeProjectCount(id), 2, "projects follow the builder");

        // 6. the badge follows: same serial, issue date and lapsed flag kept
        badge.sync(id);
        assertEq(badge.ownerOf(serial), fresh);
        assertEq(badge.balanceOf(alice), 0);
        assertEq(badge.serialOf(id), serial);
        assertEq(badge.issuedAt(serial), issued);
        assertTrue(badge.lapsed(serial));
        vm.prank(operator);
        badge.setLapsed(id, false); // proofs re-published under the new wallet
        assertFalse(badge.isLapsed(serial));
        vm.prank(fresh);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.transferFrom(fresh, thief, serial);

        // 7. the pending epoch-e0 claim pays the new owner
        uint256 amt0 = fund.claimFor(e0, id);
        assertEq(amt0, 990e6);
        assertEq(ledger.balanceOf(fresh), amt0);

        // 8. the next epochs: new income, claimed by the new owner itself
        _earn(id, 500e6);
        _endEpoch();
        uint256 e1 = fund.currentEpoch() - 1;
        vm.prank(fresh);
        uint256 amt1 = fund.claimFor(e1, id);
        assertEq(amt1, 495e6);
        assertEq(ledger.balanceOf(fresh), amt0 + amt1);
        assertEq(ledger.balanceOf(thief), 0);
        assertEq(ledger.balanceOf(treasury), 15e6);

        // 9. the stolen key is inert
        vm.startPrank(alice);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        caretakers.setPayout(id, thief);
        vm.expectRevert(BuilderRegistry.NotOwner.selector);
        builders.removeProject(p1);
        vm.expectRevert(BuilderRegistry.NotRegistered.selector);
        builders.proposeOwner(thief);
        vm.stopPrank();
        _solvent();
    }
}
