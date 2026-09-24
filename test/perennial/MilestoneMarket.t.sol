// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// Milestone market: "did the builder ship a release?" resolves from a bonded
/// 1/0 attestation, and the treasury fee leg funds the commons (ProgressPool).
contract MilestoneMarketTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    ProgressPool pool;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    address builder = address(0xB111);

    address agent = address(0x0AC1E); // the caretaker, as bonded agent
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address taker = address(0x7A4E);
    bytes32 feedId;
    uint256 constant DW = 1 hours;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        builders.registerFor(builder, "github.com/example/builder");
        pool = new ProgressPool(ledger, builders, caretakers, address(this), 1 days, 1 hours, address(0x7EA5));
        markets = new MarketsPerennial(ledger, registry, attestation, builders, address(this), address(pool), 1 hours, 1 days);
        markets.setApprovedAgent(agent, true);
        markets.setApprovedResolver(resolver, true);

        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("ships-release", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 10e6);
        vm.stopPrank();

        _fund(creator);
        _fund(taker);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _milestoneMarket() internal returns (bytes32 id) {
        vm.prank(creator);
        // threshold 1, GreaterOrEqual -> YES iff attested value >= 1 (a release shipped)
        id = markets.createMarket(
            1, feedId, agent, int256(1), MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 10e6
        );
    }

    function test_shipped_resolvesYes_andFundsCommons() public {
        bytes32 id = _milestoneMarket();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0); // fee 7e6; treasury leg 35e5
        assertEq(ledger.balanceOf(address(pool)), 35e5, "commons funded by milestone-market fee");

        vm.warp(block.timestamp + 2 hours + 1); // trading closed; now the agent reads
        vm.prank(agent);
        attestation.attest(feedId, int256(1), bytes32("release:v1.2.0")); // shipped
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertTrue(markets.getMarket(id).yesWon, "shipped -> YES wins");
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "solvent");
    }

    function test_notShipped_resolvesNo() public {
        bytes32 id = _milestoneMarket();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.No, 1_000e6, 0);

        vm.warp(block.timestamp + 2 hours + 1); // trading closed; now the agent reads
        vm.prank(agent);
        attestation.attest(feedId, int256(0), bytes32("release:none")); // nothing shipped
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertFalse(markets.getMarket(id).yesWon, "not shipped -> NO wins");
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "solvent");
    }
}
