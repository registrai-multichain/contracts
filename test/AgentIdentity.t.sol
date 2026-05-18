// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";

contract AgentIdentityTest is Test {
    AgentIdentity ident;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        ident = new AgentIdentity();
    }

    function test_setProfile_writesFields() public {
        vm.prank(alice);
        ident.setProfile("Alice Resi", "Warsaw real estate", "https://alice.example", "@alice");

        AgentIdentity.Profile memory p = ident.getProfile(alice);
        assertEq(p.name, "Alice Resi");
        assertEq(p.description, "Warsaw real estate");
        assertEq(p.url, "https://alice.example");
        assertEq(p.contact, "@alice");
        assertTrue(p.exists);
        assertEq(p.registeredAt, p.updatedAt);
    }

    function test_setProfile_updateBumpsUpdatedAt() public {
        vm.prank(alice);
        ident.setProfile("Alice", "v1", "", "");
        uint64 registeredAt = ident.getProfile(alice).registeredAt;

        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        ident.setProfile("Alice", "v2", "", "");

        AgentIdentity.Profile memory p = ident.getProfile(alice);
        assertEq(p.registeredAt, registeredAt); // immutable
        assertGt(p.updatedAt, registeredAt);    // bumped
        assertEq(p.description, "v2");
    }

    function test_setProfile_perAddress() public {
        vm.prank(alice);
        ident.setProfile("Alice", "", "", "");
        vm.prank(bob);
        ident.setProfile("Bob", "", "", "");

        assertEq(ident.getProfile(alice).name, "Alice");
        assertEq(ident.getProfile(bob).name, "Bob");
    }

    function test_revert_emptyName() public {
        vm.expectRevert(AgentIdentity.NameRequired.selector);
        vm.prank(alice);
        ident.setProfile("", "x", "", "");
    }

    function test_revert_nameTooLong() public {
        string memory tooLong = "this name is over sixty four characters which is longer than the cap";
        vm.expectRevert(AgentIdentity.NameTooLong.selector);
        vm.prank(alice);
        ident.setProfile(tooLong, "", "", "");
    }

    function test_revert_fieldTooLong() public {
        // Build a 513-byte string.
        bytes memory big = new bytes(513);
        for (uint256 i = 0; i < 513; ++i) big[i] = "a";
        vm.expectRevert(AgentIdentity.FieldTooLong.selector);
        vm.prank(alice);
        ident.setProfile("ok", string(big), "", "");
    }

    function test_hasProfile() public {
        assertFalse(ident.hasProfile(alice));
        vm.prank(alice);
        ident.setProfile("Alice", "", "", "");
        assertTrue(ident.hasProfile(alice));
    }

    function test_anyoneCanRegister_noAdmin() public {
        // No setUp wiring needed. Multiple unrelated addresses.
        for (uint256 i = 1; i <= 5; i++) {
            address a = address(uint160(0xCafe0000 + i));
            vm.prank(a);
            ident.setProfile(string.concat("Agent", vm.toString(i)), "", "", "");
            assertTrue(ident.hasProfile(a));
        }
    }
}
