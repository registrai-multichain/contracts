// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {SettlementPolicy} from "../../src/nanopay/SettlementPolicy.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// @notice Fee & settlement model v3 (owner decision 2026-09-24), on both market
/// kinds:
///   - 1% trading fee on every buy (of collateralIn) and sell (of the gross curve
///     amount), split creator 30 / commons (Perennial) or treasury (V4) 50 paid
///     per trade, agent 20 escrowed per market; nothing charged at settlement;
///   - resolve: escrow to the agent, winners 1 per share, LP the winning reserve;
///   - void: traders get their net cost (after fees) back (pro rata only when
///     early sellers took more profit than the LP seed), the escrow goes to a
///     successful challenger, else to the commons / treasury;
///   - V4 agents are permissionless;
///   - ProgressPool takes 1% of each builder payout for the protocol treasury.
contract FeeModelTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    ProgressPool pool;
    MarketsPerennial perennial;
    MarketsV4 v4;

    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address protocolTreasury = address(0x7EA5);
    address challenger = address(0xC4A1);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address dave = address(0xDA5E);
    address builder = address(0xB111);
    uint256 constant BUILDER_ID = 1; // `builder`'s id
    bytes32 feedId;

    uint256 constant DW = 1 hours;
    uint256 constant WINDOW = 1 hours;
    uint256 constant GRACE = 1 days;
    uint256 constant LIFE = 10 hours;

    event Bought(
        bytes32 indexed marketId,
        address indexed buyer,
        MarketsPerennial.Outcome outcome,
        uint256 collateralIn,
        uint256 sharesOut,
        uint256 fee
    );
    event Sold(
        bytes32 indexed marketId,
        address indexed seller,
        MarketsPerennial.Outcome outcome,
        uint256 sharesIn,
        uint256 collateralOut,
        uint256 fee
    );
    event FeesPaid(bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 agentFee);
    event VoidFeesPaid(
        bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 challengerReward, address challenger
    );
    event ProtocolFeePaid(uint256 indexed epoch, uint256 indexed builderId, uint256 fee);
    event AgentFeeReleased(bytes32 indexed marketId, address indexed agent, uint256 amount);

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
        builders.registerFor(builder, "b1");
        pool = new ProgressPool(ledger, builders, caretakers, address(this), 1 days, 1 hours, protocolTreasury);
        perennial = new MarketsPerennial(ledger, registry, attestation, builders, address(this), address(pool), WINDOW, GRACE);
        v4 = new MarketsV4(ledger, registry, attestation, address(this), treasury, WINDOW, GRACE);
        perennial.setApprovedAgent(agent, true);
        perennial.setApprovedResolver(resolver, true);
        v4.setApprovedResolver(resolver, true);

        usdc.mint(agent, 10_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("f", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 1_000e6);
        vm.stopPrank();

        _fund(creator);
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(dave);
        usdc.mint(challenger, 10_000e6);
        vm.prank(challenger);
        usdc.approve(address(dispute), type(uint256).max);
    }

    function _fund(address a) internal {
        usdc.mint(a, 10_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(5_000_000e6);
        ledger.approveSpender(address(perennial), type(uint256).max);
        ledger.approveSpender(address(v4), type(uint256).max);
        vm.stopPrank();
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger insolvent");
    }

    function _p(uint256 liq) internal returns (bytes32 id) {
        vm.prank(creator);
        id = perennial.createMarket(
            1, feedId, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + LIFE, liq
        );
    }

    function _v(uint256 liq) internal returns (bytes32 id) {
        vm.prank(creator);
        id = v4.createMarket(feedId, agent, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + LIFE, liq);
    }

    function _attestAndFinalize(uint256 expiry, int256 value) internal {
        vm.warp(expiry + 1);
        vm.prank(agent);
        attestation.attest(feedId, value, keccak256(abi.encode(value, block.timestamp)));
        vm.warp(vm.getBlockTimestamp() + DW);
    }

    // ───────────────────────── 1% trading fee ─────────────────────────

    function test_perennial_buySell_exactFeeLegs_perTrade() public {
        bytes32 id = _p(100e6);
        uint256 a0 = ledger.balanceOf(alice);
        uint256 cr0 = ledger.balanceOf(creator);

        vm.expectEmit(true, false, false, true, address(perennial));
        emit FeesPaid(id, 15e4, 25e4, 1e5); // fee 0.5: 30 / 50 / 20
        vm.recordLogs();
        vm.prank(alice);
        uint256 shares = perennial.buy(id, MarketsPerennial.Outcome.Yes, 50e6, 0);
        assertEq(_lastFee(), 5e5, "Bought.fee == 1% of collateralIn");
        // 49.5 after the fee mints a full set: alice gets 149.5 - ceil(100 * 100 / 149.5)
        assertEq(shares, 1495e5 - (uint256(100e6) * 100e6 + 1495e5 - 1) / 1495e5);
        assertEq(a0 - ledger.balanceOf(alice), 50e6, "exactly collateralIn debited");
        assertEq(ledger.balanceOf(creator) - cr0, 15e4, "creator 30% now");
        assertEq(ledger.balanceOf(address(pool)), 25e4, "commons 50% now");
        assertEq(perennial.agentEscrow(id), 1e5, "agent 20% held");
        assertEq(perennial.collateralOf(id), 1495e5);
        assertEq(perennial.netCost(id, alice), 495e5, "net cost is after the fee");
        assertEq(perennial.totalNetCost(id), 495e5);

        vm.recordLogs();
        vm.prank(alice);
        uint256 out = perennial.sell(id, MarketsPerennial.Outcome.Yes, shares, 0);
        uint256 gross = 1495e5 - perennial.collateralOf(id);
        uint256 fee = gross / 100;
        assertEq(_lastFee(), fee, "Sold.fee == 1% of the gross curve amount");
        assertEq(out, gross - fee, "seller receives gross minus the fee");
        assertApproxEqAbs(gross, 495e5, 2, "the curve gives back what the buy put in");
        assertEq(ledger.balanceOf(alice), a0 - 50e6 + out, "exactly collateralOut credited");
        assertEq(perennial.netCost(id, alice), 495e5 - gross);
        assertEq(perennial.agentEscrow(id), 1e5 + (fee * 2000) / 10_000);
        assertEq(ledger.balanceOf(address(perennial)), perennial.collateralOf(id) + perennial.agentEscrow(id));
        assertEq(ledger.balanceOf(agent), 0, "the agent is paid nothing while trading");
    }

    function test_v4_buySell_exactFeeLegs_perTrade() public {
        bytes32 id = _v(100e6);
        uint256 a0 = ledger.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(v4));
        emit FeesPaid(id, 15e4, 25e4, 1e5);
        vm.recordLogs();
        vm.prank(alice);
        uint256 shares = v4.buy(id, MarketsV4.Outcome.No, 50e6, 0);
        assertEq(_lastFee(), 5e5);
        assertEq(shares, 1495e5 - (uint256(100e6) * 100e6 + 1495e5 - 1) / 1495e5);
        assertEq(ledger.balanceOf(treasury), 25e4, "treasury 50% now");
        assertEq(v4.agentEscrow(id), 1e5);
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = v4.sell(id, MarketsV4.Outcome.No, shares, 0);
        uint256 gross = 1495e5 - v4.collateralOf(id);
        assertEq(_lastFee(), gross / 100);
        assertEq(out, gross - gross / 100);
        assertEq(ledger.balanceOf(alice), a0 - 50e6 + out);
        assertEq(ledger.balanceOf(address(v4)), v4.collateralOf(id) + v4.agentEscrow(id));
    }

    /// The last Bought/Sold log's `fee` (the last word of its data).
    function _lastFee() internal view returns (uint256 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.topics[0] == Bought.selector || l.topics[0] == Sold.selector) {
                (,,, fee) = abi.decode(l.data, (uint8, uint256, uint256, uint256));
                return fee;
            }
        }
        revert("no trade log");
    }

    /// The legs of every trade's fee sum to exactly the fee: nothing stranded.
    function testFuzz_feeLegsSumToFee(uint256 buyIn, uint256 sellFrac) public {
        buyIn = bound(buyIn, 1, 1_000_000e6);
        bytes32 id = _p(5e6);
        uint256 cr0 = ledger.balanceOf(creator);
        vm.prank(alice);
        uint256 shares = perennial.buy(id, MarketsPerennial.Outcome.Yes, buyIn, 0);
        uint256 fee = buyIn / 100;
        uint256 legs = (ledger.balanceOf(creator) - cr0) + ledger.balanceOf(address(pool)) + perennial.agentEscrow(id);
        assertEq(legs, fee, "buy legs == fee");
        assertEq(perennial.collateralOf(id), 5e6 + buyIn - fee);

        uint256 sellShares = bound(sellFrac, 1, shares);
        uint256 c0 = perennial.collateralOf(id);
        vm.prank(alice);
        try perennial.sell(id, MarketsPerennial.Outcome.Yes, sellShares, 0) returns (uint256 out) {
            uint256 gross = c0 - perennial.collateralOf(id);
            uint256 legs2 = (ledger.balanceOf(creator) - cr0) + ledger.balanceOf(address(pool))
                + perennial.agentEscrow(id);
            assertEq(legs2 - legs, gross / 100, "sell legs == fee");
            assertEq(out, gross - gross / 100);
        } catch {}
        assertEq(ledger.balanceOf(address(perennial)), perennial.collateralOf(id) + perennial.agentEscrow(id));
    }

    // ───────────────────────── resolve: nothing charged ─────────────────────────

    function test_perennial_resolve_releasesEscrow_winnersOneToOne_lpGetsReserve() public {
        bytes32 id = _p(100e6);
        vm.prank(alice);
        uint256 aYes = perennial.buy(id, MarketsPerennial.Outcome.Yes, 600e6, 0); // fee 6
        vm.prank(bob);
        perennial.buy(id, MarketsPerennial.Outcome.No, 300e6, 0); // fee 3
        assertEq(perennial.collateralOf(id), 991e6, "100 + 594 + 297");
        assertEq(perennial.agentEscrow(id), 18e5, "20% of 9");
        assertEq(ledger.balanceOf(address(pool)), 45e5, "50% of 9, paid per trade");
        MarketsPerennial.Market memory m = perennial.getMarket(id);

        uint256 c0 = ledger.balanceOf(creator);
        _attestAndFinalize(m.expiry, 1); // YES
        vm.expectEmit(true, true, false, true, address(perennial));
        emit AgentFeeReleased(id, agent, 18e5);
        perennial.resolve(id);
        assertEq(ledger.balanceOf(agent), 18e5, "the escrow goes to the agent");
        assertEq(ledger.balanceOf(creator), c0, "nothing charged at settlement");
        assertEq(ledger.balanceOf(address(pool)), 45e5, "nothing charged at settlement");
        assertEq(ledger.balanceOf(address(perennial)), 991e6);

        assertEq(perennial.redeemable(id, alice), aYes);
        assertEq(perennial.redeemable(id, bob), 0, "loser");
        vm.prank(alice);
        assertEq(perennial.redeem(id), aYes, "1 per winning share");
        vm.prank(bob);
        vm.expectRevert(MarketsPerennial.InsufficientShares.selector);
        perennial.redeem(id);

        assertEq(perennial.lpPotAtResolution(id), m.yesReserve, "LP pot = winning reserve");
        assertEq(perennial.claimableLP(id, creator), m.yesReserve);
        vm.prank(creator);
        assertEq(perennial.claimLP(id), m.yesReserve);
        assertEq(ledger.balanceOf(address(perennial)), 0, "exactly solvent: winning supply == C");
        _solvent();
    }

    function test_v4_resolve_releasesEscrow_treasuryPaidPerTrade() public {
        bytes32 id = _v(100e6);
        vm.prank(alice);
        uint256 aNo = v4.buy(id, MarketsV4.Outcome.No, 900e6, 0); // fee 9
        assertEq(ledger.balanceOf(treasury), 45e5, "the 50% leg is the treasury's, per trade");
        MarketsV4.Market memory m = v4.getMarket(id);
        _attestAndFinalize(m.expiry, 0); // NO wins (0 < 1)
        vm.expectEmit(true, true, false, true, address(v4));
        emit AgentFeeReleased(id, agent, 18e5);
        v4.resolve(id);
        assertEq(ledger.balanceOf(agent), 18e5);
        assertEq(ledger.balanceOf(treasury), 45e5);
        vm.prank(alice);
        assertEq(v4.redeem(id), aNo);
        vm.prank(creator);
        assertEq(v4.claimLP(id), m.noReserve);
        assertEq(ledger.balanceOf(address(v4)), 0);
        _solvent();
    }

    // ───────────────────────── void: net cost back ─────────────────────────

    function test_perennial_void_refundsNetCost_afterPartialSell() public {
        bytes32 id = _p(100e6);
        vm.prank(alice);
        uint256 aYes = perennial.buy(id, MarketsPerennial.Outcome.Yes, 400e6, 0); // net 396
        vm.prank(bob);
        perennial.buy(id, MarketsPerennial.Outcome.No, 200e6, 0); // net 198
        uint256 c0 = perennial.collateralOf(id);
        vm.prank(alice);
        perennial.sell(id, MarketsPerennial.Outcome.Yes, aYes / 4, 0);
        uint256 gross = c0 - perennial.collateralOf(id);
        assertLt(gross, 396e6);
        uint256 aCost = 396e6 - gross;
        assertEq(perennial.netCost(id, alice), aCost, "net cost falls by the gross amount");
        uint256 c = perennial.collateralOf(id);
        assertEq(c, 694e6 - gross);
        uint256 escrow = perennial.agentEscrow(id);
        uint256 pool0 = ledger.balanceOf(address(pool));

        vm.warp(perennial.getMarket(id).expiry + WINDOW + 1);
        vm.expectEmit(true, false, false, true, address(perennial));
        emit VoidFeesPaid(id, 0, escrow, 0, address(0));
        perennial.voidMarket(id);
        assertEq(ledger.balanceOf(address(pool)) - pool0, escrow, "unclaimed escrow to the commons");
        assertEq(perennial.voidTraderPool(id), aCost + 198e6, "min(totalNetCost, C)");
        assertEq(perennial.voidNetCostTotal(id), aCost + 198e6);

        assertEq(perennial.redeemable(id, alice), aCost);
        vm.prank(alice);
        assertEq(perennial.redeem(id), aCost, "alice: her net cost, exactly");
        vm.prank(bob);
        assertEq(perennial.redeem(id), 198e6, "bob: 200 in, minus the 2 fee");
        vm.prank(creator);
        assertEq(perennial.claimLP(id), 100e6, "LP gets C minus the trader pool: its seed");
        assertEq(ledger.balanceOf(address(perennial)), 0);
        _solvent();
    }

    /// The rare case: an early seller's profit exceeds the LP seed, so the market
    /// holds less than the traders' net costs. They share what there is pro rata;
    /// the LP gets nothing; nobody is paid more than the market holds.
    function test_perennial_void_proRata_whenEarlySellerProfitExceedsLpSeed() public {
        bytes32 id = _p(5e6); // minimum seed
        vm.prank(bob);
        perennial.buy(id, MarketsPerennial.Outcome.No, 1_000e6, 0); // YES becomes cheap; net 990
        vm.prank(alice);
        uint256 aYes = perennial.buy(id, MarketsPerennial.Outcome.Yes, 10e6, 0); // net 9.9
        vm.prank(carol);
        perennial.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // YES becomes dear; net 1980
        vm.prank(alice);
        uint256 out = perennial.sell(id, MarketsPerennial.Outcome.Yes, aYes, 0);
        assertGt(out - 10e6, 5e6, "alice's profit exceeds the LP seed");
        assertEq(perennial.netCost(id, alice), 0, "a profit is not a negative cost");

        uint256 c = perennial.collateralOf(id);
        uint256 tnc = perennial.totalNetCost(id);
        assertEq(tnc, 2_970e6);
        assertGt(tnc, c, "the traders put in more than the market still holds");

        vm.warp(perennial.getMarket(id).expiry + WINDOW + 1);
        perennial.voidMarket(id);
        assertEq(perennial.voidTraderPool(id), c, "capped at what the market holds");
        uint256 bPay = (990e6 * c) / 2_970e6;
        uint256 cPay = (1_980e6 * c) / 2_970e6;
        assertLt(bPay, 990e6, "less than net cost: pro rata");
        vm.prank(bob);
        assertEq(perennial.redeem(id), bPay);
        vm.prank(carol);
        assertEq(perennial.redeem(id), cPay);
        assertEq(perennial.redeemable(id, alice), 0);
        vm.prank(alice);
        vm.expectRevert(MarketsPerennial.InsufficientShares.selector);
        perennial.redeem(id);
        assertEq(perennial.claimableLP(id, creator), 0);
        vm.prank(creator);
        assertEq(perennial.claimLP(id), 0, "the LP bore the loss");
        assertLe(ledger.balanceOf(address(perennial)), 2);
        _solvent();
    }

    function test_v4_void_refundsNetCost() public {
        bytes32 id = _v(100e6);
        vm.prank(alice);
        v4.buy(id, MarketsV4.Outcome.Yes, 500e6, 0);
        vm.prank(bob);
        v4.buy(id, MarketsV4.Outcome.No, 250e6, 0);
        vm.warp(v4.getMarket(id).expiry + WINDOW + 1);
        v4.voidMarket(id);
        vm.prank(alice);
        assertEq(v4.redeem(id), 495e6);
        vm.prank(bob);
        assertEq(v4.redeem(id), 2475e5);
        vm.prank(creator);
        assertEq(v4.claimLP(id), 100e6);
        assertEq(ledger.balanceOf(address(v4)), 0);
        assertEq(ledger.balanceOf(treasury), 375e4 + 15e5, "50% per trade + the unclaimed escrow");
    }

    // ───────────────────────── void: challenger reward ─────────────────────────

    /// Full Dispute flow: the agent attests inside the settlement window, a
    /// challenger disputes, the resolver rules Invalid, the window passes, the
    /// market voids — and the agent's escrow goes to that challenger.
    function test_perennial_void_paysTheSuccessfulChallenger() public {
        bytes32 id = _p(100e6);
        vm.prank(alice);
        perennial.buy(id, MarketsPerennial.Outcome.Yes, 900e6, 0); // fee 9, escrow 1.8
        uint256 expiry = perennial.getMarket(id).expiry;

        vm.warp(expiry + 5 minutes);
        vm.prank(agent);
        bytes32 att = attestation.attest(feedId, 1, keccak256("wrong"));
        vm.prank(challenger);
        bytes32 d = dispute.challenge(att, keccak256("evidence"));
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
        assertEq(dispute.invalidatedBy(att), challenger);

        vm.warp(expiry + WINDOW + 1);
        (SettlementPolicy.Settlement s,) = perennial.settlementState(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Voidable));
        uint256 c0 = ledger.balanceOf(creator);
        vm.expectEmit(true, false, false, true, address(perennial));
        emit VoidFeesPaid(id, 0, 0, 18e5, challenger);
        perennial.voidMarket(id);
        assertEq(ledger.balanceOf(challenger), 18e5, "challenger reward = the agent's escrow");
        assertEq(ledger.balanceOf(agent), 0, "the agent earns nothing");
        assertEq(ledger.balanceOf(address(pool)), 45e5, "commons keeps only its per-trade 50%");
        assertEq(ledger.balanceOf(creator), c0, "nothing charged at void");
        vm.prank(alice);
        assertEq(perennial.redeem(id), 891e6, "900 in, minus the 9 fee");
        _solvent();
    }

    function test_v4_void_paysTheSuccessfulChallenger() public {
        bytes32 id = _v(100e6);
        vm.prank(alice);
        v4.buy(id, MarketsV4.Outcome.Yes, 900e6, 0);
        uint256 expiry = v4.getMarket(id).expiry;
        vm.warp(expiry);
        vm.prank(agent);
        bytes32 att = attestation.attest(feedId, 1, keccak256("wrong"));
        vm.prank(challenger);
        bytes32 d = dispute.challenge(att, keccak256("evidence"));
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
        vm.warp(expiry + WINDOW + 1);
        vm.expectEmit(true, false, false, true, address(v4));
        emit VoidFeesPaid(id, 0, 0, 18e5, challenger);
        v4.voidMarket(id);
        assertEq(ledger.balanceOf(challenger), 18e5);
        assertEq(ledger.balanceOf(treasury), 45e5);
    }

    /// No successful challenger: the escrow goes to the commons / treasury.
    function test_void_noChallenger_escrowToCommonsAndTreasury() public {
        bytes32 p = _p(100e6);
        bytes32 q = _v(100e6);
        vm.startPrank(alice);
        perennial.buy(p, MarketsPerennial.Outcome.Yes, 900e6, 0);
        v4.buy(q, MarketsV4.Outcome.Yes, 900e6, 0);
        vm.stopPrank();
        vm.warp(perennial.getMarket(p).expiry + WINDOW + 1);
        vm.expectEmit(true, false, false, true, address(perennial));
        emit VoidFeesPaid(p, 0, 18e5, 0, address(0));
        perennial.voidMarket(p);
        vm.expectEmit(true, false, false, true, address(v4));
        emit VoidFeesPaid(q, 0, 18e5, 0, address(0));
        v4.voidMarket(q);
        assertEq(ledger.balanceOf(address(pool)), 45e5 + 18e5, "commons: 50% per trade + the escrow");
        assertEq(ledger.balanceOf(treasury), 45e5 + 18e5, "treasury: 50% per trade + the escrow");
        assertEq(ledger.balanceOf(agent), 0);
        assertEq(perennial.agentEscrow(p), 0);
        assertEq(v4.agentEscrow(q), 0);
    }

    /// A successful challenge of an attestation OUTSIDE the settlement window earns
    /// nothing from the market: it did not remove the market's reading.
    function test_void_outOfWindowChallenge_earnsNothing() public {
        bytes32 id = _p(100e6);
        vm.prank(alice);
        perennial.buy(id, MarketsPerennial.Outcome.Yes, 100e6, 0); // escrow 0.2
        uint256 expiry = perennial.getMarket(id).expiry;
        // an Invalid ruling on an attestation BEFORE the window
        vm.warp(expiry - 30 minutes);
        vm.prank(agent);
        bytes32 early = attestation.attest(feedId, 1, keccak256("early"));
        vm.prank(challenger);
        bytes32 d = dispute.challenge(early, keccak256("e"));
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
        assertEq(dispute.invalidatedBy(early), challenger);
        // the agent is now deactivated and cannot attest in the window: void
        vm.warp(expiry + WINDOW + 1);
        vm.expectEmit(true, false, false, true, address(perennial));
        emit VoidFeesPaid(id, 0, 2e5, 0, address(0));
        perennial.voidMarket(id);
        assertEq(ledger.balanceOf(challenger), 0);
    }

    // ───────────────────────── oracle views ─────────────────────────

    function test_firstInvalidatedInWindow_isBounded() public {
        uint256 from = vm.getBlockTimestamp() + 1;
        for (uint256 i; i < 33; i++) {
            vm.warp(from + i);
            vm.prank(agent);
            attestation.attest(feedId, int256(i), keccak256(abi.encode(i)));
        }
        bytes32 last = attestation.historyAt(feedId, agent, 32);
        vm.prank(challenger);
        bytes32 d = dispute.challenge(last, keccak256("e"));
        assertEq(dispute.invalidatedBy(last), address(0), "pending is not invalidated");
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);

        (bool found, bytes32 att) = attestation.firstInvalidatedInWindow(feedId, agent, from, from + 1 hours, 32);
        assertFalse(found, "33rd entry is beyond a 32-entry scan");
        (found, att) = attestation.firstInvalidatedInWindow(feedId, agent, from, from + 1 hours, 33);
        assertTrue(found);
        assertEq(att, last);
        (found,) = attestation.firstInvalidatedInWindow(feedId, agent, from, from + 31, 64);
        assertFalse(found, "outside [from, to]");
        (found,) = attestation.firstInvalidatedInWindow(feedId, agent, from + 32, from + 32, 1);
        assertTrue(found, "window start found by binary search");
        assertEq(dispute.invalidatedBy(attestation.historyAt(feedId, agent, 0)), address(0), "never challenged");
    }

    // ───────────────────────── V4: permissionless agents ─────────────────────────

    function test_v4_userAgent_createsSettlesAndEarns() public {
        address userAgent = address(0x05E7);
        usdc.mint(userAgent, 1_000e6);
        vm.startPrank(userAgent);
        usdc.approve(address(registry), type(uint256).max);
        bytes32 f = registry.createFeed("user feed", keccak256("u"), 10e6, DW, resolver);
        registry.registerAgent(f, keccak256("u"), 100e6);
        vm.stopPrank();
        assertTrue(v4.isApprovedFeed(f, userAgent), "any active agent on an approved-resolver feed");

        vm.prank(creator);
        bytes32 id = v4.createMarket(f, userAgent, 1, MarketsV4.Comparator.GreaterOrEqual, vm.getBlockTimestamp() + LIFE, 100e6);
        vm.prank(alice);
        v4.buy(id, MarketsV4.Outcome.Yes, 900e6, 0);
        vm.warp(v4.getMarket(id).expiry + 1);
        vm.prank(userAgent);
        attestation.attest(f, 1, keccak256("v"));
        vm.warp(vm.getBlockTimestamp() + DW);
        v4.resolve(id);
        assertEq(ledger.balanceOf(userAgent), 18e5, "the user's agent earns its escrowed 20% of the trading fees");
        // Perennial stays gated on the governor's agent list
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.AgentNotApproved.selector);
        perennial.createMarket(1, f, userAgent, 1, MarketsPerennial.Comparator.GreaterOrEqual, vm.getBlockTimestamp() + LIFE, 100e6);
    }

    function test_v4_selfResolvedFeed_refused_evenWithApprovedResolver() public {
        address userAgent = address(0x05E7);
        usdc.mint(userAgent, 1_000e6);
        vm.startPrank(userAgent);
        usdc.approve(address(registry), type(uint256).max);
        bytes32 f = registry.createFeed("self", keccak256("u"), 10e6, DW, userAgent);
        registry.registerAgent(f, keccak256("u"), 100e6);
        vm.stopPrank();
        v4.setApprovedResolver(userAgent, true);
        assertFalse(v4.isApprovedFeed(f, userAgent));
        vm.prank(creator);
        vm.expectRevert(MarketsV4.SelfResolvedFeed.selector);
        v4.createMarket(f, userAgent, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + LIFE, 100e6);
    }

    function test_v4_unapprovedResolver_refused() public {
        address userAgent = address(0x05E7);
        usdc.mint(userAgent, 1_000e6);
        vm.startPrank(userAgent);
        usdc.approve(address(registry), type(uint256).max);
        bytes32 f = registry.createFeed("friendly resolver", keccak256("u"), 10e6, DW, address(0xF12E));
        registry.registerAgent(f, keccak256("u"), 100e6);
        vm.stopPrank();
        assertFalse(v4.isApprovedFeed(f, userAgent));
        vm.prank(creator);
        vm.expectRevert(MarketsV4.ResolverNotApproved.selector);
        v4.createMarket(f, userAgent, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + LIFE, 100e6);
    }

    // ───────────────────────── ProgressPool: 1% protocol fee ─────────────────────────

    function test_progressPool_protocolFee_onePercent_streamCarries99() public {
        pool.grantRole(pool.PROGRESS_ROLE(), address(this));
        vm.prank(alice);
        ledger.internalTransfer(address(pool), 1_000e6);
        pool.addProgress(BUILDER_ID, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        pool.closeEpoch();
        assertEq(pool.PROTOCOL_FEE_BPS(), 100);
        assertEq(pool.PROTOCOL_TREASURY(), protocolTreasury);
        assertEq(pool.claimable(0, BUILDER_ID), 990e6, "claimable is net");

        vm.expectEmit(true, true, false, true, address(pool));
        emit ProtocolFeePaid(0, BUILDER_ID, 10e6);
        uint256 net = pool.claimFor(0, BUILDER_ID);
        assertEq(net, 990e6);
        assertEq(ledger.balanceOf(protocolTreasury), 10e6, "1% to the protocol treasury");
        (, address to,, uint256 cap,,,) = ledger.streams(pool.streamIdOf(0, BUILDER_ID));
        assertEq(to, builder);
        assertEq(cap, 990e6, "the stream carries 99%");
        assertEq(pool.claimable(0, BUILDER_ID), 0);
        assertEq(pool.unclaimedReserved(), 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        ledger.settleStream(pool.streamIdOf(0, BUILDER_ID));
        assertEq(ledger.balanceOf(builder), 990e6);
        _solvent();
    }

    function test_progressPool_rejectsZeroProtocolTreasury() public {
        vm.expectRevert(ProgressPool.ZeroAddress.selector);
        new ProgressPool(ledger, builders, caretakers, address(this), 1 days, 1 hours, address(0));
    }

    // ───────────────────────── solvency fuzz ─────────────────────────

    struct Books {
        uint256 totalIn; // LP seed + every buy's collateralIn
        uint256 sold; // what sellers received
        uint256 fees; // every trade's 1% fee (creator + commons/treasury paid, agent escrowed)
        uint256 redeemed;
        uint256 lp;
        uint256 feeRecipients; // what the fee recipients actually received
    }

    function testFuzz_perennial_solvency(uint256 seed, uint8 n, bool settle, uint256 liq) public {
        n = uint8(bound(n, 1, 30));
        liq = bound(liq, 5e6, 20_000e6);
        address[4] memory who = [alice, bob, carol, dave];
        Books memory b;
        bytes32 id = _p(liq);
        b.totalIn = liq;
        uint256 cr0 = ledger.balanceOf(creator);
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address t = who[r % 4];
            MarketsPerennial.Outcome o = (r >> 8) % 2 == 0 ? MarketsPerennial.Outcome.Yes : MarketsPerennial.Outcome.No;
            uint256 c0 = perennial.collateralOf(id);
            if ((r >> 16) % 3 == 0) {
                uint256 bal = o == MarketsPerennial.Outcome.Yes ? perennial.yesBalance(id, t) : perennial.noBalance(id, t);
                if (bal == 0) continue;
                vm.prank(t);
                try perennial.sell(id, o, bound(r >> 32, 1, bal), 0) returns (uint256 out) {
                    b.sold += out;
                    b.fees += (c0 - perennial.collateralOf(id)) - out;
                } catch {}
            } else {
                uint256 amt = bound(r >> 32, 1, 20_000e6);
                vm.prank(t);
                try perennial.buy(id, o, amt, 0) {
                    b.totalIn += amt;
                    b.fees += amt / 100;
                } catch {}
            }
            assertEq(
                ledger.balanceOf(address(perennial)),
                perennial.collateralOf(id) + perennial.agentEscrow(id),
                "balance == C + escrow while trading"
            );
        }
        uint256 c = perennial.collateralOf(id);
        assertEq(c, b.totalIn - b.sold - b.fees);

        uint256 expiry = perennial.getMarket(id).expiry;
        if (settle) {
            _attestAndFinalize(expiry, int256(r2(seed) % 2));
            perennial.resolve(id);
        } else {
            vm.warp(expiry + WINDOW + 1);
            perennial.voidMarket(id);
        }
        assertEq(ledger.balanceOf(address(perennial)), c, "only the escrow left at settlement");
        b.feeRecipients = (ledger.balanceOf(creator) - cr0) + ledger.balanceOf(address(pool)) + ledger.balanceOf(agent);
        assertEq(b.feeRecipients, b.fees, "every fee reached creator, commons or agent");

        for (uint256 i; i < 4; i++) {
            uint256 owed = perennial.redeemable(id, who[i]);
            if (owed == 0) continue;
            vm.prank(who[i]);
            assertEq(perennial.redeem(id), owed);
            b.redeemed += owed;
        }
        vm.prank(creator);
        b.lp = perennial.claimLP(id);
        uint256 dust = ledger.balanceOf(address(perennial));
        assertLe(dust, 4, "only rounding dust left");
        if (settle) assertEq(dust, 0, "resolve pays out exactly");
        assertEq(b.sold + b.redeemed + b.lp + b.fees + dust, b.totalIn, "every unit in is accounted for");
        _solvent();
    }

    function testFuzz_v4_solvency(uint256 seed, uint8 n, bool settle, uint256 liq) public {
        n = uint8(bound(n, 1, 30));
        liq = bound(liq, 5e6, 20_000e6);
        address[4] memory who = [alice, bob, carol, dave];
        Books memory b;
        bytes32 id = _v(liq);
        b.totalIn = liq;
        uint256 cr0 = ledger.balanceOf(creator);
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address t = who[r % 4];
            MarketsV4.Outcome o = (r >> 8) % 2 == 0 ? MarketsV4.Outcome.Yes : MarketsV4.Outcome.No;
            uint256 c0 = v4.collateralOf(id);
            if ((r >> 16) % 3 == 0) {
                uint256 bal = o == MarketsV4.Outcome.Yes ? v4.yesBalance(id, t) : v4.noBalance(id, t);
                if (bal == 0) continue;
                vm.prank(t);
                try v4.sell(id, o, bound(r >> 32, 1, bal), 0) returns (uint256 out) {
                    b.sold += out;
                    b.fees += (c0 - v4.collateralOf(id)) - out;
                } catch {}
            } else {
                uint256 amt = bound(r >> 32, 1, 20_000e6);
                vm.prank(t);
                try v4.buy(id, o, amt, 0) {
                    b.totalIn += amt;
                    b.fees += amt / 100;
                } catch {}
            }
        }
        uint256 c = v4.collateralOf(id);
        assertEq(c, b.totalIn - b.sold - b.fees);
        assertEq(ledger.balanceOf(address(v4)), c + v4.agentEscrow(id));

        uint256 expiry = v4.getMarket(id).expiry;
        if (settle) {
            _attestAndFinalize(expiry, int256(r2(seed) % 2));
            v4.resolve(id);
        } else {
            vm.warp(expiry + WINDOW + 1);
            v4.voidMarket(id);
        }
        assertEq(ledger.balanceOf(address(v4)), c);
        b.feeRecipients = (ledger.balanceOf(creator) - cr0) + ledger.balanceOf(treasury) + ledger.balanceOf(agent);
        assertEq(b.feeRecipients, b.fees, "every fee reached creator, treasury or agent");

        for (uint256 i; i < 4; i++) {
            uint256 owed = v4.redeemable(id, who[i]);
            if (owed == 0) continue;
            vm.prank(who[i]);
            assertEq(v4.redeem(id), owed);
            b.redeemed += owed;
        }
        vm.prank(creator);
        b.lp = v4.claimLP(id);
        uint256 dust = ledger.balanceOf(address(v4));
        assertLe(dust, 4, "only rounding dust left");
        if (settle) assertEq(dust, 0, "resolve pays out exactly");
        assertEq(b.sold + b.redeemed + b.lp + b.fees + dust, b.totalIn, "every unit in is accounted for");
        _solvent();
    }

    function r2(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, "value")));
    }
}
