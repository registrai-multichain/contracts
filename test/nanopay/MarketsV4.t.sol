// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";

/// MarketsV4 lifecycle on NanoLedger: create/buy/sell settle as internal
/// accounting, fees accrue with one write and are claimed from the ledger,
/// oracle resolution + redeem + LP claim pay into ledger balances. Ledger
/// solvency holds throughout.
contract MarketsV4Test is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsV4 markets;

    address oracle = address(0x0AC1E);   // bonded agent + feed creator
    address resolver = address(0xBEEF);
    address treasury = address(0x7AEA);
    address creator = address(0xC0FFEE);
    address taker = address(0x7A4E);

    bytes32 feedId;
    uint256 constant DW = 1 hours;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        ledger = new NanoLedger(usdc, address(this));
        markets = new MarketsV4(ledger, registry, attestation, treasury);
        ledger.setSource(address(markets), true);

        // bonded agent + feed (creator == agent in v2)
        usdc.mint(oracle, 1_000e6);
        vm.startPrank(oracle);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("BTC/USD", keccak256("m"), 10e6, DW, resolver);
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
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger insolvent");
    }

    function _market() internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(feedId, oracle, int256(100_000), MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 1_000e6);
    }

    // ───────────── create ─────────────

    function test_createMarket_pullsLiquidityFromLedger() public {
        uint256 creatorBefore = ledger.balanceOf(creator);
        bytes32 id = _market();
        assertEq(ledger.balanceOf(creator), creatorBefore - 1_000e6, "seed pulled from ledger balance");
        assertEq(ledger.balanceOf(address(markets)), 1_000e6, "market holds collateral as ledger balance");
        MarketsV4.Market memory m = markets.getMarket(id);
        assertEq(m.yesReserve, 1_000e6);
        assertEq(m.noReserve, 1_000e6);
        assertEq(markets.lpShares(id, creator), 1_000e6);
        _solvent();
    }

    function test_createMarket_agentNotActiveReverts() public {
        vm.prank(creator);
        vm.expectRevert(MarketsV4.AgentNotRegistered.selector);
        markets.createMarket(bytes32("nope"), oracle, 0, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 1 hours, 1_000e6);
    }

    // ───────────── buy: fee = one accrual write ─────────────

    function test_buy_settlesOnLedger_andAccruesFeeOnce() public {
        bytes32 id = _market();
        uint256 takerBefore = ledger.balanceOf(taker);

        vm.prank(taker);
        uint256 shares = markets.buy(id, MarketsV4.Outcome.Yes, 1_000e6, 0);
        assertGt(shares, 0);
        assertEq(ledger.balanceOf(taker), takerBefore - 1_000e6, "collateral debited from ledger balance");

        // fee = 1000 * 70bps = 7 USDC, split 40/20/10 -> creator 4, agent 2, treasury 1
        assertEq(markets.LEDGER().claimablePool(id, creator), 4e6, "creator fee accrued");
        assertEq(markets.LEDGER().claimablePool(id, oracle), 2e6, "agent fee accrued");
        assertEq(markets.LEDGER().claimablePool(id, treasury), 1e6, "treasury fee accrued");
        _solvent();
    }

    function test_buy_slippageReverts() public {
        bytes32 id = _market();
        vm.prank(taker);
        vm.expectRevert(MarketsV4.SlippageExceeded.selector);
        markets.buy(id, MarketsV4.Outcome.Yes, 1_000e6, type(uint256).max);
    }

    function test_feeClaim_fromLedger() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsV4.Outcome.Yes, 1_000e6, 0);

        uint256 creatorBefore = ledger.balanceOf(creator);
        vm.prank(creator);
        uint256 owed = ledger.claim(id);
        assertEq(owed, 4e6);
        assertEq(ledger.balanceOf(creator), creatorBefore + 4e6, "fee claimed to ledger balance");
        assertEq(ledger.claimablePool(id, creator), 0, "checkpoint advanced");
        _solvent();
    }

    // ───────────── sell ─────────────

    function test_sell_paysToLedgerBalance() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, MarketsV4.Outcome.Yes, 1_000e6, 0);

        uint256 takerBefore = ledger.balanceOf(taker);
        vm.prank(taker);
        uint256 out = markets.sell(id, MarketsV4.Outcome.Yes, shares, 0);
        assertGt(out, 0);
        assertEq(ledger.balanceOf(taker), takerBefore + out, "proceeds credited to ledger balance");
        _solvent();
    }

    // ───────────── resolve / redeem / LP ─────────────

    function test_resolve_redeem_claimLP_endToEnd() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, MarketsV4.Outcome.Yes, 2_000e6, 0);

        // oracle attests a value that makes YES win (>= 100_000)
        vm.prank(oracle);
        attestation.attest(feedId, int256(123_456), bytes32("ih"));

        // past expiry + dispute window
        vm.warp(block.timestamp + 2 hours + DW + 1);
        markets.resolve(id);
        assertTrue(markets.getMarket(id).phase == MarketsV4.Phase.Resolved);
        assertTrue(markets.getMarket(id).yesWon);

        // winner redeems to ledger balance
        uint256 takerBefore = ledger.balanceOf(taker);
        vm.prank(taker);
        uint256 payout = markets.redeem(id);
        assertEq(payout, shares, "winning shares redeem 1:1");
        assertEq(ledger.balanceOf(taker), takerBefore + payout);

        // creator claims LP pot
        vm.prank(creator);
        uint256 lp = markets.claimLP(id);
        assertGt(lp, 0);
        _solvent();
    }

    function test_redeem_beforeResolveReverts() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsV4.Outcome.Yes, 1_000e6, 0);
        vm.prank(taker);
        vm.expectRevert(MarketsV4.NotResolved.selector);
        markets.redeem(id);
    }

    // ───────────── solvency invariant after a trade storm ─────────────

    function test_solvency_afterMixedActivity() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsV4.Outcome.Yes, 3_000e6, 0);
        vm.prank(creator);
        markets.buy(id, MarketsV4.Outcome.No, 1_500e6, 0);
        vm.prank(creator);
        ledger.claim(id); // claim creator + (creator!=others) fees
        vm.prank(treasury);
        // treasury has no ledger deposit but can still claim fees into a balance
        ledger.claim(id);
        _solvent();
    }
}
