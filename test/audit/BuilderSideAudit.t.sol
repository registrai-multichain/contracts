// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Builder-side security audit (pre mainnet phase 1).
/// Scope: BuilderRegistry, CaretakerRegistry, VerifiedBuilderBadge,
/// DeployBuilders / DeployPerennial (reuse path) / DeployBadge.
/// Updated for builders-with-projects (2026-09-24-builder-projects-design):
/// M-2 is superseded (the badge names no project), M-3 is fixed (owner
/// transfer + REGISTRAR recovery + payout fallback); pool/arbiter by builder id.
///
/// Naming: test_POC_* demonstrate an issue (they PASS when the issue is real);
///         test_OK_*  are regression tests for properties that were checked and hold.

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {ProgressArbiter} from "../../src/perennial/ProgressArbiter.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge, IERC5192} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {RoleTable} from "../../script/lib/RoleTable.sol";
import {DeployOracle} from "../../script/DeployOracle.s.sol";
import {DeployNanoLedger} from "../../script/DeployNanoLedger.s.sol";
import {DeployPerennial} from "../../script/DeployPerennial.s.sol";
import {DeployBuilders} from "../../script/DeployBuilders.s.sol";
import {DeployBadge} from "../../script/DeployBadge.s.sol";
import {DeployArbiter} from "../../script/DeployArbiter.s.sol";
import {DeployNanoStack} from "../../script/DeployNanoStack.s.sol";
import {Handoff} from "../../script/Handoff.s.sol";
import {VerifyRoles} from "../../script/VerifyRoles.s.sol";

contract AuditSafeStub {}

/// Not BuilderRegistry code: a registry look-alike for the code-hash check.
contract FakeRegistry {
    function ownerOf(uint256) external pure returns (address) {
        return address(1);
    }
}

/// A contract owner that refuses ERC-721 safe receipts (and any call).
contract RejectingOwner {
    BuilderRegistry immutable reg;

    constructor(BuilderRegistry r) {
        reg = r;
    }

    function register(string calldata uri, string calldata source) external returns (uint256 id) {
        (id,) = reg.registerBuilderWithProject(uri, source);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("no NFTs");
    }
}

