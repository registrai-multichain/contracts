// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {VerifiedBuilderBadge, IERC5192} from "../../src/perennial/VerifiedBuilderBadge.sol";

contract VerifiedBuilderBadgeTest is Test {
    BuilderRegistry builders;
    VerifiedBuilderBadge badge;

    address admin = makeAddr("admin"); // the Safe
    address keeper = makeAddr("keeper"); // operator key: STATUS only
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 aliceId;
    uint256 bobId;

    event Locked(uint256 tokenId);
    event MetadataUpdate(uint256 _tokenId);

    function setUp() public {
        builders = new BuilderRegistry(admin);
        badge = new VerifiedBuilderBadge(
            builders, admin, keeper, "Arc Mainnet", "https://registrai.cc/badge/arc/", "https://registrai.cc/atlas/?builder="
        );
        vm.prank(alice);
        aliceId = builders.registerBuilder("registrai:github:alice/app");
        vm.prank(bob);
        bobId = builders.registerBuilder("registrai:domain:bob.xyz");
    }

    function _issue(uint256 id) internal returns (uint256) {
        vm.prank(admin);
        return badge.issue(id);
    }

    // ───────────── roles ─────────────

    function test_rolesAtDeploy() public view {
        assertTrue(badge.hasRole(badge.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(badge.hasRole(badge.ISSUER_ROLE(), admin));
        assertTrue(badge.hasRole(badge.STATUS_ROLE(), keeper));
        assertFalse(badge.hasRole(badge.ISSUER_ROLE(), keeper));
        assertFalse(badge.hasRole(badge.DEFAULT_ADMIN_ROLE(), keeper));
        assertFalse(badge.hasRole(badge.DEFAULT_ADMIN_ROLE(), address(this)), "deployer holds nothing");
        assertFalse(badge.hasRole(badge.ISSUER_ROLE(), address(this)));
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(VerifiedBuilderBadge.ZeroAddress.selector);
        new VerifiedBuilderBadge(builders, address(0), keeper, "", "", "");
        vm.expectRevert(VerifiedBuilderBadge.ZeroAddress.selector);
        new VerifiedBuilderBadge(builders, admin, address(0), "", "", "");
        vm.expectRevert(VerifiedBuilderBadge.ZeroAddress.selector);
        new VerifiedBuilderBadge(BuilderRegistry(address(0)), admin, keeper, "", "", "");
    }

    function test_keeperCannotIssueOrRevoke() public {
        bytes32 issuer = badge.ISSUER_ROLE();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, issuer));
        badge.issue(aliceId);
        _issue(aliceId);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, issuer));
        badge.revoke(aliceId);
    }

    function test_strangerCannotAnything() public {
        vm.startPrank(carol);
        vm.expectRevert();
        badge.issue(aliceId);
        vm.expectRevert();
        badge.setLapsed(aliceId, true);
        vm.expectRevert();
        badge.setBases("x", "y");
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert();
        badge.setBases("x", "y");
    }

    // ───────────── issue ─────────────

    function test_issueMintsSerialsInOrderToRegistryOwner() public {
        vm.expectEmit(address(badge));
        emit Locked(1);
        assertEq(_issue(bobId), 1);
        assertEq(_issue(aliceId), 2);
        assertEq(badge.ownerOf(1), bob);
        assertEq(badge.ownerOf(2), alice);
        assertEq(badge.serialOf(bobId), 1);
        assertEq(badge.builderOf(2), aliceId);
        assertEq(badge.balanceOf(alice), 1);
        assertEq(badge.issuedAt(1), block.timestamp);
        assertTrue(badge.locked(1));
    }

    function test_issueRejectsUnregisteredInactiveAndDuplicate() public {
        vm.prank(admin);
        vm.expectRevert(VerifiedBuilderBadge.NotRegistered.selector);
        badge.issue(99);

        vm.prank(admin);
        builders.setActive(aliceId, false);
        vm.prank(admin);
        vm.expectRevert(VerifiedBuilderBadge.InactiveBuilder.selector);
        badge.issue(aliceId);

        _issue(bobId);
        vm.prank(admin);
        vm.expectRevert(VerifiedBuilderBadge.AlreadyIssued.selector);
        badge.issue(bobId);
    }

    function test_revokeRetiresSerialAndReissueGetsNewOne() public {
        _issue(aliceId); // 1
        vm.prank(keeper);
        badge.setLapsed(aliceId, true);
        vm.prank(admin);
        badge.revoke(aliceId);
        assertEq(badge.serialOf(aliceId), 0);
        assertEq(badge.balanceOf(alice), 0);
        assertFalse(badge.lapsed(1));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        badge.ownerOf(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        badge.tokenURI(1);

        assertEq(_issue(aliceId), 2, "serials are never reused");

        vm.prank(admin);
        vm.expectRevert(VerifiedBuilderBadge.NoBadge.selector);
        badge.revoke(bobId);
    }

    // ───────────── soulbound ─────────────

    function test_cannotTransferOrApprove() public {
        _issue(aliceId);
        vm.startPrank(alice);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.transferFrom(alice, carol, 1);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, carol, 1);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, carol, 1, "");
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.approve(carol, 1);
        vm.expectRevert(VerifiedBuilderBadge.Soulbound.selector);
        badge.setApprovalForAll(carol, true);
        vm.stopPrank();
        assertEq(badge.ownerOf(1), alice);
        assertEq(badge.getApproved(1), address(0));
        assertFalse(badge.isApprovedForAll(alice, carol));
    }

    function test_lockedRevertsForMissingToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 5));
        badge.locked(5);
    }

    function test_interfaces() public view {
        assertTrue(badge.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(badge.supportsInterface(0x5b5e139f), "ERC721Metadata");
        assertTrue(badge.supportsInterface(0xb45a3c0e), "ERC5192");
        assertTrue(badge.supportsInterface(0x49064906), "ERC4906");
        assertTrue(badge.supportsInterface(type(IERC5192).interfaceId));
        assertTrue(badge.supportsInterface(type(IAccessControl).interfaceId));
        assertFalse(badge.supportsInterface(0xffffffff));
    }

    // ───────────── status ─────────────

    function test_keeperTogglesLapsedIdempotently() public {
        _issue(aliceId);
        vm.expectEmit(address(badge));
        emit MetadataUpdate(1);
        vm.prank(keeper);
        badge.setLapsed(aliceId, true);
        assertTrue(badge.lapsed(1));

        vm.recordLogs();
        vm.prank(keeper);
        badge.setLapsed(aliceId, true); // no-op
        assertEq(vm.getRecordedLogs().length, 0, "idempotent: no event");

        vm.prank(keeper);
        badge.setLapsed(aliceId, false);
        assertFalse(badge.lapsed(1));
        assertEq(badge.ownerOf(1), alice, "status never moves the token");
    }

    function test_setLapsedNeedsBadge() public {
        vm.prank(keeper);
        vm.expectRevert(VerifiedBuilderBadge.NoBadge.selector);
        badge.setLapsed(aliceId, true);
    }

    // ───────────── metadata ─────────────

    function _json(uint256 serial) internal view returns (string memory) {
        string memory uri = badge.tokenURI(serial);
        bytes memory u = bytes(uri);
        string memory prefix = "data:application/json;base64,";
        uint256 p = bytes(prefix).length;
        for (uint256 i; i < p; i++) {
            assertEq(u[i], bytes(prefix)[i]);
        }
        bytes memory b64 = new bytes(u.length - p);
        for (uint256 i; i < b64.length; i++) {
            b64[i] = u[i + p];
        }
        return string(_b64decode(string(b64)));
    }

    function test_tokenURIIsValidJson() public {
        vm.warp(1_790_000_000);
        _issue(aliceId);
        string memory j = _json(1);
        assertEq(vm.parseJsonString(j, ".name"), "Registrai Verified Builder No. 001");
        assertEq(vm.parseJsonString(j, ".image"), "https://registrai.cc/badge/arc/1.jpg");
        assertEq(vm.parseJsonString(j, ".external_url"), string.concat("https://registrai.cc/atlas/?builder=", vm.toString(aliceId)));
        assertEq(vm.parseJsonString(j, ".attributes[0].value"), "Verified");
        assertEq(vm.parseJsonUint(j, ".attributes[1].value"), 1);
        assertEq(vm.parseJsonUint(j, ".attributes[2].value"), aliceId);
        assertEq(vm.parseJsonString(j, ".attributes[3].value"), "github:alice/app");
        assertEq(vm.parseJsonString(j, ".attributes[4].value"), "Arc Mainnet");
        assertEq(vm.parseJsonUint(j, ".attributes[5].value"), 1_790_000_000);

        vm.prank(keeper);
        badge.setLapsed(aliceId, true);
        j = _json(1);
        assertEq(vm.parseJsonString(j, ".image"), "https://registrai.cc/badge/arc/1-lapsed.jpg");
        assertEq(vm.parseJsonString(j, ".attributes[0].value"), "Lapsed");
    }

    function test_serialPadding() public {
        for (uint256 i = 1; i <= 12; i++) {
            address w = address(uint160(0x1000 + i));
            vm.prank(w);
            uint256 id = builders.registerBuilder("registrai:github:x/y");
            _issue(id);
        }
        // alice/bob hold none; serial 12 went to the 12th registration
        assertEq(vm.parseJsonString(_json(9), ".name"), "Registrai Verified Builder No. 009");
        assertEq(vm.parseJsonString(_json(12), ".name"), "Registrai Verified Builder No. 012");
    }

    /// The profile link is builder-controlled: quotes, backslashes and control
    /// characters must not break (or inject into) the JSON.
    function test_hostileProfileIsEscaped() public {
        vm.prank(carol);
        uint256 id = builders.registerBuilder(
            string.concat("registrai:github:a\"},{\"trait_type\":\"Status\",\"value\":\"Verified\\", string(hex"0a0d09")) // quote, backslash, \n\r\t
        );
        uint256 serial = _issue(id);
        string memory j = _json(serial);
        assertEq(
            vm.parseJsonString(j, ".attributes[3].value"),
            string.concat("github:a\"},{\"trait_type\":\"Status\",\"value\":\"Verified\\", string(hex"0a0d09"))
        );
        assertEq(vm.parseJsonString(j, ".attributes[4].value"), "Arc Mainnet", "no injected attribute");
    }

    function test_sourceOfNonRegistraiProfileIsEmpty() public {
        vm.prank(carol);
        uint256 id = builders.registerBuilder("ipfs://whatever");
        assertEq(badge.sourceOf(id), "");
        vm.prank(alice);
        builders.updateProfile("registrai:");
        assertEq(badge.sourceOf(aliceId), "");
        assertEq(badge.sourceOf(bobId), "domain:bob.xyz");
    }

    function test_setBasesByAdmin() public {
        _issue(aliceId);
        vm.prank(admin);
        badge.setBases("ipfs://cid/", "https://x/?b=");
        assertEq(vm.parseJsonString(_json(1), ".image"), "ipfs://cid/1.jpg");
    }

    // ───────────── helpers ─────────────

    function _b64decode(string memory s) internal pure returns (bytes memory) {
        bytes memory data = bytes(s);
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
}
