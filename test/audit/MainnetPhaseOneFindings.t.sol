// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Mainnet phase-1 audit (2026-09-25): findings PoCs + an end-to-end run on a
/// FORK of Arc mainnet against the deployed bytecode at the deployed addresses.
///
/// Naming: test_POC_<SEV>_* demonstrates a finding (PASSES while the issue is
///         real); test_OK_* is a property that was checked and holds.
///
/// Fork suite (reads live state; sends nothing):
///   FORK_MAINNET=1 forge test --match-path test/audit/MainnetPhaseOneFindings.t.sol -vv

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {JsonHelpers} from "./BuilderSideAudit.t.sol";

/// Shared: the mainnet layout, either fresh (unit) or the live deployment (fork).
abstract contract PhaseOneBase is JsonHelpers {
    address constant M_BUILDERS = 0xBB6F4B18776Fd20Bb53a1205375273373DD1E5bA;
    address constant M_CARETAKERS = 0x64725935d90F0aa6f3c8642Bb9cACF44CAA46224;
    address constant M_BADGE = 0xF229d2Ed13Cc35d46fa7676a579495E5C80CFEB2;
    address constant M_SAFE = 0xFeE926e8Be2D1C6192213cf20f31D94Dad1e80Fb;
    address constant M_OPERATOR = 0xe528487069a24DA29c0360e61378db07ECAE88c9;
    address constant M_ONBOARDER = 0x80e81588175558D565FFC1f63Fe0513a61316405;
    address constant M_DEPLOYER = 0x84C799941C6B69AbB296EC46a02E4e0772Ad2E5e;

    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    VerifiedBuilderBadge badge;
    address safe;
    address operator;
    address onboarder;
    address deployer;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address thief = makeAddr("thief");
    address mallory = makeAddr("mallory");

    function _deployFresh() internal {
        safe = M_SAFE;
        operator = M_OPERATOR;
        onboarder = M_ONBOARDER;
        deployer = M_DEPLOYER;
        vm.startPrank(deployer);
        builders = new BuilderRegistry(safe);
        caretakers = new CaretakerRegistry(builders, deployer);
        caretakers.grantRole(0x00, safe);
        caretakers.grantRole(caretakers.GOVERNOR_ROLE(), safe);
        caretakers.grantRole(caretakers.GOVERNOR_ROLE(), onboarder);
        caretakers.renounceRole(caretakers.GOVERNOR_ROLE(), deployer);
        caretakers.renounceRole(0x00, deployer);
        badge = new VerifiedBuilderBadge(
            builders,
            deployer,
            operator,
            "Arc Mainnet",
            "https://builder.registrai.cc/badge/arc/",
            "https://builder.registrai.cc/builders/?builder="
        );
        badge.grantRole(0x00, safe);
        badge.grantRole(badge.ISSUER_ROLE(), safe);
        badge.grantRole(badge.REVOKER_ROLE(), safe);
        badge.grantRole(badge.ISSUER_ROLE(), onboarder);
        badge.renounceRole(badge.ISSUER_ROLE(), deployer);
        badge.renounceRole(badge.REVOKER_ROLE(), deployer);
        badge.renounceRole(0x00, deployer);
        vm.stopPrank();
    }

    function _useLive() internal {
        builders = BuilderRegistry(M_BUILDERS);
        caretakers = CaretakerRegistry(M_CARETAKERS);
        badge = VerifiedBuilderBadge(M_BADGE);
        safe = M_SAFE;
        operator = M_OPERATOR;
        onboarder = M_ONBOARDER;
        deployer = M_DEPLOYER;
    }

    function _claim(address who, string memory source) internal returns (uint256 id) {
        vm.prank(who);
        (id,) = builders.registerBuilderWithProject(string.concat("registrai:", source), source);
    }

    function _onboard(uint256 id) internal returns (uint256 serial) {
        vm.startPrank(onboarder);
        caretakers.setCaretaker(id, operator);
        serial = badge.issue(id);
        vm.stopPrank();
    }

    function _transfer(uint256 id, address from, address to) internal {
        vm.prank(from);
        builders.proposeOwner(to);
        vm.prank(to);
        builders.acceptOwnership(id);
    }
}

