// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// BuilderRegistry: projects under a builder, two-step owner transfer and
/// REGISTRAR recovery; CaretakerRegistry payout fallback on owner change.
contract BuilderProjectsTest is Test {
    BuilderRegistry reg;
    CaretakerRegistry care;

    address safe = makeAddr("safe"); // REGISTRAR + admin
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    uint256 aliceId;

    event ProjectAdded(uint256 indexed builderId, uint256 indexed projectId, string source);
    event ProjectStatusSet(uint256 indexed projectId, bool active);
    event OwnerProposed(uint256 indexed builderId, address indexed newOwner);
    event RecoveryStarted(uint256 indexed builderId, address indexed newOwner, uint64 readyAt);
    event RecoveryCancelled(uint256 indexed builderId);
    event OwnerChanged(uint256 indexed builderId, address indexed from, address indexed to, bool recovered);
    event BuilderRegistered(uint256 indexed id, address indexed owner, string profileURI);

    function setUp() public {
        reg = new BuilderRegistry(safe);
        care = new CaretakerRegistry(reg, safe);
        vm.prank(alice);
        aliceId = reg.registerBuilder("https://alice.dev");
    }

    function _source(uint256 pid) internal view returns (string memory s) {
        (, s,,) = reg.projects(pid);
    }

    function _active(uint256 pid) internal view returns (bool a) {
        (,, a,) = reg.projects(pid);
    }

    // ───────────── projects ─────────────

    function test_addProject_byOwner() public {
        vm.warp(1_800_000_000);
        assertEq(reg.nextProjectId(), 1);
        vm.expectEmit(address(reg));
        emit ProjectAdded(aliceId, 1, "github:alice/app");
        vm.prank(alice);
        uint256 p1 = reg.addProject("github:alice/app");
        vm.prank(alice);
        uint256 p2 = reg.addProject("domain:alice.dev");
        assertEq(p1, 1);
        assertEq(p2, 2);
        (uint256 b, string memory src, bool active, uint64 addedAt) = reg.projects(p1);
        assertEq(b, aliceId);
        assertEq(src, "github:alice/app");
        assertTrue(active);
        assertEq(addedAt, 1_800_000_000);
        uint256[] memory list = reg.projectsOf(aliceId);
        assertEq(list.length, 2);
        assertEq(list[0], 1);
        assertEq(list[1], 2);
        assertEq(reg.activeProjectCount(aliceId), 2);
        assertTrue(reg.hasActiveProject(aliceId));
        assertEq(reg.nextProjectId(), 3);
    }

    function test_addProject_refusals() public {
        vm.prank(stranger);
        vm.expectRevert(BuilderRegistry.NotRegistered.selector);
        reg.addProject("github:x/y");

        vm.prank(safe);
        reg.setActive(aliceId, false);
        vm.prank(alice);
        vm.expectRevert(BuilderRegistry.InactiveBuilder.selector);
        reg.addProject("github:alice/app");
        vm.prank(safe);
        vm.expectRevert(BuilderRegistry.InactiveBuilder.selector);
        reg.addProjectFor(aliceId, "github:alice/app");
    }

    function test_addProject_sourceLength() public {
        vm.startPrank(alice);
        vm.expectRevert(BuilderRegistry.EmptySource.selector);
        reg.addProject("");
        bytes memory s129 = new bytes(129);
        bytes memory s128 = new bytes(128);
        for (uint256 i; i < 129; i++) {
            s129[i] = "a";
            if (i < 128) s128[i] = "a";
        }
        vm.expectRevert(BuilderRegistry.TooLong.selector);
        reg.addProject(string(s129));
        uint256 pid = reg.addProject(string(s128));
        vm.stopPrank();
        assertEq(bytes(_source(pid)).length, reg.MAX_SOURCE_LEN());
    }

    function test_addProject_capCountsEverAdded_removeCannotCycle() public {
        vm.startPrank(alice);
        for (uint256 i; i < reg.MAX_PROJECTS_PER_BUILDER(); i++) {
            reg.addProject(string.concat("github:alice/r", vm.toString(i)));
        }
        vm.expectRevert(BuilderRegistry.TooManyProjects.selector);
        reg.addProject("github:alice/r16");
        reg.removeProject(1);
        reg.removeProject(2);
        assertEq(reg.activeProjectCount(aliceId), 14);
        vm.expectRevert(BuilderRegistry.TooManyProjects.selector);
        reg.addProject("github:alice/again");
        vm.stopPrank();
        vm.prank(safe);
        vm.expectRevert(BuilderRegistry.TooManyProjects.selector);
        reg.addProjectFor(aliceId, "github:alice/again");
        assertEq(reg.projectsOf(aliceId).length, 16);
    }

    function test_noOnChainUniquenessOfSource() public {
        vm.prank(alice);
        reg.addProject("github:shared/repo");
        vm.prank(bob);
        (uint256 bobId, uint256 pid) = reg.registerBuilderWithProject("", "github:shared/repo");
        assertEq(_source(pid), "github:shared/repo");
        assertEq(reg.activeProjectCount(bobId), 1);
    }

    function test_addProjectFor_registrarOnly() public {
        bytes32 registrar = reg.REGISTRAR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, registrar)
        );
        reg.addProjectFor(aliceId, "github:alice/app");
        vm.prank(alice); // the owner is not REGISTRAR either
        vm.expectRevert();
        reg.addProjectFor(aliceId, "github:alice/app");

        vm.prank(safe);
        vm.expectRevert(BuilderRegistry.NotRegistered.selector);
        reg.addProjectFor(99, "github:x/y");

        vm.expectEmit(address(reg));
        emit ProjectAdded(aliceId, 1, "domain:alice.dev");
        vm.prank(safe);
        uint256 pid = reg.addProjectFor(aliceId, "domain:alice.dev");
        (uint256 b,,,) = reg.projects(pid);
        assertEq(b, aliceId, "belongs to the builder, not the registrar");
        assertEq(reg.builderIdOf(safe), 0);
    }

    function test_registerBuilderWithProject() public {
        vm.expectEmit(address(reg));
        emit BuilderRegistered(2, bob, "https://bob.xyz");
        vm.expectEmit(address(reg));
        emit ProjectAdded(2, 1, "domain:bob.xyz");
        vm.prank(bob);
        (uint256 id, uint256 pid) = reg.registerBuilderWithProject("https://bob.xyz", "domain:bob.xyz");
        assertEq(id, 2);
        assertEq(pid, 1);
        assertEq(reg.ownerOf(id), bob);
        assertEq(reg.activeProjectCount(id), 1);

        vm.prank(bob);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        reg.registerBuilderWithProject("", "github:bob/x");
        vm.prank(carol);
        vm.expectRevert(BuilderRegistry.EmptySource.selector);
        reg.registerBuilderWithProject("", "");
        assertEq(reg.builderIdOf(carol), 0, "atomic: nothing registered");
    }

    function test_removeProject_ownerOnly_idempotent_historyKept() public {
        vm.prank(alice);
        uint256 pid = reg.addProject("github:alice/app");

        vm.prank(stranger);
        vm.expectRevert(BuilderRegistry.NotOwner.selector);
        reg.removeProject(pid);
        vm.prank(safe); // REGISTRAR uses setProjectActive, not removeProject
        vm.expectRevert(BuilderRegistry.NotOwner.selector);
        reg.removeProject(pid);
        vm.prank(alice);
        vm.expectRevert(BuilderRegistry.UnknownProject.selector);
        reg.removeProject(99);

        vm.expectEmit(address(reg));
        emit ProjectStatusSet(pid, false);
        vm.prank(alice);
        reg.removeProject(pid);
        assertFalse(_active(pid));
        assertEq(_source(pid), "github:alice/app", "history stays");
        assertEq(reg.activeProjectCount(aliceId), 0);
        assertFalse(reg.hasActiveProject(aliceId));
        assertEq(reg.projectsOf(aliceId).length, 1);

        vm.recordLogs();
        vm.prank(alice);
        reg.removeProject(pid); // idempotent
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(reg.activeProjectCount(aliceId), 0, "no underflow / double count");
    }

    function test_removeProject_worksOnInactiveBuilder() public {
        vm.prank(alice);
        uint256 pid = reg.addProject("github:alice/app");
        vm.prank(safe);
        reg.setActive(aliceId, false);
        vm.prank(alice);
        reg.removeProject(pid);
        assertEq(reg.activeProjectCount(aliceId), 0);
    }

    function test_setProjectActive_registrar() public {
        vm.prank(alice);
        uint256 pid = reg.addProject("github:alice/app");
        vm.prank(alice);
        vm.expectRevert();
        reg.setProjectActive(pid, false);
        vm.prank(safe);
        vm.expectRevert(BuilderRegistry.UnknownProject.selector);
        reg.setProjectActive(99, true);

        vm.expectEmit(address(reg));
        emit ProjectStatusSet(pid, false);
        vm.prank(safe);
        reg.setProjectActive(pid, false);
        assertEq(reg.activeProjectCount(aliceId), 0);
        vm.prank(safe);
        reg.setProjectActive(pid, true);
        assertEq(reg.activeProjectCount(aliceId), 1);
        vm.recordLogs();
        vm.prank(safe);
        reg.setProjectActive(pid, true);
        assertEq(vm.getRecordedLogs().length, 0, "idempotent");
        assertEq(reg.activeProjectCount(aliceId), 1);
    }

    function test_projectsFollowTheBuilderAcrossOwnerChange() public {
        vm.prank(alice);
        uint256 pid = reg.addProject("github:alice/app");
        _transfer(alice, carol);
        vm.prank(alice);
        vm.expectRevert(BuilderRegistry.NotOwner.selector);
        reg.removeProject(pid);
        vm.prank(carol);
        reg.removeProject(pid);
        vm.prank(carol);
        reg.addProject("github:carol/app");
        assertEq(reg.projectsOf(aliceId).length, 2);
    }

    // ───────────── owner transfer (two-step) ─────────────

    function _transfer(address from, address to) internal {
        vm.prank(from);
        reg.proposeOwner(to);
        vm.prank(to);
        reg.acceptOwnership(aliceId);
    }

    function test_transfer_twoStep() public {
        vm.prank(alice);
        reg.linkIdentity(hex"01");
        vm.expectEmit(address(reg));
        emit OwnerProposed(aliceId, carol);
        vm.prank(alice);
        reg.proposeOwner(carol);
        assertEq(reg.pendingOwner(aliceId), carol);
        assertEq(reg.ownerOf(aliceId), alice, "nothing moves before accept");

        vm.prank(stranger);
        vm.expectRevert(BuilderRegistry.NotPendingOwner.selector);
        reg.acceptOwnership(aliceId);

        vm.expectEmit(address(reg));
        emit OwnerChanged(aliceId, alice, carol, false);
        vm.prank(carol);
        reg.acceptOwnership(aliceId);

        assertEq(reg.ownerOf(aliceId), carol);
        assertEq(reg.builderIdOf(carol), aliceId);
        assertEq(reg.builderIdOf(alice), 0);
        assertEq(reg.pendingOwner(aliceId), address(0));
        assertFalse(reg.isRegistered(alice));
        assertTrue(reg.isActiveBuilder(carol));
        (,, bytes memory ident,, bool active) = reg.builders(aliceId);
        assertEq(ident, hex"01", "builder data stays with the id");
        assertTrue(active);

        // the old wallet is free to register again; the new one acts as owner
        vm.prank(alice);
        uint256 newId = reg.registerBuilder("fresh");
        assertEq(newId, 2);
        vm.prank(carol);
        reg.updateProfile("https://carol.dev");
        vm.prank(carol);
        vm.expectRevert(BuilderRegistry.NotPendingOwner.selector);
        reg.acceptOwnership(aliceId); // proposal consumed
    }

    function test_transfer_cancelWithZero() public {
        vm.prank(alice);
        reg.proposeOwner(carol);
        vm.expectEmit(address(reg));
        emit OwnerProposed(aliceId, address(0));
        vm.prank(alice);
        reg.proposeOwner(address(0));
        assertEq(reg.pendingOwner(aliceId), address(0));
        vm.prank(carol);
        vm.expectRevert(BuilderRegistry.NotPendingOwner.selector);
        reg.acceptOwnership(aliceId);
    }

    function test_transfer_refusesRegisteredNewOwner() public {
        vm.prank(bob);
        reg.registerBuilder("bob");
        vm.prank(alice);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        reg.proposeOwner(bob);

        // proposed while free, registered before accepting
        vm.prank(alice);
        reg.proposeOwner(carol);
        vm.prank(carol);
        reg.registerBuilder("carol");
        vm.prank(carol);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        reg.acceptOwnership(aliceId);
        assertEq(reg.ownerOf(aliceId), alice);
    }

    function test_proposeOwner_needsRegisteredCaller() public {
        vm.prank(stranger);
        vm.expectRevert(BuilderRegistry.NotRegistered.selector);
        reg.proposeOwner(carol);
    }

    // ───────────── recovery ─────────────

    function test_recovery_startAndFinishAfterDelay() public {
        vm.warp(1_800_000_000);
        uint64 readyAt = uint64(1_800_000_000 + 7 days);
        assertEq(reg.RECOVERY_DELAY(), 7 days);
        vm.expectEmit(address(reg));
        emit RecoveryStarted(aliceId, carol, readyAt);
        vm.prank(safe);
        reg.startRecovery(aliceId, carol);
        (address to, uint64 at) = reg.recoveryOf(aliceId);
        assertEq(to, carol);
        assertEq(at, readyAt);

        vm.warp(readyAt - 1);
        vm.expectRevert(BuilderRegistry.RecoveryNotReady.selector);
        reg.finishRecovery(aliceId);

        vm.warp(readyAt);
        vm.expectEmit(address(reg));
        emit OwnerChanged(aliceId, alice, carol, true);
        vm.prank(stranger); // anyone
        reg.finishRecovery(aliceId);
        assertEq(reg.ownerOf(aliceId), carol);
        assertEq(reg.builderIdOf(carol), aliceId);
        assertEq(reg.builderIdOf(alice), 0);
        (to, at) = reg.recoveryOf(aliceId);
        assertEq(to, address(0));
        assertEq(at, 0);
        vm.expectRevert(BuilderRegistry.NoRecovery.selector);
        reg.finishRecovery(aliceId);
    }

    function test_recovery_startGuards() public {
        vm.prank(stranger);
        vm.expectRevert();
        reg.startRecovery(aliceId, carol);
        vm.prank(alice); // the owner cannot start one either
        vm.expectRevert();
        reg.startRecovery(aliceId, carol);
        vm.startPrank(safe);
        vm.expectRevert(BuilderRegistry.NotRegistered.selector);
        reg.startRecovery(99, carol);
        vm.expectRevert(BuilderRegistry.ZeroAddress.selector);
        reg.startRecovery(aliceId, address(0));
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        reg.startRecovery(aliceId, alice);
        vm.stopPrank();
        vm.prank(bob);
        reg.registerBuilder("bob");
        vm.prank(safe);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        reg.startRecovery(aliceId, bob);
    }

    function test_recovery_finishRefusedIfNewOwnerRegisteredMeanwhile() public {
        vm.prank(safe);
        reg.startRecovery(aliceId, carol);
        vm.prank(carol);
        reg.registerBuilder("carol");
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        reg.finishRecovery(aliceId);
    }

    function test_recovery_cancelByOwner() public {
        vm.prank(safe);
        reg.startRecovery(aliceId, carol);
        vm.prank(stranger);
        vm.expectRevert(BuilderRegistry.NotOwner.selector);
        reg.cancelRecovery(aliceId);
        vm.expectEmit(address(reg));
        emit RecoveryCancelled(aliceId);
        vm.prank(alice);
        reg.cancelRecovery(aliceId);
        (address to,) = reg.recoveryOf(aliceId);
        assertEq(to, address(0));
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(BuilderRegistry.NoRecovery.selector);
        reg.finishRecovery(aliceId);
        vm.prank(alice);
        vm.expectRevert(BuilderRegistry.NoRecovery.selector);
        reg.cancelRecovery(aliceId);
    }

    function test_recovery_cancelByRegistrar_andRestartResetsClock() public {
        vm.prank(safe);
        reg.startRecovery(aliceId, carol);
        vm.prank(safe);
        reg.cancelRecovery(aliceId);
        vm.warp(block.timestamp + 6 days);
        vm.prank(safe);
        reg.startRecovery(aliceId, bob);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(BuilderRegistry.RecoveryNotReady.selector);
        reg.finishRecovery(aliceId);
        vm.warp(block.timestamp + 5 days);
        reg.finishRecovery(aliceId);
        assertEq(reg.ownerOf(aliceId), bob);
    }

    function test_recovery_clearedByOwnerTransfer() public {
        vm.prank(safe);
        reg.startRecovery(aliceId, carol);
        _transfer(alice, bob);
        (address to,) = reg.recoveryOf(aliceId);
        assertEq(to, address(0), "an owner transfer clears the recovery");
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(BuilderRegistry.NoRecovery.selector);
        reg.finishRecovery(aliceId);
        assertEq(reg.ownerOf(aliceId), bob);
    }

    function test_recovery_clearsPendingTransfer() public {
        vm.prank(alice);
        reg.proposeOwner(bob);
        vm.prank(safe);
        reg.startRecovery(aliceId, carol);
        vm.warp(block.timestamp + 7 days);
        reg.finishRecovery(aliceId);
        assertEq(reg.pendingOwner(aliceId), address(0));
        vm.prank(bob);
        vm.expectRevert(BuilderRegistry.NotPendingOwner.selector);
        reg.acceptOwnership(aliceId);
    }

    function test_recovery_worksOnInactiveBuilder() public {
        vm.startPrank(safe);
        reg.setActive(aliceId, false); // freeze first, then recover
        reg.startRecovery(aliceId, carol);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        reg.finishRecovery(aliceId);
        assertEq(reg.ownerOf(aliceId), carol);
        assertFalse(reg.isActiveBuilderId(aliceId), "status unchanged by recovery");
    }

    // ───────────── payout fallback ─────────────

    function test_payout_fallsBackToNewOwner_afterTransfer() public {
        vm.prank(alice);
        care.setPayout(aliceId, bob);
        assertEq(care.payoutOf(aliceId), bob);
        (address p, address setBy) = care.payoutRecord(aliceId);
        assertEq(p, bob);
        assertEq(setBy, alice);

        _transfer(alice, carol);
        assertEq(care.payoutOf(aliceId), carol, "old owner's payout no longer honoured");
        vm.prank(alice);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        care.setPayout(aliceId, alice);
        vm.prank(carol);
        care.setPayout(aliceId, stranger);
        assertEq(care.payoutOf(aliceId), stranger);
    }

    function test_payout_thiefSetPayoutIgnoredAfterRecovery() public {
        address thief = makeAddr("thief");
        vm.prank(alice); // stolen key
        care.setPayout(aliceId, thief);
        assertEq(care.payoutOf(aliceId), thief);
        vm.prank(safe);
        reg.startRecovery(aliceId, carol);
        vm.warp(block.timestamp + 7 days);
        reg.finishRecovery(aliceId);
        assertEq(care.payoutOf(aliceId), carol);
    }

    function test_payout_unsetAndUnregistered() public view {
        assertEq(care.payoutOf(aliceId), alice);
        assertEq(care.payoutOf(99), address(0));
    }
}
