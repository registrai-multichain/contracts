// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SuffixTreasury} from "../src/suffix/SuffixTreasury.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// Proves the production admin posture: GOVERNOR_ROLE held by a
/// TimelockController, so risk-parameter changes (e.g. setSeniorCap) are
/// delayed + governed, not instant single-key actions.
contract SuffixGovernanceTest is Test {
    MockUSDC usdc;
    SuffixTreasury t;
    TimelockController tl;

    uint256 constant DELAY = 2 days;

    function setUp() public {
        usdc = new MockUSDC();
        t = new SuffixTreasury(usdc, address(this), "Suffix AI", "ai"); // deployer = initial admin

        address[] memory props = new address[](1);
        props[0] = address(this);
        address[] memory execs = new address[](1);
        execs[0] = address(this);
        tl = new TimelockController(DELAY, props, execs, address(0));

        // Hand GOVERNOR_ROLE to the timelock; deployer renounces it.
        t.grantRole(t.GOVERNOR_ROLE(), address(tl));
        t.renounceRole(t.GOVERNOR_ROLE(), address(this));
    }

    function test_governorParamChangeMustGoThroughTimelock() public {
        // Direct call now fails — deployer is no longer GOVERNOR.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                t.GOVERNOR_ROLE()
            )
        );
        t.setSeniorCap(1_000e6);

        bytes memory data = abi.encodeWithSelector(t.setSeniorCap.selector, 1_000e6);
        bytes32 salt = keccak256("cap");

        // Schedule + try to execute before the delay → reverts.
        tl.schedule(address(t), 0, data, bytes32(0), salt, DELAY);
        vm.expectRevert();
        tl.execute(address(t), 0, data, bytes32(0), salt);

        // After the delay, execution succeeds and the param is set.
        vm.warp(block.timestamp + DELAY + 1);
        tl.execute(address(t), 0, data, bytes32(0), salt);
        assertEq(t.seniorCap(), 1_000e6);
    }
}
