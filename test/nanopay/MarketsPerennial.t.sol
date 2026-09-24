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
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {FundKit} from "../perennial/FundKit.sol";

contract MarketsPerennialTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    BuilderFund fund;
    SeasonPool pool;
    address builder = address(0xB111);
    address builder2 = address(0xB222);
    address challenger = address(0xC4A1);

    address oracle = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address taker = address(0x7A4E);
    bytes32 feedId;
    uint256 constant DW = 1 hours;

    uint256 constant EPOCH = 1 hours; // shorter than a market's life

    event FeesPaid(bytes32 indexed marketId, uint256 creatorFee, uint256 builderFee, uint256 agentFee);
    event VoidFeesPaid(
        bytes32 indexed marketId,
        uint256 creatorFee,
        uint256 seasonPoolAmount,
        uint256 challengerReward,
        address challenger
    );
    event IncomeCredited(uint256 indexed epoch, uint256 indexed builderId, uint256 amount);

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
        builders.registerFor(builder2, "github.com/example/other");
        caretakers = new CaretakerRegistry(builders, address(this));
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), EPOCH);
        markets = new MarketsPerennial(ledger, registry, attestation, builders, address(this), fund, 1 hours, 1 days);
        FundKit.wire(fund, address(markets));
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
        return _marketFor(1);
    }

    function _marketFor(uint256 builderId) internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(
            builderId,
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

    /// 1% of every buy: creator 30% paid now, the builder's 50% paid into the
    /// fund and credited to the market's builder now, the agent's 20% escrowed
    /// until the market settles.
    function test_buy_tradeFeeSplit_30_20_50_agentEscrowed() public {
        bytes32 id = _market();
        uint256 creatorBefore = ledger.balanceOf(creator);
        uint256 oracleBefore = ledger.balanceOf(oracle);

        vm.expectEmit(address(fund));
        emit IncomeCredited(0, 1, 5e6);
        vm.expectEmit(true, false, false, true, address(markets));
        emit FeesPaid(id, 3e6, 5e6, 2e6);
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0); // fee 10

        assertEq(ledger.balanceOf(creator) - creatorBefore, 3e6, "creator 30% now");
        assertEq(ledger.balanceOf(address(fund)), 5e6, "builder 50% now, held by the fund");
        assertEq(fund.incomeOf(0, 1), 5e6, "credited to the market's builder");
        assertEq(ledger.balanceOf(oracle), oracleBefore, "agent not paid at trade time");
        assertEq(markets.agentEscrow(id), 2e6, "agent 20% escrowed");
        assertEq(markets.collateralOf(id), 1_000e6, "C = seed + collateralIn - fee");
        assertEq(markets.netCost(id, taker), 990e6, "net cost is after the fee");
        assertEq(ledger.balanceOf(address(markets)), 1_002e6, "C + escrow");
        _solvent();

        _settleYes(id);
        assertEq(ledger.balanceOf(oracle) - oracleBefore, 2e6, "escrow released on settlement");
        assertEq(markets.agentEscrow(id), 0);
        assertEq(ledger.balanceOf(address(fund)), 5e6, "nothing charged at settlement");
        _solvent();
    }

    /// The builder leg is income of the builder THE MARKET IS ABOUT, in the
    /// epoch of the trade, and reaches the builder when it claims the epoch.
    function test_builderLeg_creditedToTheRightBuilderAndEpoch() public {
        bytes32 m1 = _marketFor(1);
        bytes32 m2 = _marketFor(2);
        vm.prank(taker);
        markets.buy(m1, MarketsPerennial.Outcome.No, 2_000e6, 0); // fee 20, builder 1 gets 10
        vm.prank(taker);
        markets.buy(m2, MarketsPerennial.Outcome.Yes, 1_000e6, 0); // fee 10, builder 2 gets 5
        assertEq(fund.incomeOf(0, 1), 10e6);
        assertEq(fund.incomeOf(0, 2), 5e6);
        assertEq(ledger.balanceOf(builder), 0, "nothing paid before the epoch ends");

        vm.warp(fund.epochEnd(0)); // next epoch, the market still trades
        vm.prank(taker);
        markets.buy(m1, MarketsPerennial.Outcome.Yes, 400e6, 0); // fee 4, builder 1 gets 2
        assertEq(fund.incomeOf(1, 1), 2e6, "epoch 1 income");
        assertEq(fund.incomeOf(0, 1), 10e6, "epoch 0 unchanged");

        fund.claimFor(0, 1); // under $1,000: untaxed, 1% protocol fee
        assertEq(ledger.balanceOf(builder), 99e5);
        assertEq(ledger.balanceOf(address(0x7EA5)), 1e5);
        assertEq(ledger.balanceOf(address(fund)), 5e6 + 2e6, "the rest stays for later claims");
        _solvent();
    }

    /// Void with no successful challenger: the agent's escrow goes to the
    /// season pool (through the fund), not to the builder.
    function test_void_noChallenger_escrowToSeasonPool() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0); // escrow 2
        vm.warp(markets.getMarket(id).expiry + 1 hours + 1); // silent agent: window over
        vm.expectEmit(address(markets));
        emit VoidFeesPaid(id, 0, 2e6, 0, address(0));
        markets.voidMarket(id);
        assertEq(ledger.balanceOf(address(pool)), 2e6, "escrow in the season pool");
        assertEq(pool.unallocated(), 2e6, "and accounted there");
        assertEq(fund.outstanding(), 5e6, "builder income untouched");
        assertEq(ledger.balanceOf(address(fund)), 5e6);
        _solvent();
    }

    /// Void with a successful challenger: the challenger still gets the escrow.
    function test_void_withChallenger_paysTheChallenger() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0); // escrow 2
        vm.warp(markets.getMarket(id).expiry + 1);
        vm.prank(oracle);
        bytes32 att = attestation.attest(feedId, int256(123_456), bytes32("ih"));
        usdc.mint(challenger, 1_000e6);
        vm.startPrank(challenger);
        usdc.approve(address(dispute), type(uint256).max);
        bytes32 did = dispute.challenge(att, keccak256("contested"));
        vm.stopPrank();
        vm.prank(resolver);
        dispute.resolve(did, Dispute.DisputeOutcome.AttestationInvalid); // the reading was wrong
        vm.warp(markets.getMarket(id).expiry + 1 hours + 1);
        uint256 before = ledger.balanceOf(challenger);
        vm.expectEmit(address(markets));
        emit VoidFeesPaid(id, 0, 0, 2e6, challenger);
        markets.voidMarket(id);
        assertEq(ledger.balanceOf(challenger) - before, 2e6, "challenger earns the escrow");
        assertEq(ledger.balanceOf(address(pool)), 0, "season pool gets nothing");
        _solvent();
    }

    function test_constructor_refusesAForeignFund() public {
        BuilderRegistry otherBuilders = new BuilderRegistry(address(this));
        CaretakerRegistry otherCare = new CaretakerRegistry(otherBuilders, address(this));
        (, BuilderFund foreign) = FundKit.deploy(ledger, otherBuilders, otherCare, address(0x7EA5), EPOCH);
        vm.expectRevert(MarketsPerennial.FundMismatch.selector);
        new MarketsPerennial(ledger, registry, attestation, builders, address(this), foreign, 1 hours, 1 days);
        NanoLedger otherLedger = new NanoLedger(usdc, address(this));
        (, BuilderFund foreign2) = FundKit.deploy(otherLedger, builders, caretakers, address(0x7EA5), EPOCH);
        vm.expectRevert(MarketsPerennial.FundMismatch.selector);
        new MarketsPerennial(ledger, registry, attestation, builders, address(this), foreign2, 1 hours, 1 days);
    }

    /// Without MARKETS_ROLE on the fund a market cannot take a trade (the
    /// credit reverts), so a mis-wired deploy fails loudly, not silently.
    function test_trade_requiresMarketsRoleOnTheFund() public {
        bytes32 id = _market();
        fund.revokeRole(fund.MARKETS_ROLE(), address(markets));
        vm.prank(taker);
        vm.expectRevert();
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0);
    }

    function test_sell_paysFeesAndProceeds() public {
        bytes32 id = _market();
        vm.prank(taker);
        uint256 shares = markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0);
        uint256 fundBefore = ledger.balanceOf(address(fund));
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
        assertEq(ledger.balanceOf(address(fund)) - fundBefore, fee - cFee - aFee, "builder leg of the sell fee");
        assertEq(fund.incomeOf(0, 1), 5e6 + fee - cFee - aFee, "credited to the builder");
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
        assertEq(markets.BUILDER_SHARE_BPS(), 5000);
        assertEq(markets.BPS(), 10_000);
        assertEq(
            markets.CREATOR_SHARE_BPS() + markets.AGENT_SHARE_BPS() + markets.BUILDER_SHARE_BPS(), markets.BPS()
        );
    }

    /// The fund is immutable: the old setters are gone.
    function test_fundIsImmutable_noFeeOrCommonsSetters() public {
        assertEq(address(markets.FUND()), address(fund));
        (bool has,) = address(markets).call(abi.encodeWithSignature("commons()"));
        assertFalse(has, "commons() removed");
        (bool ok,) = address(markets).call(abi.encodeWithSignature("setCommons(address)", address(0xABCD)));
        assertFalse(ok, "setCommons removed");
        (ok,) = address(markets).call(abi.encodeWithSignature("setFeeSplit(uint256,uint256,uint256)", 10, 40, 20));
        assertFalse(ok, "setFeeSplit removed");
        (ok,) = address(markets).call(abi.encodeWithSignature("setForfeitSink(address)", address(0xABCD)));
        assertFalse(ok, "setForfeitSink removed");
        assertEq(address(markets.FUND()), address(fund));
    }
}