abstract contract JsonHelpers is Test {
    function _decodeTokenURI(string memory uri) internal pure returns (string memory) {
        bytes memory u = bytes(uri);
        bytes memory prefix = "data:application/json;base64,";
        for (uint256 i; i < prefix.length; i++) {
            require(u[i] == prefix[i], "prefix");
        }
        bytes memory b64 = new bytes(u.length - prefix.length);
        for (uint256 i; i < b64.length; i++) {
            b64[i] = u[i + prefix.length];
        }
        return string(_b64decode(b64));
    }

    function _b64decode(bytes memory data) internal pure returns (bytes memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint8[128] memory rev;
        for (uint8 i; i < 64; i++) {
            rev[uint8(table[i])] = i;
        }
        uint256 pad;
        if (data.length > 0 && data[data.length - 1] == "=") pad++;
        if (data.length > 1 && data[data.length - 2] == "=") pad++;
        bytes memory out = new bytes((data.length / 4) * 3 - pad);
        uint256 j;
        for (uint256 i; i < data.length; i += 4) {
            uint256 n = (uint256(rev[uint8(data[i])]) << 18) | (uint256(rev[uint8(data[i + 1])]) << 12)
                | (uint256(data[i + 2] == "=" ? 0 : rev[uint8(data[i + 2])]) << 6)
                | uint256(data[i + 3] == "=" ? 0 : rev[uint8(data[i + 3])]);
            if (j < out.length) out[j++] = bytes1(uint8(n >> 16));
            if (j < out.length) out[j++] = bytes1(uint8(n >> 8));
            if (j < out.length) out[j++] = bytes1(uint8(n));
        }
        return out;
    }

    function _blob(uint256 n, bytes1 fill) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; i++) {
            b[i] = fill;
        }
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; i++) {
            bool ok = true;
            for (uint256 k; k < needle.length; k++) {
                if (hay[i + k] != needle[k]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Phase 1: the three builder contracts, with the planned role layout
// (Safe = DEFAULT_ADMIN everywhere + REGISTRAR; onboarder = badge ISSUER +
// caretaker GOVERNOR; keeper operator = badge STATUS).
// ═══════════════════════════════════════════════════════════════════════════
contract BuilderSideAuditPhase1Test is JsonHelpers {
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    VerifiedBuilderBadge badge;

    address safe = makeAddr("safe");
    address onboarder = makeAddr("onboarder");
    address operator = makeAddr("operator"); // keeper: badge STATUS (and, in phase 2, caretaker/proposer)
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 aliceId;
    uint256 bobId;

    event Locked(uint256 tokenId);
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function setUp() public {
        builders = new BuilderRegistry(safe);
        caretakers = new CaretakerRegistry(builders, safe);
        badge = new VerifiedBuilderBadge(
            builders, safe, operator, "Arc Mainnet", "https://registrai.cc/badge/arc/", "https://registrai.cc/builders/?builder="
        );
        vm.startPrank(safe);
        badge.grantRole(badge.ISSUER_ROLE(), onboarder);
        caretakers.grantRole(caretakers.GOVERNOR_ROLE(), onboarder);
        vm.stopPrank();

        vm.prank(alice);
        (aliceId,) = builders.registerBuilderWithProject("https://alice.dev", "github:alice/app");
        vm.prank(bob);
        (bobId,) = builders.registerBuilderWithProject("", "domain:bob.xyz");
    }

    function _onboard(uint256 id) internal returns (uint256 serial) {
        vm.startPrank(onboarder);
        caretakers.setCaretaker(id, operator);
        serial = badge.issue(id);
        vm.stopPrank();
    }

    function _json(uint256 serial) internal view returns (string memory) {
        return _decodeTokenURI(badge.tokenURI(serial));
    }

    // ───────────────────────────── FINDINGS ─────────────────────────────

    /// SUPERSEDED (was M-2, then the profile-hash fix): a builder may hold
    /// several projects, and only the off-chain proof says which one is
    /// verified, so the badge names NO project and ignores the free-form
    /// profile. It needs >=1 active project to be issued; it reads Lapsed on the
    /// keeper flag (no verified project left) or at once when the builder is
    /// deactivated. A re-pointed profile can no longer borrow a verified look.
    function test_SUPERSEDED_M2_badgeNamesNoProject_lapseIsKeeperOrInactive() public {
        uint256 serial = _onboard(aliceId);
        string memory j = _json(serial);
        assertFalse(_contains(bytes(j), "github:alice/app"), "no source on-chain");
        assertFalse(vm.keyExistsJson(j, ".attributes[5]"), "Status, Serial, Builder ID, Chain, Issued");

        vm.startPrank(alice);
        builders.updateProfile("registrai:github:ethereum/go-ethereum");
        builders.addProject("github:ethereum/go-ethereum"); // a squat: no proof, keeper lapses it
        vm.stopPrank();
        j = _json(serial);
        assertFalse(_contains(bytes(j), "ethereum"), "neither profile nor projects are rendered");

        // the keeper sees no verified project left -> Lapsed
        vm.prank(operator);
        badge.setLapsed(aliceId, true);
        assertEq(vm.parseJsonString(_json(serial), ".attributes[0].value"), "Lapsed");

        // a builder without an active project cannot get a badge at all
        address dave = makeAddr("dave");
        vm.prank(dave);
        uint256 daveId = builders.registerBuilder("registrai:github:dave/app");
        vm.prank(onboarder);
        vm.expectRevert(VerifiedBuilderBadge.NoProject.selector);
        badge.issue(daveId);
    }

    /// FIXED (was L-3): burning is REVOKER-only (the Safe). A compromised
    /// onboarder can still issue to its own sybils (a Safe revoke undoes that),
    /// but can no longer destroy anyone's number.
    function test_FIXED_onboarderCannotBurnSerials() public {
        _onboard(aliceId);
        _onboard(bobId);
        vm.startPrank(onboarder);
        vm.expectRevert();
        badge.revoke(aliceId);
        vm.expectRevert();
        badge.revoke(bobId);
        vm.stopPrank();
        assertEq(badge.ownerOf(1), alice);
        assertEq(badge.ownerOf(2), bob);

        vm.prank(mallory);
        (uint256 sybil,) = builders.registerBuilderWithProject("", "github:mallory/fake");
        vm.prank(onboarder);
        badge.issue(sybil);
        vm.prank(safe);
        badge.revoke(sybil); // the Safe cleans up
        assertEq(badge.balanceOf(mallory), 0);
    }

    /// FIXED (was info): revoke clears the burned serial's data.
    function test_FIXED_revokeClearsSerialMappings() public {
        vm.warp(1_800_000_000);
        uint256 s = _onboard(aliceId);
        vm.prank(safe);
        badge.revoke(aliceId);
        assertEq(badge.serialOf(aliceId), 0);
        assertEq(badge.builderOf(s), 0);
        assertEq(badge.issuedAt(s), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, s));
        badge.tokenURI(s);
    }

    function test_POC_isUniqueBuilderIsSelfAsserted() public {
        address[3] memory sybils = [makeAddr("s1"), makeAddr("s2"), makeAddr("s3")];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(sybils[i]);
            builders.registerBuilder("x");
            builders.linkIdentity(hex"01");
            vm.stopPrank();
            assertTrue(builders.isUniqueBuilder(sybils[i]));
        }
    }

    /// FIXED (was Informational): bytes >= 0x80 in a builder's profile or
    /// project source never reach the badge JSON (no builder string is rendered).
    function test_FIXED_invalidUtf8CannotReachJson() public {
        vm.startPrank(alice);
        builders.updateProfile(string(abi.encodePacked("registrai:github:a/", hex"ff", hex"c0")));
        builders.addProject(string(abi.encodePacked("github:a/", hex"ff", hex"c0")));
        vm.stopPrank();
        uint256 s = _onboard(aliceId);
        bytes memory j = bytes(_json(s));
        assertFalse(_contains(j, hex"ffc0"), "no raw builder bytes in metadata");
    }

    /// FIXED (was L-4): builder-controlled strings are capped (profile 256
    /// bytes, identity 1024, source 128, 16 projects), and none is rendered, so
    /// tokenURI costs the same for every builder.
    function test_FIXED_builderStringsCapped_tokenURIGasBounded() public {
        uint256 sA = _onboard(aliceId);
        bytes memory big = abi.encodePacked("registrai:github:", _blob(24_000, "\""));
        vm.startPrank(alice);
        vm.expectRevert(BuilderRegistry.TooLong.selector);
        builders.updateProfile(string(big));
        vm.expectRevert(BuilderRegistry.TooLong.selector);
        builders.linkIdentity(_blob(1025, 0x01));
        builders.linkIdentity(_blob(1024, 0x01));
        vm.expectRevert(BuilderRegistry.TooLong.selector);
        builders.addProject(string(_blob(129, "x")));
        vm.expectRevert(BuilderRegistry.EmptySource.selector);
        builders.addProject("");
        vm.stopPrank();
        vm.prank(mallory);
        vm.expectRevert(BuilderRegistry.TooLong.selector);
        builders.registerBuilder(string(big));

        // worst case allowed: 256-byte profile, 1KB identity, 16 x 128-byte sources
        address carol = makeAddr("carol");
        vm.startPrank(carol);
        uint256 id = builders.registerBuilder(string(_blob(256, "\"")));
        builders.linkIdentity(_blob(1024, 0x02));
        for (uint256 i; i < 16; i++) {
            builders.addProject(string(_blob(128, "\"")));
        }
        vm.expectRevert(BuilderRegistry.TooManyProjects.selector);
        builders.addProject("github:c/17");
        vm.stopPrank();
        uint256 sC = _onboard(id);
        badge.tokenURI(_onboard(bobId)); // warm the shared strings for a fair comparison
        uint256 g = gasleft();
        badge.tokenURI(sC);
        uint256 worst = g - gasleft();
        g = gasleft();
        badge.tokenURI(sA);
        uint256 normal = g - gasleft();
        console2.log("tokenURI gas: normal", normal, "worst allowed", worst);
        assertLt(worst, 1_000_000, "bounded");
        assertApproxEqAbs(worst, normal, 5_000, "independent of builder strings");
    }

    /// FIXED (was info): a deactivated builder's badge reads Lapsed at once.
    function test_FIXED_deactivatedBuilderBadgeReadsLapsed() public {
        uint256 s = _onboard(aliceId);
        vm.prank(safe);
        builders.setActive(aliceId, false);
        assertEq(vm.parseJsonString(_json(s), ".attributes[0].value"), "Lapsed");
    }

    // ───────────────────────────── HOLDS ─────────────────────────────

    function test_OK_soulbound_allTransferAndApprovalPathsRevert() public {
        uint256 s = _onboard(aliceId);
        vm.startPrank(alice);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.transferFrom(alice, bob, s);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, bob, s);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, bob, s, "");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        badge.transferFrom(alice, address(0), s); // no self-burn path
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.approve(bob, s);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.setApprovalForAll(bob, true);
        vm.stopPrank();
        // admins cannot move it either
        vm.prank(safe);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.transferFrom(alice, safe, s);
        assertEq(badge.getApproved(s), address(0));
        assertFalse(badge.isApprovedForAll(alice, bob));
        assertEq(badge.ownerOf(s), alice);
        assertTrue(badge.locked(s));
    }

    function test_OK_mintToRejectingContractOwnerSucceeds_noCallback() public {
        RejectingOwner c = new RejectingOwner(builders);
        uint256 id = c.register("", "github:c/c");
        vm.prank(onboarder);
        uint256 s = badge.issue(id);
        assertEq(badge.ownerOf(s), address(c));
    }

    function test_OK_serialsNeverReused_revokeReissue_bookkeeping() public {
        uint256 s1 = _onboard(aliceId);
        vm.prank(operator);
        badge.setLapsed(aliceId, true);
        vm.prank(safe);
        badge.revoke(aliceId);
        assertFalse(badge.lapsed(s1), "lapsed cleared on revoke");
        vm.prank(operator);
        vm.expectRevert(VerifiedBuilderBadge.NoBadge.selector);
        badge.setLapsed(aliceId, true);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, s1));
        badge.locked(s1);

        vm.prank(onboarder);
        uint256 s2 = badge.issue(aliceId);
        assertEq(s2, s1 + 1);
        assertEq(badge.serialOf(aliceId), s2);
        assertEq(badge.builderOf(s2), aliceId);
        assertEq(badge.balanceOf(alice), 1);
        vm.prank(onboarder);
        vm.expectRevert(VerifiedBuilderBadge.AlreadyIssued.selector);
        badge.issue(aliceId);
    }

    function test_OK_issueGuards() public {
        vm.startPrank(onboarder);
        vm.expectRevert(VerifiedBuilderBadge.NotRegistered.selector);
        badge.issue(999);
        vm.stopPrank();
        vm.prank(safe);
        builders.setActive(bobId, false);
        vm.prank(onboarder);
        vm.expectRevert(VerifiedBuilderBadge.InactiveBuilder.selector);
        badge.issue(bobId);
        // an active builder whose only project was removed
        uint256 pid = builders.projectsOf(aliceId)[0];
        vm.prank(alice);
        builders.removeProject(pid);
        vm.prank(onboarder);
        vm.expectRevert(VerifiedBuilderBadge.NoProject.selector);
        badge.issue(aliceId);
    }

    function test_OK_supportsInterface() public view {
        assertEq(type(IERC5192).interfaceId, bytes4(0xb45a3c0e));
        assertTrue(badge.supportsInterface(0xb45a3c0e), "ERC-5192");
        assertTrue(badge.supportsInterface(0x49064906), "ERC-4906");
        assertTrue(badge.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(badge.supportsInterface(0x5b5e139f), "ERC-721 metadata");
        assertTrue(badge.supportsInterface(0x7965db0b), "AccessControl");
        assertTrue(badge.supportsInterface(0x01ffc9a7), "ERC-165");
        assertFalse(badge.supportsInterface(0x780e9d63), "not enumerable");
        assertFalse(badge.supportsInterface(0xffffffff));
    }

    function test_OK_events_Locked_MetadataUpdate_BatchRange() public {
        vm.prank(onboarder);
        caretakers.setCaretaker(aliceId, operator);
        // no BatchMetadataUpdate before any serial exists
        vm.recordLogs();
        vm.prank(safe);
        badge.setBases("a/", "b/");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only BasesSet");

        vm.expectEmit(address(badge));
        emit Locked(1);
        vm.prank(onboarder);
        badge.issue(aliceId);
        vm.prank(onboarder);
        badge.issue(bobId);

        vm.expectEmit(address(badge));
        emit MetadataUpdate(2);
        vm.prank(operator);
        badge.setLapsed(bobId, true);

        vm.expectEmit(address(badge));
        emit BatchMetadataUpdate(1, 2);
        vm.prank(safe);
        badge.setBases("c/", "d/");
    }

    /// Hostile strings: builder-controlled ones (profile, source) are not
    /// rendered at all; admin-set ones (chain label, bases) round-trip escaped
    /// as one string value each — quotes, backslashes, every control char, DEL,
    /// multi-byte UTF-8 and a JSON-injection attempt.
    function test_OK_jsonEscaping_hostileStringsRoundTrip() public {
        bytes memory ctrl = new bytes(32);
        for (uint256 i; i < 32; i++) {
            ctrl[i] = bytes1(uint8(i));
        }
        string memory evil = string(
            abi.encodePacked(
                "x\",\"trait_type\":\"Status\",\"value\":\"Verified\"}]}\\\\\\\"",
                ctrl,
                hex"7f",
                unicode"żółć—🚀",
                hex"e280a8"
            )
        );
        vm.prank(alice);
        builders.addProject(string.concat("github:", "x/y\"}]}"));
        VerifiedBuilderBadge hostile = new VerifiedBuilderBadge(builders, safe, operator, evil, evil, evil);
        vm.prank(safe);
        uint256 s = hostile.issue(aliceId);
        string memory j = _decodeTokenURI(hostile.tokenURI(s));
        assertEq(vm.parseJsonString(j, ".attributes[3].value"), evil, "chain label round trip");
        assertEq(vm.parseJsonString(j, ".image"), string.concat(evil, "1.jpg"), "image base round trip");
        assertEq(vm.parseJsonString(j, ".external_url"), string.concat(evil, vm.toString(aliceId)));
        assertEq(vm.parseJsonUint(j, ".attributes[2].value"), aliceId, "structure intact");
        assertFalse(vm.keyExistsJson(j, ".attributes[5]"), "no injected attribute");
    }

    function test_OK_roleBoundaries_onboarderAndOperator() public {
        uint256 s = _onboard(aliceId);
        bytes32 issuerRole = badge.ISSUER_ROLE();
        bytes32 govRole = caretakers.GOVERNOR_ROLE();
        // onboarder: nothing outside ISSUER + GOVERNOR
        vm.startPrank(onboarder);
        vm.expectRevert();
        badge.setLapsed(aliceId, true);
        vm.expectRevert();
        badge.setBases("x", "y");
        vm.expectRevert();
        badge.grantRole(issuerRole, mallory);
        vm.expectRevert();
        caretakers.grantRole(govRole, mallory);
        vm.expectRevert();
        builders.setActive(aliceId, false);
        vm.expectRevert();
        builders.registerFor(mallory, "registrai:github:x/y");
        // REGISTRAR stays with the Safe: no project or recovery power
        vm.expectRevert();
        builders.addProjectFor(aliceId, "github:x/y");
        vm.expectRevert();
        builders.setProjectActive(1, false);
        vm.expectRevert();
        builders.startRecovery(aliceId, onboarder);
        vm.expectRevert(BuilderRegistry.NotOwner.selector);
        builders.cancelRecovery(aliceId);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        caretakers.setPayout(aliceId, onboarder);
        vm.stopPrank();
        // operator: STATUS only
        vm.startPrank(operator);
        vm.expectRevert();
        badge.issue(bobId);
        vm.expectRevert();
        badge.revoke(aliceId);
        vm.expectRevert();
        caretakers.setCaretaker(bobId, operator);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        caretakers.setPayout(aliceId, operator); // caretaker cannot redirect payout
        vm.expectRevert();
        builders.startRecovery(aliceId, operator);
        vm.expectRevert(BuilderRegistry.NotOwner.selector);
        builders.removeProject(1);
        badge.sync(aliceId); // anyone may sync: a no-op while in sync
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.transferFrom(alice, operator, s);
        vm.stopPrank();
        assertEq(caretakers.payoutOf(aliceId), alice);
    }

    function test_OK_registry_oneBuilderPerAddress_andRegistrarOnlyRegisterFor() public {
        vm.prank(alice);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        builders.registerBuilder("again");
        vm.prank(safe);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        builders.registerFor(alice, "x");
        vm.prank(mallory);
        vm.expectRevert();
        builders.registerFor(makeAddr("victim"), "registrai:github:victim/repo");
        vm.prank(safe);
        vm.expectRevert(BuilderRegistry.ZeroAddress.selector);
        builders.registerFor(address(0), "x");
        address gasless = makeAddr("gasless");
        vm.prank(safe);
        uint256 id = builders.registerFor(gasless, "registrai:github:g/g");
        assertEq(builders.ownerOf(id), gasless, "owner is the builder, not the registrar");
        vm.prank(gasless);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        builders.registerBuilder("x");
    }

    function test_OK_caretakerRegistryGuards() public {
        vm.startPrank(onboarder);
        vm.expectRevert(CaretakerRegistry.NotRegistered.selector);
        caretakers.setCaretaker(999, operator);
        vm.expectRevert(CaretakerRegistry.ZeroAddress.selector);
        caretakers.setCaretaker(aliceId, address(0));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(CaretakerRegistry.ZeroAddress.selector);
        caretakers.setPayout(aliceId, address(0));
        vm.prank(alice);
        caretakers.setPayout(aliceId, bob);
        assertEq(caretakers.payoutOf(aliceId), bob);
        assertEq(caretakers.payoutOf(999), address(0));
        assertFalse(caretakers.isCaretaker(999, address(0)));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Phase 2: the same registries under ProgressPool + ProgressArbiter.
// operator = caretaker = arbiter PROPOSER (runbook / run-arc-caretaker.sh).
// ═══════════════════════════════════════════════════════════════════════════
contract BuilderSideAuditPhase2Test is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    ProgressPool pool;
    ProgressArbiter arb;

    address safe = makeAddr("safe");
    address onboarder = makeAddr("onboarder");
    address operator = makeAddr("operator");
    address resolver = makeAddr("resolver");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");
    address funder = makeAddr("funder");

    uint256 aliceId;
    uint256 constant EPOCH = 7 days;
    uint256 constant WINDOW = 1 hours;
    uint256 constant STAKE = 50e6;

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(safe);
        caretakers = new CaretakerRegistry(builders, safe);
        bytes32 gov = caretakers.GOVERNOR_ROLE();
        vm.prank(safe);
        caretakers.grantRole(gov, onboarder);
        pool = new ProgressPool(ledger, builders, caretakers, safe, EPOCH, 30 days, treasury);
        arb = new ProgressArbiter(ledger, pool, builders, caretakers, safe, WINDOW, STAKE, 10, 7 days);
        vm.startPrank(safe);
        pool.grantRole(pool.PROGRESS_ROLE(), address(arb));
        arb.grantRole(arb.PROPOSER_ROLE(), operator);
        arb.grantRole(arb.RESOLVER_ROLE(), resolver);
        vm.stopPrank();

        vm.prank(alice);
        (aliceId,) = builders.registerBuilderWithProject("", "github:alice/app");
        vm.prank(onboarder);
        caretakers.setCaretaker(aliceId, operator);

        _fund(operator, 500e6);
        vm.prank(operator);
        arb.depositBond(500e6);
        _fund(funder, 1_000e6);
        vm.prank(funder);
        ledger.internalTransfer(address(pool), 1_000e6); // stands in for the commons fee leg
    }

    function _fund(address a, uint256 amt) internal {
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(amt);
        ledger.approveSpender(address(arb), type(uint256).max);
        vm.stopPrank();
    }

    function _proposeAndFinalize(uint256 builderId, uint256 w) internal {
        vm.prank(operator);
        uint256 id = arb.propose(builderId, w);
        vm.warp(block.timestamp + WINDOW + 1);
        arb.finalize(id);
    }

    /// FINDING (Medium, phase 2): CaretakerRegistry GOVERNOR is the sole on-chain
    /// gate on who can draw from the commons. The keeper proposes for every
    /// builder whose caretaker == operator and whose proof is valid, and the
    /// arbiter accepts the operator's proposals exactly for those ids. A
    /// compromised onboarder (GOVERNOR) can admit its own self-registered
    /// sybils (with proofs for repos it controls) and cut real builders off.
    /// Streams opened by the pool are irrevocable (the pool has no cancel), so
    /// revoking the onboarder afterwards does not claw anything back.
    function test_POC_onboarderGovernor_admitsSybilToCommons_andCutsOffBuilder() public {
        vm.prank(mallory);
        (uint256 sybilId,) = builders.registerBuilderWithProject("", "github:mallory/tags-farm");

        // before: the operator cannot propose for the sybil
        vm.prank(operator);
        vm.expectRevert(ProgressArbiter.UnauthorizedCaretaker.selector);
        arb.propose(sybilId, 10);

        // compromised onboarder: admit sybil, cut alice off
        vm.startPrank(onboarder);
        caretakers.setCaretaker(sybilId, operator);
        caretakers.setCaretaker(aliceId, address(0xdead));
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(ProgressArbiter.UnauthorizedCaretaker.selector);
        arb.propose(aliceId, 5); // alice's real progress can no longer be proposed

        // the keeper proposes the sybil's (real, self-made) tags; nothing to challenge
        _proposeAndFinalize(sybilId, 10);

        vm.warp(block.timestamp + EPOCH);
        pool.closeEpoch();

        // Safe reacts: revokes the onboarder, deactivates the sybil
        bytes32 gov = caretakers.GOVERNOR_ROLE();
        vm.startPrank(safe);
        caretakers.revokeRole(gov, onboarder);
        builders.setActive(sybilId, false);
        vm.stopPrank();

        // too late: claimFor has no active check and the stream cannot be cancelled
        uint256 amount = pool.claimFor(0, sybilId);
        assertEq(amount, 990e6, "sybil took the whole pot (net of 1% fee)");
        vm.warp(block.timestamp + 31 days); // integer rate vests slightly after the window
        ledger.settleStream(pool.streamIdOf(0, sybilId));
        assertEq(ledger.balanceOf(mallory), 990e6);
        assertEq(pool.claimable(0, aliceId), 0);
    }

    /// FIXED (was M-3): builder ownership was immutable with no recovery. Now
    /// the Safe (REGISTRAR) recovers a builder to a fresh wallet after
    /// RECOVERY_DELAY; the thief-set payout is ignored once the owner changed
    /// (CaretakerRegistry stores who set it), and claims are keyed by builder id,
    /// so the next claim pays the recovered owner.
    function test_FIXED_M3_builderKeyCompromise_safeRecovers_payoutFallsBack() public {
        _proposeAndFinalize(aliceId, 10);
        vm.warp(block.timestamp + EPOCH);
        pool.closeEpoch();

        address thief = makeAddr("thief");
        vm.prank(alice); // attacker holding alice's key
        caretakers.setPayout(aliceId, thief);
        assertEq(caretakers.payoutOf(aliceId), thief);

        address aliceNew = makeAddr("aliceNew");
        vm.prank(safe);
        builders.startRecovery(aliceId, aliceNew);
        vm.expectRevert(BuilderRegistry.RecoveryNotReady.selector);
        builders.finishRecovery(aliceId);
        vm.warp(block.timestamp + builders.RECOVERY_DELAY());
        builders.finishRecovery(aliceId); // anyone
        assertEq(builders.ownerOf(aliceId), aliceNew);
        assertEq(builders.builderIdOf(alice), 0, "the stolen key holds nothing");
        assertEq(caretakers.payoutOf(aliceId), aliceNew, "thief-set payout ignored");

        uint256 amount = pool.claimFor(0, aliceId); // permissionless
        vm.warp(block.timestamp + 31 days); // integer rate vests slightly after the window
        ledger.settleStream(pool.streamIdOf(0, aliceId));
        assertEq(amount, 990e6);
        assertEq(ledger.balanceOf(aliceNew), amount);
        assertEq(ledger.balanceOf(thief), 0);

        // the old key can no longer act for the builder
        vm.startPrank(alice);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        caretakers.setPayout(aliceId, thief);
        vm.expectRevert(BuilderRegistry.NotRegistered.selector);
        builders.proposeOwner(thief);
        vm.stopPrank();
    }

    /// RESIDUAL (by design, spec "recovery option B"): the current owner may
    /// cancel a recovery for RECOVERY_DELAY, and an owner transfer clears it, so
    /// a thief who keeps using the key can block recovery indefinitely; and
    /// until a recovery finishes, claimFor pays the thief-set payout. The
    /// Safe's levers are setActive(false) (stops new progress) and restarting.
    function test_POC_residual_activeThiefCanCancelRecovery_andClaimMeanwhile() public {
        _proposeAndFinalize(aliceId, 10);
        vm.warp(block.timestamp + EPOCH);
        pool.closeEpoch();
        address thief = makeAddr("thief");
        vm.prank(alice);
        caretakers.setPayout(aliceId, thief);
        vm.prank(safe);
        builders.startRecovery(aliceId, makeAddr("aliceNew"));
        vm.prank(alice); // the thief, with alice's key
        builders.cancelRecovery(aliceId);
        (address pendingNew,) = builders.recoveryOf(aliceId);
        assertEq(pendingNew, address(0));
        pool.claimFor(0, aliceId);
        (, address to,,,,,) = ledger.streams(pool.streamIdOf(0, aliceId));
        assertEq(to, thief);
    }

    /// Context for the role table: in phase 2 the keeper operator is caretaker
    /// of every verified builder AND arbiter PROPOSER, so a leaked operator key
    /// can propose max weight for any of them repeatedly (bounded only by bond,
    /// maxWeight and third-party challenges) — far beyond "flip a badge".
    function test_POC_operatorKeyInPhase2_proposesForAnyCaretakenBuilder() public {
        vm.startPrank(operator);
        for (uint256 i; i < 10; i++) {
            arb.propose(aliceId, 10);
        }
        vm.stopPrank();
        assertEq(arb.entryCount(), 10);
    }

    /// Holds: payout is owner-controlled only; neither the GOVERNOR nor the
    /// caretaker nor the Safe can redirect a builder's claim.
    function test_OK_payoutOnlyOwnerControlled_inClaims() public {
        _proposeAndFinalize(aliceId, 10);
        vm.warp(block.timestamp + EPOCH);
        pool.closeEpoch();
        vm.prank(onboarder);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        caretakers.setPayout(aliceId, onboarder);
        vm.prank(operator);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        caretakers.setPayout(aliceId, operator);
        vm.prank(safe);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        caretakers.setPayout(aliceId, safe);
        vm.prank(operator);
        pool.claimFor(0, aliceId);
        (, address to,,,,,) = ledger.streams(pool.streamIdOf(0, aliceId));
        assertEq(to, alice);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Deploy scripts
// ═══════════════════════════════════════════════════════════════════════════
contract BuilderSideAuditDeployTest is Test {
    MockUSDC usdc;
    address deployer = makeAddr("deployer");
    address admin;
    address agent = makeAddr("agent");
    address disputeResolver = makeAddr("disputeResolver");
    address operator = makeAddr("operator"); // keeper: badge STATUS + arbiter PROPOSER
    address arbResolver = makeAddr("arbResolver");
    address treasury = makeAddr("treasury");
    address protocolTreasury = makeAddr("protocolTreasury");
    address onboarder = makeAddr("onboarder");

    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    VerifiedBuilderBadge badge;
    ProgressPool pool;
    MarketsPerennial perennial;
    ProgressArbiter arbiter;
    MarketsV4 v4;

    function setUp() public {
        usdc = new MockUSDC();
        admin = address(new AuditSafeStub());
    }

    function _usdcAddr() internal view returns (address) {
        return block.chainid == 5042 ? 0x3600000000000000000000000000000000000000 : address(usdc);
    }

    function _buildersCfg() internal view returns (DeployBuilders.Config memory c) {
        c.deployer = deployer;
        c.admin = admin;
        c.operator = operator;
        c.onboarder = onboarder;
        c.chainLabel = "Arc Mainnet";
        c.imageBase = "https://registrai.cc/badge/arc/";
        c.externalBase = "https://registrai.cc/builders/?builder=";
    }

    function _oracleAndLedger() internal {
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 10e6, points: address(0)})
        );
        ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
    }

    function _perennialCfg() internal view returns (DeployPerennial.Config memory c) {
        c.deployer = deployer;
        c.registry = address(registry);
        c.attestation = address(attestation);
        c.ledger = address(ledger);
        c.epochLength = 30 days;
        c.streamWindow = 30 days;
        c.settlementWindow = 24 hours;
        c.resolutionGrace = 7 days;
        c.protocolTreasury = protocolTreasury;
        c.approvedAgent = agent;
        c.disputeResolver = disputeResolver;
    }

    function _arbiterCfg(address caretakerReg) internal view returns (DeployArbiter.Config memory c) {
        c.deployer = deployer;
        c.ledger = address(ledger);
        c.pool = address(pool);
        c.builders = address(builders);
        c.caretakers = caretakerReg;
        c.proposer = operator;
        c.resolver = arbResolver;
        c.challengeWindow = 1 hours;
        c.stakePerProposal = 50e6;
        c.maxWeight = 10;
        c.resolveTimeout = 7 days;
    }

    function _v4Cfg() internal view returns (DeployNanoStack.Config memory c) {
        c.deployer = deployer;
        c.usdc = _usdcAddr();
        c.registry = address(registry);
        c.attestation = address(attestation);
        c.ledger = address(ledger);
        c.treasury = treasury;
        c.settlementWindow = 24 hours;
        c.resolutionGrace = 7 days;
        c.disputeResolver = disputeResolver;
    }

    function _stack() internal view returns (RoleTable.Stack memory s) {
        s.registry = address(registry);
        s.attestation = address(attestation);
        s.ledger = address(ledger);
        s.builders = address(builders);
        s.caretakers = address(caretakers);
        s.pool = address(pool);
        s.perennial = address(perennial);
        s.v4 = address(v4);
        s.arbiter = address(arbiter);
    }

    /// FIXED (was L-1): on mainnet DeployPerennial requires the phase-1
    /// registries and checks the BuilderRegistry's code hash.
    function test_FIXED_mainnet_perennialRequiresPhase1Registries() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        (BuilderRegistry b1, CaretakerRegistry c1,) = new DeployBuilders().deploy(_buildersCfg());
        _oracleAndLedger();
        DeployPerennial p = new DeployPerennial();
        DeployPerennial.Config memory pc = _perennialCfg();
        vm.expectRevert(bytes("mainnet: BUILDER_REGISTRY and CARETAKER_REGISTRY (phase 1) are required"));
        p.deploy(pc);

        // a look-alike registry (other code) is refused
        FakeRegistry fake = new FakeRegistry();
        CaretakerRegistry cFake = new CaretakerRegistry(BuilderRegistry(address(fake)), admin);
        pc.builders = address(fake);
        pc.caretakers = address(cFake);
        vm.expectRevert(bytes("BUILDER_REGISTRY is not this BuilderRegistry"));
        p.deploy(pc);

        pc.builders = address(b1);
        pc.caretakers = address(c1);
        (BuilderRegistry b,,,) = p.deploy(pc);
        assertEq(address(b), address(b1));
    }

    /// FIXED (was L-2): DeployArbiter refuses registries that are not the
    /// pool's, and Handoff/VerifyRoles refuse an arbiter wired elsewhere.
    function test_FIXED_arbiterRegistryMismatchIsRefused() public {
        (builders, caretakers, badge) = new DeployBuilders().deploy(_buildersCfg());
        _oracleAndLedger();
        DeployPerennial.Config memory pc = _perennialCfg();
        pc.builders = address(builders);
        pc.caretakers = address(caretakers);
        (,, pool, perennial) = new DeployPerennial().deploy(pc);

        CaretakerRegistry rogue = new CaretakerRegistry(builders, makeAddr("rogueGov"));
        DeployArbiter da = new DeployArbiter();
        DeployArbiter.Config memory ac = _arbiterCfg(address(rogue));
        vm.expectRevert(bytes("CARETAKER_REGISTRY is not the pool's"));
        da.deploy(ac);

        // hand-built arbiter on the rogue registry: Handoff's final check refuses it
        _handBuiltArbiter(rogue, ac);
        (, v4) = new DeployNanoStack().deploy(_v4Cfg());
        Handoff h = new Handoff();
        vm.expectRevert(bytes("arbiter caretakers"));
        h.handoff(_stack(), admin, deployer);
    }

    function _arbiterArgs(CaretakerRegistry ct, DeployArbiter.Config memory ac) internal view returns (bytes memory) {
        bytes memory head = abi.encode(address(ledger), address(pool), address(builders), address(ct), deployer);
        return bytes.concat(head, abi.encode(ac.challengeWindow, ac.stakePerProposal, ac.maxWeight, ac.resolveTimeout));
    }

    function _handBuiltArbiter(CaretakerRegistry ct, DeployArbiter.Config memory ac) internal {
        bytes memory args = _arbiterArgs(ct, ac);
        vm.startPrank(deployer);
        arbiter = ProgressArbiter(deployCode("ProgressArbiter.sol:ProgressArbiter", args));
        pool.grantRole(pool.PROGRESS_ROLE(), address(arbiter));
        arbiter.grantRole(arbiter.PROPOSER_ROLE(), ac.proposer);
        arbiter.grantRole(arbiter.RESOLVER_ROLE(), ac.resolver);
        vm.stopPrank();
    }

    function test_OK_deployBuilders_roleLayout() public {
        (builders, caretakers, badge) = new DeployBuilders().deploy(_buildersCfg());
        bytes32 da = 0x00;
        assertTrue(badge.hasRole(badge.STATUS_ROLE(), operator));
        assertFalse(builders.hasRole(da, operator) || builders.hasRole(builders.REGISTRAR_ROLE(), operator));
        assertFalse(caretakers.hasRole(da, operator) || caretakers.hasRole(caretakers.GOVERNOR_ROLE(), operator));
        assertFalse(badge.hasRole(badge.STATUS_ROLE(), admin), "Safe does not hold STATUS (can grant it)");
        assertEq(badge.getRoleAdmin(badge.ISSUER_ROLE()), da);
        assertEq(badge.getRoleAdmin(badge.STATUS_ROLE()), da);
        assertEq(caretakers.getRoleAdmin(caretakers.GOVERNOR_ROLE()), da);
        assertFalse(badge.hasRole(da, deployer) || caretakers.hasRole(da, deployer) || builders.hasRole(da, deployer));
    }

    /// Holds: the reuse check rejects a CaretakerRegistry of another registry.
    function test_OK_perennialReuse_rejectsForeignCaretakers() public {
        (builders, caretakers, badge) = new DeployBuilders().deploy(_buildersCfg());
        _oracleAndLedger();
        CaretakerRegistry foreign = new CaretakerRegistry(new BuilderRegistry(admin), admin);
        DeployPerennial.Config memory pc = _perennialCfg();
        pc.builders = address(builders);
        pc.caretakers = address(foreign);
        DeployPerennial p = new DeployPerennial();
        vm.expectRevert(bytes("CARETAKER_REGISTRY belongs to a different BuilderRegistry"));
        p.deploy(pc);
    }

    /// Holds: DeployBadge on mainnet refuses an EOA admin and deployer roles.
    function test_OK_deployBadge_mainnetGuards() public {
        builders = new BuilderRegistry(admin);
        vm.chainId(5042);
        DeployBadge d = new DeployBadge();
        DeployBadge.Config memory c;
        c.deployer = deployer;
        c.builders = address(builders);
        c.admin = makeAddr("eoa");
        c.operator = operator;
        vm.expectRevert(bytes("mainnet: ADMIN must be a contract (Safe/timelock), not an EOA"));
        d.deploy(c);
        c.admin = admin;
        c.operator = deployer;
        vm.expectRevert(bytes("mainnet: deployer must hold no badge role"));
        d.deploy(c);
        c.operator = operator;
        VerifiedBuilderBadge b = d.deploy(c);
        assertFalse(b.hasRole(0x00, deployer));
    }
}
