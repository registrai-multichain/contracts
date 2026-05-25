// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {Markets} from "../src/Markets.sol";
import {RegistraiPoints} from "../src/RegistraiPoints.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice End-to-end smoke for the points integration: register, attest,
///         create market — each should award the documented amount.
contract PointsTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    Markets markets;
    RegistraiPoints points;

    address deployer = address(this); // deployer is the test contract
    address agent = makeAddr("agent");
    address treasury = makeAddr("treasury");

    bytes32 constant METHODOLOGY = keccak256("ipfs://methodology");

    function setUp() public {
        usdc = new MockUSDC();
        points = new RegistraiPoints();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        markets = new Markets(attestation, registry, usdc, treasury);

        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        registry.setPoints(address(points));
        attestation.setPoints(address(points));
        markets.setPoints(address(points));

        points.setMinter(address(registry), true);
        points.setMinter(address(attestation), true);
        points.setMinter(address(markets), true);

        usdc.mint(agent, 10_000e6);
    }

    function test_register_awardsPoints() public {
        // agent creates a feed and registers as its agent (v2 rule)
        vm.startPrank(agent);
        bytes32 feedId = registry.createFeed(
            "test", METHODOLOGY, 10e6, 1 hours, agent
        );
        usdc.approve(address(registry), 10e6);
        registry.registerAgent(feedId, METHODOLOGY, 10e6);
        vm.stopPrank();

        assertEq(points.points(agent), 1000, "register should award 1000 points");
    }

    function test_attest_awardsPoints() public {
        vm.startPrank(agent);
        bytes32 feedId = registry.createFeed("test", METHODOLOGY, 10e6, 1 hours, agent);
        usdc.approve(address(registry), 10e6);
        registry.registerAgent(feedId, METHODOLOGY, 10e6);

        attestation.attest(feedId, 100, keccak256("inputs"));
        vm.stopPrank();

        // 1000 (register) + 50 (attest) = 1050
        assertEq(points.points(agent), 1050, "attest should add 50 points");
    }
}
