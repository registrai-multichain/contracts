// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {ProgressArbiter} from "../../src/perennial/ProgressArbiter.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";

/// Shared phase-2 stack: Safe = admin/REGISTRAR/GOVERNOR/ISSUER, operator =
/// caretaker + arbiter PROPOSER + badge STATUS (runbook layout).
abstract contract BuilderStack is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    VerifiedBuilderBadge badge;
    ProgressPool pool;
    ProgressArbiter arb;

    address safe = makeAddr("safe");
    address operator = makeAddr("operator");
    address resolver = makeAddr("resolver");
    address treasury = makeAddr("treasury");
    address funder = makeAddr("funder");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant EPOCH = 7 days;
    uint256 constant WINDOW = 1 hours;
    uint256 constant STAKE = 50e6;
    uint256 constant STREAM = 30 days;

    function _deployStack() internal {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(safe);
        caretakers = new CaretakerRegistry(builders, safe);
        badge = new VerifiedBuilderBadge(builders, safe, operator, "Arc", "img/", "ext/");
        pool = new ProgressPool(ledger, builders, caretakers, safe, EPOCH, STREAM, treasury);
        arb = new ProgressArbiter(ledger, pool, builders, caretakers, safe, WINDOW, STAKE, 10, 7 days);
        vm.startPrank(safe);
        pool.grantRole(pool.PROGRESS_ROLE(), address(arb));
        arb.grantRole(arb.PROPOSER_ROLE(), operator);
        arb.grantRole(arb.RESOLVER_ROLE(), resolver);
        vm.stopPrank();
        _fund(operator, 500e6);
        vm.prank(operator);
        arb.depositBond(500e6);
    }

    function _fund(address a, uint256 amt) internal {
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(amt);
        ledger.approveSpender(address(arb), type(uint256).max);
        vm.stopPrank();
    }

    function _fundCommons(uint256 amt) internal {
        _fund(funder, amt);
        vm.prank(funder);
        ledger.internalTransfer(address(pool), amt); // stands in for the commons fee leg
    }

    function _onboard(uint256 id) internal returns (uint256 serial) {
        vm.startPrank(safe);
        caretakers.setCaretaker(id, operator);
        serial = badge.issue(id);
        vm.stopPrank();
    }

    function _proposeAndFinalize(uint256 id, uint256 w) internal returns (uint256 entry) {
        vm.prank(operator);
        entry = arb.propose(id, w);
        vm.warp(block.timestamp + WINDOW + 1);
        arb.finalize(entry);
    }

    function _closeEpoch() internal {
        vm.warp(pool.epochStart() + EPOCH);
        pool.closeEpoch();
    }

    function _streamTo(uint256 epoch, uint256 id) internal view returns (address to) {
        (, to,,,,,) = ledger.streams(pool.streamIdOf(epoch, id));
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
    }
}