// ═════════════════════════════ findings (fresh deploy) ═════════════════════════════

contract MainnetPhaseOneFindingsTest is PhaseOneBase {
    event RecoveryCancelled(uint256 indexed builderId);
    event OwnerProposed(uint256 indexed builderId, address indexed newOwner);

    function setUp() public {
        _deployFresh();
    }

    /// LOW-1 — the badge does not follow an owner change until someone calls
    /// `sync`. Meanwhile the PREVIOUS owner (a buyer's seller, or the thief a
    /// recovery just removed) still holds the "Verified" RVB token, the new
    /// owner holds nothing, and a wallet can hold TWO badges. Anything that
    /// reads `balanceOf` / `ownerOf(serial)` as "is a verified builder" (wallet
    /// UIs, marketplaces, third-party gates) is wrong in that window.
    /// Fix (no redeploy): the keeper syncs on every OwnerChanged event (sync is
    /// permissionless and cheap); integrators resolve holders through
    /// `serialOf(builderIdOf(addr))`, not `balanceOf`. Fix (redeploy): make
    /// ownerOf/balanceOf derive from the registry, or have the registry call
    /// sync in _changeOwner.
    function test_POC_LOW1_staleBadgeUntilSync_oldOwnerHoldsTwo() public {
        uint256 a = _claim(alice, "github:alice/app");
        uint256 s1 = _onboard(a);
        _transfer(a, alice, bob); // alice hands builder #a to bob
        assertEq(builders.ownerOf(a), bob);
        assertEq(badge.ownerOf(s1), alice, "badge still with the old owner");
        assertEq(badge.balanceOf(bob), 0, "new owner shows no badge");

        uint256 c = _claim(alice, "github:alice/next"); // alice registers anew
        uint256 s2 = _onboard(c);
        assertEq(badge.balanceOf(alice), 2, "one wallet holds two soulbound badges");
        assertEq(badge.ownerOf(s2), alice);

        badge.sync(a); // anyone fixes it
        assertEq(badge.ownerOf(s1), bob);
        assertEq(badge.balanceOf(alice), 1);
    }

    /// LOW-1 (recovery flavour): after the Safe recovers a stolen builder, the
    /// thief keeps displaying the Verified badge until `sync`.
    function test_POC_LOW1_thiefKeepsBadgeAfterRecoveryUntilSync() public {
        uint256 a = _claim(alice, "github:alice/app");
        uint256 s = _onboard(a);
        _transfer(a, alice, thief); // key compromise: thief moves it to its wallet
        badge.sync(a); // (anyone synced it to the thief)
        vm.prank(safe);
        builders.startRecovery(a, carol);
        vm.warp(block.timestamp + 7 days);
        builders.finishRecovery(a);
        assertEq(builders.ownerOf(a), carol);
        assertEq(badge.ownerOf(s), thief, "thief still holds the badge");
        assertFalse(badge.isLapsed(s), "and it still reads Verified");
        badge.sync(a);
        assertEq(badge.ownerOf(s), carol);
    }

    /// LOW-2 — `cancelRecovery` has no deadline: the owner can still cancel
    /// AFTER readyAt (the spec says "may cancel for RECOVERY_DELAY"), so a
    /// recovery becomes a race between the owner's cancel and anyone's finish.
    /// With finishRecovery permissionless the new owner can call it at readyAt,
    /// so this only matters if nobody does; combined with LOW-3 (an active
    /// thief can cancel at any time anyway) the practical effect is nil today.
    /// Fix (redeploy): in cancelRecovery, `if (msg.sender == owner &&
    /// block.timestamp >= readyAt) revert RecoveryNotReady()`-style check.
    function test_POC_LOW2_ownerCanCancelAfterReadyAt() public {
        uint256 a = _claim(alice, "github:alice/app");
        vm.prank(safe);
        builders.startRecovery(a, carol);
        vm.warp(block.timestamp + 30 days); // long past readyAt
        vm.prank(alice);
        builders.cancelRecovery(a); // still allowed
        (address to,) = builders.recoveryOf(a);
        assertEq(to, address(0));
        vm.expectRevert(BuilderRegistry.NoRecovery.selector);
        builders.finishRecovery(a);
    }

    /// LOW-3 (known, BuilderSideAudit RESIDUAL; re-checked on mainnet): an
    /// ACTIVE thief can defeat recovery forever: cancel it, or move the builder
    /// to a fresh wallet (which also clears it, SILENTLY: no RecoveryCancelled
    /// event, so an indexer that only watches recovery events keeps showing a
    /// pending recovery). Phase 1 moves no money, so the damage is the badge /
    /// gallery identity; the Safe's lever is setActive(false) (badge reads
    /// Lapsed at once) + revoke.
    /// Fix (redeploy, design choice): while a recovery is pending, block
    /// proposeOwner/acceptOwnership and let only the REGISTRAR cancel (the owner
    /// disputes off-chain) — trades owner-protection-from-Safe for theft
    /// recovery. At least emit RecoveryCancelled / OwnerProposed(0) in
    /// _changeOwner when it clears them.
    function test_POC_LOW3_activeThiefDefeatsRecovery_andClearsItSilently() public {
        uint256 a = _claim(alice, "github:alice/app");
        uint256 s = _onboard(a);
        vm.prank(safe);
        builders.startRecovery(a, carol);

        // the thief holds alice's key: moves the builder away mid-recovery
        address fresh = makeAddr("thief2");
        vm.prank(alice);
        builders.proposeOwner(fresh);
        vm.recordLogs();
        vm.prank(fresh);
        builders.acceptOwnership(a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != RecoveryCancelled.selector, "no RecoveryCancelled emitted");
        }
        (address to,) = builders.recoveryOf(a);
        assertEq(to, address(0), "recovery silently cleared");
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BuilderRegistry.NoRecovery.selector);
        builders.finishRecovery(a);

        // the Safe's effective lever in phase 1
        vm.prank(safe);
        builders.setActive(a, false);
        assertTrue(badge.isLapsed(s), "deactivation lapses the badge at once");
        vm.prank(safe);
        badge.revoke(a);
    }

    /// INFO-1 — payout resurrection: a payout is honoured while its SETTER owns
    /// the builder, so if ownership ever RETURNS to a wallet that set a payout
    /// earlier (A -> B -> A, or a recovery back to an old wallet), that old
    /// payout silently comes back. Never a stranger's address (only the current
    /// owner's own old choice), and phase 1 pays nothing; noted for phase 2
    /// (BuilderFund pays payoutOf). Fix (redeploy): key the payout to an owner
    /// epoch/nonce that _changeOwner bumps, not to the setter address.
    function test_POC_INFO1_payoutResurrectsWhenOwnershipReturns() public {
        uint256 a = _claim(alice, "github:alice/app");
        address oldPayout = makeAddr("alice-old-exchange-deposit");
        vm.prank(alice);
        caretakers.setPayout(a, oldPayout);
        _transfer(a, alice, bob);
        assertEq(caretakers.payoutOf(a), bob, "falls back on transfer");
        _transfer(a, bob, alice);
        assertEq(caretakers.payoutOf(a), oldPayout, "old payout revived without re-confirmation");
    }

    /// INFO-2 — deactivating a builder flips its badge to Lapsed in tokenURI,
    /// but the badge emits no ERC-4906 MetadataUpdate (only the registry emits
    /// BuilderStatusSet), so marketplaces keep the cached "Verified" metadata
    /// until the keeper also calls setLapsed(true) (which does emit it). The
    /// keeper spec already lapses "at once" on inactive: keep it that way.
    function test_POC_INFO2_deactivationEmitsNoBadgeMetadataUpdate() public {
        uint256 a = _claim(alice, "github:alice/app");
        uint256 s = _onboard(a);
        vm.recordLogs();
        vm.prank(safe);
        builders.setActive(a, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(badge), "badge emitted nothing");
        }
        assertTrue(badge.isLapsed(s));
    }

    /// Compromised ONBOARDER key, full blast radius on the mainnet layout:
    /// CAN issue badges to self-registered sybils and repoint every caretaker
    /// (the gallery's "verified" = caretaker == operator, so it can both
    /// "verify" sybils and un-verify everyone). CANNOT revoke, move, lapse,
    /// register, add/retire projects, recover, change bases or grant roles.
    /// The Safe removes both roles in ONE MultiSend and repairs by batch.
    function test_OK_compromisedOnboarder_blastRadius_andSafeContainment() public {
        uint256 a = _claim(alice, "github:alice/app");
        uint256 s = _onboard(a);

        // what it CAN do
        uint256 sybil = _claim(mallory, "github:mallory/fake");
        vm.startPrank(onboarder);
        uint256 sybilSerial = badge.issue(sybil);
        caretakers.setCaretaker(sybil, operator); // gallery: "verified" sybil
        caretakers.setCaretaker(a, mallory); // gallery: alice no longer verified
        vm.stopPrank();
        assertEq(badge.ownerOf(sybilSerial), mallory);

        // what it CANNOT do
        bytes32 revokerRole = badge.REVOKER_ROLE();
        vm.startPrank(onboarder);
        vm.expectRevert();
        badge.revoke(a);
        vm.expectRevert();
        badge.setLapsed(a, true);
        vm.expectRevert();
        badge.setBases("https://evil/", "https://evil/");
        vm.expectRevert();
        builders.registerFor(mallory, "x");
        vm.expectRevert();
        builders.startRecovery(a, mallory);
        vm.expectRevert();
        builders.setActive(a, false);
        vm.expectRevert();
        builders.addProjectFor(a, "github:x/y");
        vm.expectRevert();
        builders.setProjectActive(1, false);
        vm.expectRevert();
        badge.grantRole(revokerRole, onboarder);
        vm.expectRevert();
        caretakers.grantRole(0x00, onboarder);
        vm.expectRevert();
        caretakers.setPayout(a, mallory);
        vm.expectRevert();
        badge.transferFrom(alice, mallory, s);
        vm.stopPrank();

        // containment: the Safe (one batch) strips both roles, then repairs
        vm.startPrank(safe);
        badge.revokeRole(badge.ISSUER_ROLE(), onboarder);
        caretakers.revokeRole(caretakers.GOVERNOR_ROLE(), onboarder);
        badge.revoke(sybil);
        caretakers.setCaretaker(a, operator);
        vm.stopPrank();
        vm.prank(onboarder);
        vm.expectRevert();
        badge.issue(a);
        assertEq(badge.ownerOf(s), alice, "alice's number untouched");
    }

    /// Compromised OPERATOR (keeper) key: can only flip lapsed on issued badges.
    function test_OK_compromisedOperator_onlyLapses() public {
        uint256 a = _claim(alice, "github:alice/app");
        uint256 s = _onboard(a);
        vm.startPrank(operator);
        badge.setLapsed(a, true); // worst case: everyone reads Lapsed until the keeper is fixed
        vm.expectRevert();
        badge.issue(a);
        vm.expectRevert();
        badge.revoke(a);
        vm.expectRevert();
        caretakers.setCaretaker(a, operator);
        vm.expectRevert();
        builders.setActive(a, false);
        vm.expectRevert();
        badge.setBases("", "");
        vm.stopPrank();
        assertEq(badge.ownerOf(s), alice);
        bytes32 statusRole = badge.STATUS_ROLE();
        vm.prank(safe);
        badge.revokeRole(statusRole, operator); // containment
        assertFalse(badge.hasRole(statusRole, operator));
    }

    /// A malicious / coerced Safe quorum (2 of 3) on phase 1: it can take any
    /// builder, but only through a 7-day recovery the owner can cancel; it can
    /// never set a builder's payout, move a badge except by following the
    /// registry, or reuse a serial. Everything else (deactivate, revoke badges,
    /// point art/links at another host, grant roles) is visible and reversible
    /// by a later honest quorum — so the Safe owners' keys are the real root.
    function test_OK_maliciousSafeQuorum_limits() public {
        uint256 a = _claim(alice, "github:alice/app");
        uint256 s = _onboard(a);
        vm.startPrank(safe);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        caretakers.setPayout(a, safe);
        vm.expectRevert();
        badge.transferFrom(alice, safe, s);
        builders.startRecovery(a, mallory);
        vm.stopPrank();
        vm.prank(alice);
        builders.cancelRecovery(a); // the owner defeats a hostile recovery
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(BuilderRegistry.NoRecovery.selector);
        builders.finishRecovery(a);
        assertEq(builders.ownerOf(a), alice);
    }

    /// The badge contract makes no external call that can re-enter: `issue` and
    /// `sync` use _mint (no onERC721Received), and every call it makes is a
    /// STATICCALL to the immutable registry. A contract owner that reverts on
    /// every call still receives and follows its badge.
    function test_OK_noReceiverHook_contractOwnerThatRejectsEverything() public {
        Rejector r = new Rejector();
        vm.prank(address(r));
        (uint256 id,) = builders.registerBuilderWithProject("", "domain:r.xyz");
        uint256 s = _onboard(id);
        assertEq(badge.ownerOf(s), address(r));
        vm.prank(address(r));
        builders.proposeOwner(bob);
        vm.prank(bob);
        builders.acceptOwnership(id);
        badge.sync(id);
        assertEq(badge.ownerOf(s), bob);
    }

    /// Races: a pending proposeOwner never survives a recovery (so the proposed
    /// wallet cannot take the builder back from the recovered owner), and a
    /// recovery target that got registered in the meantime blocks finish.
    function test_OK_pendingOwnerClearedByRecovery_noTakeback() public {
        uint256 a = _claim(alice, "github:alice/app");
        vm.prank(alice);
        builders.proposeOwner(thief); // thief pre-positions a proposal
        vm.prank(safe);
        builders.startRecovery(a, carol);
        vm.warp(block.timestamp + 7 days);
        builders.finishRecovery(a);
        assertEq(builders.pendingOwner(a), address(0));
        vm.prank(thief);
        vm.expectRevert(BuilderRegistry.NotPendingOwner.selector);
        builders.acceptOwnership(a);
    }

    /// Gas bound: the heaviest views stay cheap at every builder-controlled cap
    /// (16 projects x 128 bytes, profile 256, identity 1024).
    function test_OK_viewGasBoundedAtCaps() public {
        vm.startPrank(alice);
        builders.registerBuilder(string(new bytes(256)));
        builders.linkIdentity(new bytes(1024));
        for (uint256 i; i < 16; i++) {
            bytes memory src = new bytes(128);
            src[0] = bytes1(uint8(0x41 + i));
            builders.addProject(string(src));
        }
        vm.expectRevert(BuilderRegistry.TooManyProjects.selector);
        builders.addProject("x");
        vm.stopPrank();
        uint256 id = builders.builderIdOf(alice);
        uint256 s = _onboard(id);
        uint256 g = gasleft();
        builders.projectsOf(id);
        builders.builders(id);
        badge.tokenURI(s);
        uint256 used = g - gasleft();
        emit log_named_uint("projectsOf + builders() + tokenURI gas", used);
        assertLt(used, 1_000_000);
    }
}

