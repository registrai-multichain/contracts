// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {BinaryMarket} from "../../src/nanopay/BinaryMarket.sol";

/// MarketsV4 lifecycle on NanoLedger: create/buy/sell settle as internal
/// accounting with a 1% trading fee per trade (creator 30 and treasury 50 paid
/// now, the agent's 20 escrowed until settlement), oracle resolution + redeem +
/// LP claim pay into ledger balances. Ledger solvency holds throughout.
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
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        ledger = new NanoLedger(usdc, address(this));
        markets = new MarketsV4(ledger, registry, attestation, address(this), treasury, 1 hours, 1 days);
        markets.setApprovedResolver(resolver, true);
        // no ledger role: V4 creates no fee pools

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
        id = markets.createMarket(feedId, oracle, int256(100_000), BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 1_000e6);
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
        vm.expectRevert(BinaryMarket.AgentNotRegistered.selector);
        markets.createMarket(bytes32("nope"), oracle, 0, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + 1 hours, 1_000e6);
    }

    // ───────────── buy: 1% trading fee ─────────────

    function test_buy_settlesOnLedger_chargesTradeFee() public {
        bytes32 id = _market();
        uint256 takerBefore = ledger.balanceOf(taker);

        vm.prank(taker);
        uint256 shares = markets.buy(id, BinaryMarket.Outcome.Yes, 1_000e6, 0, type(uint256).max);
        assertGt(shares, 0);
        assertEq(ledger.balanceOf(taker), takerBefore - 1_000e6, "collateral debited from ledger balance");
        // fee 10: creator 3 and treasury 5 paid now, the agent's 2 escrowed
        assertEq(ledger.balanceOf(treasury), 5e6, "treasury 50% now");
        assertEq(ledger.balanceOf(oracle), 0, "agent not paid at trade time");
        assertEq(markets.agentEscrow(id), 2e6, "agent 20% escrowed");
        assertEq(markets.collateralOf(id), 1_990e6);
        assertEq(markets.netCost(id, taker), 990e6);
        assertEq(ledger.balanceOf(address(markets)), 1_992e6, "C + escrow");
        _solvent();
    }

    function test_buy_slippageReverts() public {
        bytes32 id = _market();
        vm.prank(taker);
        vm.expectRevert(BinaryMarket.SlippageExceeded.selector);
        markets.buy(id, BinaryMarket.Outcome.Yes, 1_000e6, type(uint256).max, type(uint256).max);
    }

    /// Creator and treasury are paid per trade, straight to ledger balances
    /// (nothing to claim); the agent's escrow is released at resolve.
    function test_fees_paidPerTrade_agentOnResolve() public {
        bytes32 id = _market();
        uint256 creatorBefore = ledger.balanceOf(creator);
        vm.prank(taker);
        markets.buy(id, BinaryMarket.Outcome.Yes, 1_000e6, 0, type(uint256).max); // fee 10
        assertEq(ledger.balanceOf(creator) - creatorBefore, 3e6, "creator 30% of 10");
        assertEq(ledger.balanceOf(treasury), 5e6, "treasury 50% of 10");
        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(oracle);
        attestation.attest(feedId, int256(123_456), bytes32("ih"));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertEq(ledger.balanceOf(oracle), 2e6, "agent 20% of 10, released on resolve");
        assertEq(ledger.balanceOf(treasury), 5e6, "nothing charged at settlement");
        _solvent();
    }

    // ───────────── sell ─────────────

    function test_sell_paysToLedgerBalance() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, BinaryMarket.Outcome.Yes, 1_000e6, 0, type(uint256).max);

        uint256 takerBefore = ledger.balanceOf(taker);
        vm.prank(taker);
        uint256 out = markets.sell(id, BinaryMarket.Outcome.Yes, shares, 0, type(uint256).max);
        assertGt(out, 0);
        assertEq(ledger.balanceOf(taker), takerBefore + out, "proceeds credited to ledger balance");
        assertEq(ledger.balanceOf(address(markets)), markets.collateralOf(id) + markets.agentEscrow(id));
        uint256 gross = 1_990e6 - markets.collateralOf(id); // the sell burned the gross amount
        assertApproxEqAbs(gross, 990e6, 2, "round trip at the curve: the buy's net comes back gross");
        assertEq(out, gross - gross / 100, "seller receives gross minus 1%");
        assertEq(markets.netCost(id, taker), 990e6 - (gross < 990e6 ? gross : 990e6));
        _solvent();
    }

    // ───────────── resolve / redeem / LP ─────────────

    function test_resolve_redeem_claimLP_endToEnd() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, BinaryMarket.Outcome.Yes, 2_000e6, 0, type(uint256).max);

        // trading closes at expiry; then the oracle attests a value that makes
        // YES win (>= 100_000), and the dispute window runs out
        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(oracle);
        attestation.attest(feedId, int256(123_456), bytes32("ih"));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertTrue(markets.getMarket(id).phase == BinaryMarket.Phase.Resolved);
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
        markets.buy(id, BinaryMarket.Outcome.Yes, 1_000e6, 0, type(uint256).max);
        vm.prank(taker);
        vm.expectRevert(BinaryMarket.NotResolved.selector);
        markets.redeem(id);
    }

    // ───────────── solvency invariant after a trade storm ─────────────

    function test_solvency_afterMixedActivity() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, BinaryMarket.Outcome.Yes, 3_000e6, 0, type(uint256).max);
        vm.prank(creator);
        markets.buy(id, BinaryMarket.Outcome.No, 1_500e6, 0, type(uint256).max);
        assertEq(ledger.balanceOf(address(markets)), markets.collateralOf(id) + markets.agentEscrow(id));
        assertEq(markets.collateralOf(id), 5_455e6, "1000 + 2970 + 1485");
        assertEq(markets.totalNetCost(id), 4_455e6);
        assertEq(markets.agentEscrow(id), 9e6, "20% of 30 + 15");
        _solvent();
    }
}
