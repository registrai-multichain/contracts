// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";

contract BuilderRegistryV2Test is Test {
    BuilderRegistry reg;
    address admin = address(this);
    address builder = address(0xB0B);
    address stranger = address(0x5757);

    function setUp() public {
        reg = new BuilderRegistry(admin);
    }

    function test_registerFor_setsOwnerToBuilder() public {
        uint256 id = reg.registerFor(builder, "ipfs://b");
        assertEq(id, 1);
        assertEq(reg.ownerOf(1), builder, "owner is the builder, not caller");
        assertEq(reg.builderIdOf(builder), 1);
        assertTrue(reg.isRegistered(builder));
    }

    function test_registerFor_onlyRegistrar() public {
        vm.prank(stranger);
        vm.expectRevert();
        reg.registerFor(builder, "ipfs://b");
    }

    function test_registerFor_alreadyRegistered() public {
        reg.registerFor(builder, "ipfs://b");
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        reg.registerFor(builder, "ipfs://dup");
    }

    function test_registerFor_zeroReverts() public {
        vm.expectRevert(BuilderRegistry.ZeroAddress.selector);
        reg.registerFor(address(0), "ipfs://b");
    }

    function test_selfRegister_stillWorks() public {
        vm.prank(builder);
        uint256 id = reg.registerBuilder("ipfs://self");
        assertEq(reg.ownerOf(id), builder);
    }
}