contract Rejector {
    fallback() external payable {
        revert("no");
    }
}

// ═════════════════════════════ live mainnet fork ═════════════════════════════

/// Runs against the deployed contracts on an Arc mainnet fork (local; nothing
/// is broadcast). Skipped unless FORK_MAINNET=1.
contract MainnetPhaseOneForkTest is PhaseOneBase {
    bool live;

    function setUp() public {
        live = vm.envOr("FORK_MAINNET", false);
        if (!live) return;
        vm.createSelectFork(vm.envOr("ARC_MAINNET_RPC", string("https://rpc.mainnet.arc.io")));
        _useLive();
    }

    modifier onlyFork() {
        if (!live) {
            vm.skip(true);
        }
        _;
    }

    function test_FORK_deployedState() public onlyFork {
        assertEq(block.chainid, 5042);
        bytes32 da = 0x00;
        // wiring + constants
        assertEq(address(caretakers.BUILDERS()), M_BUILDERS);
        assertEq(address(badge.BUILDERS()), M_BUILDERS);
        assertEq(builders.RECOVERY_DELAY(), 7 days);
        assertEq(builders.MAX_PROJECTS_PER_BUILDER(), 16);
        assertEq(badge.chainLabel(), "Arc Mainnet");
        assertEq(badge.imageBase(), "https://builder.registrai.cc/badge/arc/");
        assertEq(badge.externalBase(), "https://builder.registrai.cc/builders/?builder=");
        // every role admin is DEFAULT_ADMIN (no custom admin chains)
        bytes32[6] memory rs = [
            da,
            builders.REGISTRAR_ROLE(),
            caretakers.GOVERNOR_ROLE(),
            badge.ISSUER_ROLE(),
            badge.STATUS_ROLE(),
            badge.REVOKER_ROLE()
        ];
        for (uint256 i; i < 6; i++) {
            assertEq(builders.getRoleAdmin(rs[i]), da);
            assertEq(caretakers.getRoleAdmin(rs[i]), da);
            assertEq(badge.getRoleAdmin(rs[i]), da);
        }
        // exact layout
        assertTrue(builders.hasRole(da, safe) && builders.hasRole(rs[1], safe));
        assertTrue(caretakers.hasRole(da, safe) && caretakers.hasRole(rs[2], safe) && caretakers.hasRole(rs[2], onboarder));
        assertTrue(badge.hasRole(da, safe) && badge.hasRole(rs[3], safe) && badge.hasRole(rs[5], safe));
        assertTrue(badge.hasRole(rs[3], onboarder) && badge.hasRole(rs[4], operator));
        address[3] memory lesser = [operator, onboarder, deployer];
        for (uint256 k; k < 3; k++) {
            assertFalse(builders.hasRole(da, lesser[k]) || caretakers.hasRole(da, lesser[k]) || badge.hasRole(da, lesser[k]));
            assertFalse(builders.hasRole(rs[1], lesser[k]) || badge.hasRole(rs[5], lesser[k]));
        }
        assertFalse(badge.hasRole(rs[4], onboarder) || badge.hasRole(rs[3], operator) || caretakers.hasRole(rs[2], operator));
        assertFalse(badge.hasRole(rs[3], deployer) || badge.hasRole(rs[4], deployer) || caretakers.hasRole(rs[2], deployer));
        // Safe config: 2-of-3, no modules, no guard
        (bool ok, bytes memory ret) = safe.staticcall(abi.encodeWithSignature("getThreshold()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 2);
        (ok, ret) = safe.staticcall(abi.encodeWithSignature("getOwners()"));
        assertEq(abi.decode(ret, (address[])).length, 3);
        (ok, ret) = safe.staticcall(abi.encodeWithSignature("getModulesPaginated(address,uint256)", address(1), 10));
        (address[] memory mods,) = abi.decode(ret, (address[], address));
        assertEq(mods.length, 0, "Safe has a module");
        bytes32 guardSlot = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
        assertEq(vm.load(safe, guardSlot), bytes32(0), "Safe has a guard");
    }

    /// The whole phase-1 lifecycle on the REAL bytecode: claim, onboard (the
    /// onboarder key), metadata, keeper lapse, transfer + sync + payout
    /// fallback, a hostile recovery the owner cancels, a real recovery, fraud
    /// revoke, and the onboarder's containment by the Safe.
    function test_FORK_endToEndLifecycle() public onlyFork {
        uint256 n0 = builders.nextId();
        uint256 s0 = badge.nextSerial();

        uint256 a = _claim(alice, "github:alice/app");
        assertEq(a, n0);
        uint256 s = _onboard(a);
        assertEq(s, s0);
        assertTrue(caretakers.isCaretaker(a, operator));

        string memory j = _decodeTokenURI(badge.tokenURI(s));
        assertEq(vm.parseJsonString(j, ".attributes[0].value"), "Verified");
        assertEq(vm.parseJsonString(j, ".attributes[3].value"), "Arc Mainnet");
        assertEq(
            vm.parseJsonString(j, ".image"), string.concat("https://builder.registrai.cc/badge/arc/", vm.toString(s), ".jpg")
        );

        vm.prank(operator);
        badge.setLapsed(a, true);
        assertEq(vm.parseJsonString(_decodeTokenURI(badge.tokenURI(s)), ".attributes[0].value"), "Lapsed");
        vm.prank(operator);
        badge.setLapsed(a, false);

        // transfer + sync + payout fallback
        vm.prank(alice);
        caretakers.setPayout(a, makeAddr("alice-payout"));
        _transfer(a, alice, bob);
        vm.prank(mallory);
        badge.sync(a);
        assertEq(badge.ownerOf(s), bob);
        assertEq(caretakers.payoutOf(a), bob);

        // hostile recovery cancelled by the owner; real one finishes
        vm.prank(safe);
        builders.startRecovery(a, mallory);
        vm.prank(bob);
        builders.cancelRecovery(a);
        vm.prank(safe);
        builders.startRecovery(a, carol);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(BuilderRegistry.RecoveryNotReady.selector);
        builders.finishRecovery(a);
        vm.warp(block.timestamp + 1);
        builders.finishRecovery(a);
        badge.sync(a);
        assertEq(badge.ownerOf(s), carol);
        assertEq(caretakers.payoutOf(a), carol);

        // onboarder cannot burn; Safe can; serial never reused
        vm.prank(onboarder);
        vm.expectRevert();
        badge.revoke(a);
        vm.prank(safe);
        badge.revoke(a);
        vm.prank(onboarder);
        uint256 s2 = badge.issue(a);
        assertEq(s2, s + 1, "re-issue gets a new serial");

        // containment of the onboarder in one Safe batch
        vm.startPrank(safe);
        badge.revokeRole(badge.ISSUER_ROLE(), onboarder);
        caretakers.revokeRole(caretakers.GOVERNOR_ROLE(), onboarder);
        vm.stopPrank();
        uint256 b2 = _claim(bob, "github:bob/app");
        vm.prank(onboarder);
        vm.expectRevert();
        badge.issue(b2);
    }

    /// The deployer key (which broadcast the deployment) can do nothing.
    function test_FORK_deployerIsPowerless() public onlyFork {
        uint256 a = _claim(alice, "github:alice/app");
        vm.startPrank(deployer);
        vm.expectRevert();
        badge.issue(a);
        vm.expectRevert();
        caretakers.setCaretaker(a, deployer);
        vm.expectRevert();
        builders.setActive(a, false);
        vm.expectRevert();
        badge.grantRole(0x00, deployer);
        vm.expectRevert();
        caretakers.grantRole(0x00, deployer);
        vm.expectRevert();
        builders.grantRole(0x00, deployer);
        vm.stopPrank();
    }
}
