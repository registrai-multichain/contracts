// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

contract CaretakerRegistryTest is Test {
    BuilderRegistry builders;
    CaretakerRegistry care;

    address admin = address(this);
    address builderOwner = address(0xB0B);
    address caretakerOp = address(0xCA4E);
    address payout = address(0xBEEF);
    address stranger = address(0x5757);
    uint256 id;

    function setUp() public {
        builders = new BuilderRegistry(address(this));
        care = new CaretakerRegistry(builders, admin);
        vm.prank(builderOwner);
        id = builders.registerBuilder("ipfs://b"); // id == 1
    }

    function test_governorSetsCaretaker() public {
        care.setCaretaker(id, caretakerOp);
        assertEq(care.caretakerOf(id), caretakerOp);
        assertTrue(care.isCaretaker(id, caretakerOp));
        assertFalse(care.isCaretaker(id, stranger));
    }

    function test_nonGovernorCannotSetCaretaker() public {
        vm.prank(stranger);
        vm.expectRevert();
        care.setCaretaker(id, caretakerOp);
    }

    function test_setCaretaker_unregisteredReverts() public {
        vm.expectRevert(CaretakerRegistry.NotRegistered.selector);
        care.setCaretaker(999, caretakerOp);
    }

    function test_setCaretaker_zeroReverts() public {
        vm.expectRevert(CaretakerRegistry.ZeroAddress.selector);
        care.setCaretaker(id, address(0));
    }

    function test_ownerSetsPayout() public {
        vm.prank(builderOwner);
        care.setPayout(id, payout);
        assertEq(care.payoutOf(id), payout);
    }

    function test_payoutDefaultsToOwner() public {
        assertEq(care.payoutOf(id), builderOwner);
    }

    function test_caretakerCannotSetPayout() public {
        care.setCaretaker(id, caretakerOp);
        vm.prank(caretakerOp);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        care.setPayout(id, caretakerOp);
    }

    function test_strangerCannotSetPayout() public {
        vm.prank(stranger);
        vm.expectRevert(CaretakerRegistry.NotOwner.selector);
        care.setPayout(id, stranger);
    }

    function test_setPayout_zeroReverts() public {
        vm.prank(builderOwner);
        vm.expectRevert(CaretakerRegistry.ZeroAddress.selector);
        care.setPayout(id, address(0));
    }
}
