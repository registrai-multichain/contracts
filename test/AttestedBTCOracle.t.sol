// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Attestation} from "../src/Attestation.sol";
import {Registry} from "../src/Registry.sol";
import {Dispute} from "../src/Dispute.sol";
import {AttestedBTCOracle} from "../src/AttestedBTCOracle.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AttestedBTCOracleTest is Test {
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    AttestedBTCOracle oracle;
    MockUSDC usdc;

    address deployer = address(this);
    address agent = address(0xA9E1);
    bytes32 feedId;

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        registry = new Registry(IERC20(address(usdc)));
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, IERC20(address(usdc)));
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        // Mint + approve for the agent.
        usdc.mint(agent, 1_000e6);
        vm.prank(agent);
        usdc.approve(address(registry), type(uint256).max);

        // Create a BTC/USD feed.
        bytes32 methodologyHash = keccak256("BTC/USD reference, internal cirque lending");
        vm.prank(agent);
        feedId = registry.createFeed(
            "BTC/USD reference rate (internal)",
            methodologyHash,
            10e6, // min bond
            1 hours, // min dispute window
            address(dispute) // resolver
        );

        // Agent registers (deposits bond).
        vm.prank(agent);
        registry.registerAgent(feedId, methodologyHash, 10e6);

        oracle = new AttestedBTCOracle(attestation, feedId, agent);
    }

    function _attest(int256 price) internal returns (bytes32) {
        vm.prank(agent);
        return attestation.attest(feedId, price, bytes32(uint256(0xdeadbeef)));
    }

    function test_returns_latest_attested_price() public {
        bytes32 id = _attest(76_800e18);
        (uint256 price, uint256 updatedAt) = oracle.getBTCPrice();
        assertEq(price, 76_800e18);
        assertEq(updatedAt, block.timestamp);

        // Different attestation, different timestamp.
        vm.warp(block.timestamp + 10 minutes);
        bytes32 id2 = _attest(77_100e18);
        (price, updatedAt) = oracle.getBTCPrice();
        assertEq(price, 77_100e18);
        assertEq(updatedAt, block.timestamp);

        assertNotEq(id, id2);
    }

    function test_reverts_when_no_attestations() public {
        vm.expectRevert(AttestedBTCOracle.NoValidAttestation.selector);
        oracle.getBTCPrice();
    }

    function test_multiple_attestations_picks_latest() public {
        _attest(76_800e18);
        vm.warp(block.timestamp + 10 minutes);
        _attest(77_500e18);
        vm.warp(block.timestamp + 5 minutes);
        _attest(77_300e18);

        // Walks back from index len-1: latest is 77_300.
        (uint256 price, uint256 updatedAt) = oracle.getBTCPrice();
        assertEq(price, 77_300e18);
        assertEq(updatedAt, block.timestamp);
    }

    function test_returns_only_positive_prices() public {
        // Attestation contract permits negative values for general feeds
        // (e.g., temperature). BTC price should never be negative; the
        // adapter rejects it.
        _attest(-1);
        vm.expectRevert(AttestedBTCOracle.NegativePrice.selector);
        oracle.getBTCPrice();
    }
}
