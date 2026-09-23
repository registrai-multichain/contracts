// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";

contract MarketsPerennialTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    BuilderRegistry builders;
    address builder = address(0xB111);

    address oracle = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address commons; // set in setUp
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
        builders.registerFor(builder, "github.com/example/builder");
        commons = address(0xC0117);
        markets = new MarketsPerennial(ledger, registry, attestation, builders, address(this), commons, 1 hours, 1 days);

        usdc.mint(oracle, 1_000e6);
        vm.startPrank(oracle);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("BTC", keccak256("m"), 10e6, DW, resolver);
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

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
    }

    function _market() internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(
            1,
            feedId,
            oracle,
            int256(100_000),
            MarketsPerennial.Comparator.GreaterOrEqual,
            block.timestamp + 2 hours,
            10e6
        );
    }

    function test_createMarket_tagsBuilderAndPullsLiquidity() public {
        bytes32 id = _market();
        MarketsPerennial.Market memory m = markets.getMarket(id);
        assertEq(m.builderId, 1);
        assertEq(m.creator, creator);
        assertEq(m.yesReserve, 10e6);
        assertEq(ledger.balanceOf(address(markets)), 10e6);
        _solvent();
    }

    function test_createMarket_rejectsUnknownOrInactiveBuilder() public {
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.BuilderInactive.selector);
        markets.createMarket(
            999, feedId, oracle, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 10e6
        );

        builders.setActive(1, false);
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.BuilderInactive.selector);
        markets.createMarket(
            1, feedId, oracle, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 10e6
        );
    }

    function test_buy_feeSplit_20_35_15() public {
        bytes32 id = _market();
        uint256 creatorBefore = ledger.balanceOf(creator);
        uint256 oracleBefore = ledger.balanceOf(oracle);
        uint256 commonsBefore = ledger.balanceOf(commons);

        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0); // fee = 7 USDC

        // creator 20/70 -> 2, commons 35/70 -> 3.5, agent 15/70 -> 1.5
        assertEq(ledger.balanceOf(creator) - creatorBefore, 2e6, "creator leg 20bps");
        assertEq(ledger.balanceOf(commons) - commonsBefore, 35e5, "commons leg 35bps");
        // The agent leg is escrowed, not paid: it is earned by settling.
        assertEq(ledger.balanceOf(oracle), oracleBefore, "agent not paid at trade time");
        assertEq(markets.agentEscrow(id), 15e5, "agent leg 15bps escrowed");
        _solvent();

        vm.warp(block.timestamp + 2 hours + 1); // past expiry
        vm.prank(oracle);
        attestation.attest(feedId, int256(123_456), bytes32("ih"));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertEq(ledger.balanceOf(oracle) - oracleBefore, 15e5, "agent leg released on settlement");
        _solvent();
    }

    function test_commons_neverFundsTheBuilderItIsAbout() public {
        // the market is about builderId 1; its fees go to commons, not to a
        // per-builder account. The commons address accrues; nothing builder-tagged does.
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.No, 2_000e6, 0); // fee 14, commons 7
        assertEq(ledger.balanceOf(commons), 7e6);
        _solvent();
    }

    function test_sell_paysFeesAndProceeds() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0);
        uint256 commonsBefore = ledger.balanceOf(commons);
        uint256 takerBefore = ledger.balanceOf(taker);
        vm.prank(taker);
        uint256 out = markets.sell(id, MarketsPerennial.Outcome.Yes, shares, 0);
        assertGt(out, 0);
        assertEq(ledger.balanceOf(taker) - takerBefore, out);
        assertGt(ledger.balanceOf(commons), commonsBefore, "commons grew from sell fee");
        _solvent();
    }

    function test_resolve_redeem_endToEnd() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0);
        vm.warp(block.timestamp + 2 hours + 1); // trading closed; now the agent reads
        vm.prank(oracle);
        attestation.attest(feedId, int256(123_456), bytes32("ih"));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertTrue(markets.getMarket(id).yesWon);
        uint256 before = ledger.balanceOf(taker);
        vm.prank(taker);
        uint256 payout = markets.redeem(id);
        assertEq(payout, shares);
        assertEq(ledger.balanceOf(taker) - before, payout);
        vm.prank(creator);
        markets.claimLP(id);
        _solvent();
    }

    function test_setFeeSplit_governable() public {
        markets.setFeeSplit(10, 40, 20); // sum 70 ok
        assertEq(markets.treasuryBps(), 40);
        vm.expectRevert(MarketsPerennial.BadSplit.selector);
        markets.setFeeSplit(10, 10, 10); // sum 30
    }

    function test_setFeeSplit_onlyGovernor() public {
        vm.prank(creator);
        vm.expectRevert();
        markets.setFeeSplit(20, 35, 15);
    }

    function test_setCommons() public {
        markets.setCommons(address(0xABCD));
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0);
        assertEq(ledger.balanceOf(address(0xABCD)), 35e5, "new commons receives the leg");
        _solvent();
    }
}