contract BuilderIdKeyedTest is BuilderStack {
    uint256 aliceId;
    uint256 bobId;

    event ProgressProposed(uint256 indexed id, uint256 indexed builderId, uint256 weight, uint256 maturesAt);
    event ProgressFinalized(uint256 indexed id, uint256 indexed builderId, uint256 weight);
    event ProgressAdded(uint256 indexed epoch, uint256 indexed builderId, uint256 weight);
    event Claimed(uint256 indexed epoch, uint256 indexed builderId, uint256 amount);
    event ProtocolFeePaid(uint256 indexed epoch, uint256 indexed builderId, uint256 fee);
    event ProgressClosedInactive(uint256 indexed id, uint256 indexed builderId, bool challengerRefunded);

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
        _fundCommons(1_000e6);
    }

    function test_propose_finalize_byBuilderId_events() public {
        uint256 m = block.timestamp + WINDOW;
        vm.expectEmit(address(arb));
        emit ProgressProposed(0, aliceId, 7, m);
        vm.prank(operator);
        uint256 e = arb.propose(aliceId, 7);
        assertEq(arb.getEntry(e).builderId, aliceId);
        (uint256 storedId,,,,,,) = arb.entries(e);
        assertEq(storedId, aliceId);

        vm.warp(m + 1);
        vm.expectEmit(address(pool));
        emit ProgressAdded(0, aliceId, 7);
        vm.expectEmit(address(arb));
        emit ProgressFinalized(e, aliceId, 7);
        arb.finalize(e);
        assertEq(pool.progressWeight(0, aliceId), 7);
        assertEq(pool.totalWeight(0), 7);
    }

    function test_propose_refusals_byId() public {
        vm.startPrank(operator);
        vm.expectRevert(ProgressArbiter.BuilderInactive.selector);
        arb.propose(0, 1);
        vm.expectRevert(ProgressArbiter.BuilderInactive.selector);
        arb.propose(99, 1);
        vm.stopPrank();
        vm.prank(safe);
        builders.setActive(bobId, false);
        vm.prank(operator);
        vm.expectRevert(ProgressArbiter.BuilderInactive.selector);
        arb.propose(bobId, 1);
        vm.prank(safe);
        caretakers.setCaretaker(aliceId, makeAddr("otherOp"));
        vm.prank(operator);
        vm.expectRevert(ProgressArbiter.UnauthorizedCaretaker.selector);
        arb.propose(aliceId, 1);
    }

    function test_addProgress_requiresActiveBuilderId() public {
        vm.startPrank(safe);
        pool.grantRole(pool.PROGRESS_ROLE(), safe);
        vm.expectRevert(ProgressPool.BuilderInactive.selector);
        pool.addProgress(0, 1);
        vm.expectRevert(ProgressPool.BuilderInactive.selector);
        pool.addProgress(99, 1);
        builders.setActive(aliceId, false);
        vm.expectRevert(ProgressPool.BuilderInactive.selector);
        pool.addProgress(aliceId, 1);
        pool.addProgress(bobId, 1);
        vm.stopPrank();
        assertEq(pool.progressWeight(0, bobId), 1);
    }

    function test_ownerChange_doesNotTouchProposalsOrWeight() public {
        vm.prank(operator);
        uint256 e = arb.propose(aliceId, 5);
        vm.prank(alice);
        builders.proposeOwner(carol);
        vm.prank(carol);
        builders.acceptOwnership(aliceId);
        vm.warp(block.timestamp + WINDOW + 1);
        arb.finalize(e); // the entry is keyed by id: the owner change is irrelevant
        assertEq(pool.progressWeight(0, aliceId), 5);
        vm.prank(operator);
        arb.propose(aliceId, 1); // caretaker is per id: still allowed
    }

    function test_closeInactive_byId() public {
        vm.prank(operator);
        uint256 e = arb.propose(aliceId, 5);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(ProgressArbiter.BuilderActive.selector);
        arb.closeInactive(e);
        vm.prank(safe);
        builders.setActive(aliceId, false);
        vm.expectEmit(address(arb));
        emit ProgressClosedInactive(e, aliceId, false);
        arb.closeInactive(e);
        assertEq(uint8(arb.getEntry(e).state), uint8(ProgressArbiter.State.Closed));
        assertEq(pool.progressWeight(0, aliceId), 0);
        _solvent();
    }

    function test_closeEpoch_claimFor_byId_splitsAndStreams() public {
        _proposeAndFinalize(aliceId, 3);
        _proposeAndFinalize(bobId, 1);
        _closeEpoch();
        assertEq(pool.claimable(0, aliceId), 7425e5);
        assertEq(pool.claimable(0, bobId), 2475e5);

        vm.expectEmit(address(pool));
        emit ProtocolFeePaid(0, aliceId, 75e5);
        vm.expectEmit(address(pool));
        emit Claimed(0, aliceId, 7425e5);
        vm.prank(makeAddr("anyone"));
        uint256 a = pool.claimFor(0, aliceId);
        assertEq(a, 7425e5);
        assertTrue(pool.claimed(0, aliceId));
        assertEq(_streamTo(0, aliceId), alice);
        vm.expectRevert(ProgressPool.AlreadyClaimed.selector);
        pool.claimFor(0, aliceId);
        vm.expectRevert(ProgressPool.NoProgress.selector);
        pool.claimFor(0, 99);
        vm.expectRevert(ProgressPool.EpochNotClosed.selector);
        pool.claimFor(1, aliceId);

        // claim(): the caller's builder id
        vm.prank(bob);
        uint256 b = pool.claim(0);
        assertEq(b, 2475e5);
        assertEq(_streamTo(0, bobId), bob);
        vm.prank(carol); // unregistered: builder id 0 has no weight
        vm.expectRevert(ProgressPool.NoProgress.selector);
        pool.claim(0);
        assertEq(ledger.balanceOf(treasury), 10e6);
        _solvent();
    }

    function test_claimFor_paysCurrentPayout_afterTransfer() public {
        _proposeAndFinalize(aliceId, 1);
        _closeEpoch();
        vm.prank(alice);
        caretakers.setPayout(aliceId, makeAddr("aliceCold"));
        vm.prank(alice);
        builders.proposeOwner(carol);
        vm.prank(carol);
        builders.acceptOwnership(aliceId);

        vm.prank(alice); // the old owner has no builder anymore
        vm.expectRevert(ProgressPool.NoProgress.selector);
        pool.claim(0);
        vm.prank(carol); // the new owner claims the builder's earned share
        pool.claim(0);
        assertEq(_streamTo(0, aliceId), carol, "old owner's payout is not honoured");
    }

    function test_claimFor_honoursPayoutSetByCurrentOwner() public {
        _proposeAndFinalize(aliceId, 1);
        _closeEpoch();
        address cold = makeAddr("aliceCold");
        vm.prank(alice);
        caretakers.setPayout(aliceId, cold);
        pool.claimFor(0, aliceId);
        assertEq(_streamTo(0, aliceId), cold);
    }
}

/// End to end: a builder with two projects, a stolen key, a Safe recovery, the
/// badge following the builder, and the next claim paying the new owner.
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

        // 3. progress across both projects in epoch 0
        _fundCommons(1_000e6);
        _proposeAndFinalize(id, 4);
        _proposeAndFinalize(id, 6);
        _closeEpoch();

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

        // 7. the pending epoch-0 claim pays the new owner
        uint256 amt0 = pool.claimFor(0, id);
        assertEq(amt0, 990e6);
        assertEq(_streamTo(0, id), fresh);

        // 8. the next epoch: new progress, claimed by the new owner itself
        _fundCommons(500e6);
        _proposeAndFinalize(id, 2);
        _closeEpoch();
        vm.prank(fresh);
        uint256 amt1 = pool.claim(1);
        assertEq(amt1, 495e6);
        assertEq(_streamTo(1, id), fresh);

        vm.warp(block.timestamp + STREAM + 1 days);
        ledger.settleStream(pool.streamIdOf(0, id));
        ledger.settleStream(pool.streamIdOf(1, id));
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
