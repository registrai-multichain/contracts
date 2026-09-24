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

    event FeesPaid(bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 agentFee);

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
        markets.setApprovedAgent(oracle, true);
        markets.setApprovedResolver(resolver, true);

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

    function _settleYes(bytes32 id) internal {
        vm.warp(markets.getMarket(id).expiry + 1); // trading closed; now the agent reads
        vm.prank(oracle);
        attestation.attest(feedId, int256(123_456), bytes32("ih"));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
    }

    /// 1% of every buy: creator 30% and commons 50% paid now, the agent's 20%
    /// escrowed until the market settles.
    function test_buy_tradeFeeSplit_30_20_50_agentEscrowed() public {
        bytes32 id = _market();
        uint256 creatorBefore = ledger.balanceOf(creator);
        uint256 oracleBefore = ledger.balanceOf(oracle);

        vm.expectEmit(true, false, false, true, address(markets));
        emit FeesPaid(id, 3e6, 5e6, 2e6);
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0); // fee 10

        assertEq(ledger.balanceOf(creator) - creatorBefore, 3e6, "creator 30% now");
        assertEq(ledger.balanceOf(commons), 5e6, "commons 50% now");
        assertEq(ledger.balanceOf(oracle), oracleBefore, "agent not paid at trade time");
        assertEq(markets.agentEscrow(id), 2e6, "agent 20% escrowed");
        assertEq(markets.collateralOf(id), 1_000e6, "C = seed + collateralIn - fee");
        assertEq(markets.netCost(id, taker), 990e6, "net cost is after the fee");
        assertEq(ledger.balanceOf(address(markets)), 1_002e6, "C + escrow");
        _solvent();

        _settleYes(id);
        assertEq(ledger.balanceOf(oracle) - oracleBefore, 2e6, "escrow released on settlement");
        assertEq(markets.agentEscrow(id), 0);
        assertEq(ledger.balanceOf(commons), 5e6, "nothing charged at settlement");
        _solvent();
    }

    function test_commons_neverFundsTheBuilderItIsAbout() public {
        // the market is about builderId 1; its fees go to commons, not to a
        // per-builder account. The commons address accrues; nothing builder-tagged does.
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.No, 2_000e6, 0); // fee 20, commons 10
        assertEq(ledger.balanceOf(commons), 10e6);
        assertEq(ledger.balanceOf(builder), 0);
        _solvent();
    }

    function test_sell_paysFeesAndProceeds() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0);
        uint256 commonsBefore = ledger.balanceOf(commons);
        uint256 takerBefore = ledger.balanceOf(taker);
        uint256 cBefore = markets.collateralOf(id);
        vm.prank(taker);
        uint256 out = markets.sell(id, MarketsPerennial.Outcome.Yes, shares, 0);
        uint256 gross = cBefore - markets.collateralOf(id);
        uint256 fee = gross / 100;
        assertEq(out, gross - fee, "seller receives gross minus 1%");
        assertEq(ledger.balanceOf(taker) - takerBefore, out);
        uint256 cFee = (fee * 3000) / 10_000;
        uint256 aFee = (fee * 2000) / 10_000;
        assertEq(ledger.balanceOf(commons) - commonsBefore, fee - cFee - aFee, "commons grew from the sell fee");
        assertEq(markets.agentEscrow(id), 2e6 + aFee);
        assertEq(ledger.balanceOf(address(markets)), markets.collateralOf(id) + markets.agentEscrow(id));
        _solvent();
    }

    function test_resolve_redeem_endToEnd() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0);
        _settleYes(id);
        assertTrue(markets.getMarket(id).yesWon);
        assertEq(markets.redeemable(id, taker), shares);
        uint256 before = ledger.balanceOf(taker);
        vm.prank(taker);
        uint256 payout = markets.redeem(id);
        assertEq(payout, shares, "winning shares redeem 1:1");
        assertEq(ledger.balanceOf(taker) - before, payout);
        assertEq(markets.redeemable(id, taker), 0);
        uint256 lpView = markets.claimableLP(id, creator);
        assertEq(lpView, markets.getMarket(id).yesReserve, "LP pot = winning reserve");
        vm.prank(creator);
        assertEq(markets.claimLP(id), lpView);
        assertEq(ledger.balanceOf(address(markets)), 0, "every unit paid out");
        _solvent();
    }

    /// "Visible, fixed": the fee is a constant, with no governance knob.
    function test_feeIsFixedInCode() public view {
        assertEq(markets.TRADE_FEE_BPS(), 100);
        assertEq(markets.CREATOR_SHARE_BPS(), 3000);
        assertEq(markets.AGENT_SHARE_BPS(), 2000);
        assertEq(markets.COMMONS_SHARE_BPS(), 5000);
        assertEq(markets.BPS(), 10_000);
        assertEq(
            markets.CREATOR_SHARE_BPS() + markets.AGENT_SHARE_BPS() + markets.COMMONS_SHARE_BPS(), markets.BPS()
        );
    }

    /// The commons is immutable: the old setters are gone.
    function test_commonsIsImmutable_noFeeOrCommonsSetters() public {
        assertEq(markets.commons(), commons);
        (bool ok,) = address(markets).call(abi.encodeWithSignature("setCommons(address)", address(0xABCD)));
        assertFalse(ok, "setCommons removed");
        (ok,) = address(markets).call(abi.encodeWithSignature("setFeeSplit(uint256,uint256,uint256)", 10, 40, 20));
        assertFalse(ok, "setFeeSplit removed");
        (ok,) = address(markets).call(abi.encodeWithSignature("setForfeitSink(address)", address(0xABCD)));
        assertFalse(ok, "setForfeitSink removed");
        assertEq(markets.commons(), commons);
    }
}
