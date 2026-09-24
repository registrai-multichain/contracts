// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Builder-side security audit (pre mainnet phase 1).
/// Scope: BuilderRegistry, CaretakerRegistry, VerifiedBuilderBadge,
/// DeployBuilders / DeployPerennial (reuse path) / DeployBadge.
/// Updated for builders-with-projects (2026-09-24-builder-projects-design):
/// M-2 is superseded (the badge names no project), M-3 is fixed (owner
/// transfer + REGISTRAR recovery + payout fallback). Updated for builder income
/// (2026-09-24-builder-income-tax-design): ProgressPool + ProgressArbiter gave
/// way to BuilderFund + SeasonPool; M-1 is revisited (the caretaker no longer
/// gates any money) and deactivation now stops payouts.
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
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {LaunchSchedule} from "../../script/lib/LaunchSchedule.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge, IERC5192} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {RoleTable} from "../../script/lib/RoleTable.sol";
import {DeployOracle} from "../../script/DeployOracle.s.sol";
import {DeployNanoLedger} from "../../script/DeployNanoLedger.s.sol";
import {DeployPerennial} from "../../script/DeployPerennial.s.sol";
import {DeployBuilders} from "../../script/DeployBuilders.s.sol";
import {DeployBadge} from "../../script/DeployBadge.s.sol";
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
    address operator = makeAddr("operator"); // keeper: badge STATUS (and, in phase 2, caretaker)
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
// Phase 2: the same registries under BuilderFund + SeasonPool.
// operator = caretaker (keeper: crank claims, badge status); `markets` stands in
// for MarketsPerennial, the fund's only MARKETS_ROLE.
// ═══════════════════════════════════════════════════════════════════════════
contract BuilderSideAuditPhase2Test is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    SeasonPool pool;
    BuilderFund fund;

    address safe = makeAddr("safe");
    address onboarder = makeAddr("onboarder");
    address operator = makeAddr("operator");
    address markets = makeAddr("markets");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");

    uint256 aliceId;
    uint256 constant EPOCH = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(safe);
        caretakers = new CaretakerRegistry(builders, safe);
        bytes32 gov = caretakers.GOVERNOR_ROLE();
        vm.prank(safe);
        caretakers.grantRole(gov, onboarder);
        pool = new SeasonPool(ledger, builders, caretakers, safe);
        fund = new BuilderFund(ledger, builders, caretakers, pool, treasury, safe, EPOCH, LaunchSchedule.brackets());
        vm.startPrank(safe);
        pool.grantRole(pool.FUNDER_ROLE(), address(fund));
        fund.grantRole(fund.MARKETS_ROLE(), markets);
        vm.stopPrank();

        vm.prank(alice);
        (aliceId,) = builders.registerBuilderWithProject("", "github:alice/app");
        vm.prank(onboarder);
        caretakers.setCaretaker(aliceId, operator);

        usdc.mint(markets, 1_000_000e6);
        vm.startPrank(markets);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000_000e6);
        vm.stopPrank();
    }

    /// The builder leg of trades on markets about `builderId`.
    function _earn(uint256 builderId, uint256 amount) internal {
        vm.startPrank(markets);
        ledger.internalTransfer(address(fund), amount);
        fund.credit(builderId, amount);
        vm.stopPrank();
    }

    /// REVISITED (was M-1, Medium): CaretakerRegistry GOVERNOR was the sole
    /// on-chain gate on who could draw from the commons (the arbiter accepted
    /// the operator's proposals exactly for the ids it caretook). With the
    /// ProgressArbiter gone, no contract reads caretakerOf: income follows the
    /// builder id each market names, and is paid to payoutOf (owner-set). A
    /// compromised onboarder (GOVERNOR) can re-point caretakers but moves no
    /// money: alice is still paid in full, the sybil earns only what markets
    /// about it earn. What remains is off-chain: the keeper's / gallery's
    /// "verified" status and the season eligibility the Safe re-derives before
    /// publishing a root (the same kind of power as the onboarder's badge
    /// ISSUER). VerifyRoles therefore only logs its GOVERNOR on mainnet.
    function test_REVISITED_M1_onboarderGovernor_movesNoMoney() public {
        vm.prank(mallory);
        (uint256 sybilId,) = builders.registerBuilderWithProject("", "github:mallory/tags-farm");
        _earn(aliceId, 1_000e6);

        // compromised onboarder: admit the sybil, cut alice off
        vm.startPrank(onboarder);
        caretakers.setCaretaker(sybilId, operator);
        caretakers.setCaretaker(aliceId, address(0xdead));
        vm.stopPrank();

        vm.warp(fund.epochEnd(0));
        assertEq(fund.claimFor(0, aliceId), 990e6, "alice keeps her income");
        assertEq(ledger.balanceOf(alice), 990e6);
        vm.expectRevert(BuilderFund.NoIncome.selector);
        fund.claimFor(0, sybilId); // being caretaken earns nothing
        assertEq(ledger.balanceOf(mallory), 0);
        assertEq(ledger.balanceOf(address(0xdead)) + ledger.balanceOf(onboarder), 0);
    }

    /// FIXED (the lever the audit found missing): the old pool's claimFor had
    /// no active check and its streams were irrevocable, so deactivating a
    /// builder never stopped a payout. Now a deactivated builder's claim
    /// reverts and the Safe sweeps the income to the season pool.
    function test_FIXED_deactivationStopsPayouts() public {
        vm.prank(mallory);
        (uint256 sybilId,) = builders.registerBuilderWithProject("", "github:mallory/tags-farm");
        _earn(sybilId, 1_000e6); // e.g. wash-traded markets about the sybil
        vm.prank(safe);
        builders.setActive(sybilId, false);
        vm.warp(fund.epochEnd(0));
        vm.expectRevert(BuilderFund.BuilderInactive.selector);
        fund.claimFor(0, sybilId);
        vm.prank(safe);
        fund.sweepFrozen(0, sybilId);
        assertEq(pool.unallocated(), 1_000e6, "swept whole to the season pool");
        assertEq(ledger.balanceOf(mallory), 0);
    }

    /// FIXED (was M-3): builder ownership was immutable with no recovery. Now
    /// the Safe (REGISTRAR) recovers a builder to a fresh wallet after
    /// RECOVERY_DELAY; the thief-set payout is ignored once the owner changed
    /// (CaretakerRegistry stores who set it), and income is keyed by builder id,
    /// so the next claim pays the recovered owner.
    function test_FIXED_M3_builderKeyCompromise_safeRecovers_payoutFallsBack() public {
        _earn(aliceId, 1_000e6);
        vm.warp(fund.epochEnd(0));

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

        uint256 amount = fund.claimFor(0, aliceId); // permissionless
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
    /// Safe's lever is now effective: setActive(false) freezes the builder's
    /// claims (and sweepFrozen can park the income in the season pool).
    function test_POC_residual_activeThiefCanCancelRecovery_safeFreezesClaims() public {
        _earn(aliceId, 1_000e6);
        vm.warp(fund.epochEnd(0));
        _earn(aliceId, 500e6); // epoch 1
        address thief = makeAddr("thief");
        vm.prank(alice);
        caretakers.setPayout(aliceId, thief);
        vm.prank(safe);
        builders.startRecovery(aliceId, makeAddr("aliceNew"));
        vm.prank(alice); // the thief, with alice's key
        builders.cancelRecovery(aliceId);
        (address pendingNew,) = builders.recoveryOf(aliceId);
        assertEq(pendingNew, address(0));
        fund.claimFor(0, aliceId); // residual: the Safe did not freeze in time
        assertEq(ledger.balanceOf(thief), 990e6);

        vm.prank(safe);
        builders.setActive(aliceId, false); // freeze
        vm.warp(fund.epochEnd(1));
        vm.expectRevert(BuilderFund.BuilderInactive.selector);
        fund.claimFor(1, aliceId);
        assertEq(ledger.balanceOf(thief), 990e6, "no further payout while frozen");
    }

    /// Holds: the keeper operator (caretaker) holds no money role. A leaked
    /// operator key can crank claims (to the builders) and nothing else here.
    function test_OK_operatorKeyInPhase2_holdsNoMoneyRole() public {
        _earn(aliceId, 100e6);
        vm.warp(fund.epochEnd(0));
        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, fund.MARKETS_ROLE())
        );
        fund.credit(aliceId, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, fund.GOVERNOR_ROLE())
        );
        fund.sweepFrozen(0, aliceId);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, pool.FUNDER_ROLE())
        );
        pool.fund(1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, pool.GOVERNOR_ROLE())
        );
        pool.publishSeason(1, bytes32(uint256(1)), 1, uint64(block.timestamp + 1));
        fund.claimFor(0, aliceId);
        vm.stopPrank();
        assertEq(ledger.balanceOf(operator), 0);
        assertEq(ledger.balanceOf(alice), 99e6);
    }

    /// Holds: payout is owner-controlled only; neither the GOVERNOR nor the
    /// caretaker nor the Safe can redirect a builder's claim.
    function test_OK_payoutOnlyOwnerControlled_inClaims() public {
        _earn(aliceId, 1_000e6);
        vm.warp(fund.epochEnd(0));
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
        fund.claimFor(0, aliceId);
        assertEq(ledger.balanceOf(alice), 990e6);
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
    address operator = makeAddr("operator"); // keeper: badge STATUS + caretaker
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
    BuilderFund fund;
    SeasonPool pool;
    MarketsPerennial perennial;
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
        c.settlementWindow = 24 hours;
        c.resolutionGrace = 7 days;
        c.protocolTreasury = protocolTreasury;
        c.approvedAgent = agent;
        c.disputeResolver = disputeResolver;
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
        s.fund = address(fund);
        s.seasonPool = address(pool);
        s.perennial = address(perennial);
        s.v4 = address(v4);
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
        DeployPerennial.Deployed memory d = p.deploy(pc);
        assertEq(address(d.builders), address(b1));
        assertEq(address(d.fund.CARETAKERS()), address(c1));
        assertEq(address(d.seasonPool.CARETAKERS()), address(c1));
    }

    /// FIXED (was L-2, re-targeted from the arbiter to the fund): a fund or
    /// season pool paying through registries other than phase 1's is refused
    /// by Handoff/VerifyRoles' final check.
    function test_FIXED_fundRegistryMismatchIsRefused() public {
        (builders, caretakers, badge) = new DeployBuilders().deploy(_buildersCfg());
        _oracleAndLedger();
        (, v4) = new DeployNanoStack().deploy(_v4Cfg());

        // hand-built fund + pool on a rogue CaretakerRegistry (same builders)
        CaretakerRegistry rogue = new CaretakerRegistry(builders, makeAddr("rogueGov"));
        vm.startPrank(deployer);
        pool = new SeasonPool(ledger, builders, rogue, deployer);
        fund = new BuilderFund(ledger, builders, rogue, pool, protocolTreasury, deployer, 30 days, LaunchSchedule.brackets());
        perennial = new MarketsPerennial(ledger, registry, attestation, builders, deployer, fund, 24 hours, 7 days);
        fund.grantRole(fund.MARKETS_ROLE(), address(perennial));
        pool.grantRole(pool.FUNDER_ROLE(), address(fund));
        vm.stopPrank();
        Handoff h = new Handoff();
        vm.expectRevert(bytes("fund caretakers"));
        h.handoff(_stack(), admin, deployer);
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
