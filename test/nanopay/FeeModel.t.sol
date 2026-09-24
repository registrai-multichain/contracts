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

/// @notice Fee & settlement model v2 (owner decision 2026-09-24), on both market
/// kinds:
///   - no trading fee; one 1% resolution fee on the collateral pot C, split
///     creator 30 / agent 20 / commons (Perennial) or treasury (V4) 50;
///   - winners redeem shares * (C - fee) / C, the LP its reserve on the same terms;
///   - void: traders get net cost minus 1% (pro rata only when early sellers took
///     more profit than the LP seed), the agent's 20% goes to a successful
///     challenger, else to the commons / treasury;
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
    event ProtocolFeePaid(uint256 indexed epoch, address indexed builder, uint256 fee);

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

    // ───────────────────────── no trading fee ─────────────────────────

    function test_perennial_buySell_exact_eventsCarryZeroFee() public {
        bytes32 id = _p(100e6);
        uint256 a0 = ledger.balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 shares = perennial.buy(id, MarketsPerennial.Outcome.Yes, 50e6, 0);
        assertEq(_lastFee(), 0, "Bought.fee == 0");
        // no fee: all 50 mints a full set (150 / 150); alice gets 150 - ceil(100 * 100 / 150)
        assertEq(shares, 150e6 - (uint256(100e6) * 100e6 + 150e6 - 1) / 150e6);
        assertEq(a0 - ledger.balanceOf(alice), 50e6, "exactly collateralIn debited");
        assertEq(perennial.collateralOf(id), 150e6);
        assertEq(perennial.netCost(id, alice), 50e6);
        assertEq(perennial.totalNetCost(id), 50e6);

        vm.recordLogs();
        vm.prank(alice);
        uint256 out = perennial.sell(id, MarketsPerennial.Outcome.Yes, shares, 0);
        assertEq(_lastFee(), 0, "Sold.fee == 0");
        assertEq(ledger.balanceOf(alice), a0 - 50e6 + out, "exactly collateralOut credited");
        // a round trip returns (to rounding) what was paid: no fee was taken
        assertApproxEqAbs(out, 50e6, 2);
        assertEq(perennial.collateralOf(id), 150e6 - out);
        assertEq(perennial.netCost(id, alice), 50e6 - out);
        assertEq(ledger.balanceOf(address(perennial)), perennial.collateralOf(id));
        assertEq(ledger.balanceOf(creator), 5_000_000e6 - 100e6, "creator paid nothing while trading");
        assertEq(ledger.balanceOf(address(pool)), 0);
        assertEq(ledger.balanceOf(agent), 0);
    }

    function test_v4_buySell_exact_eventsCarryZeroFee() public {
        bytes32 id = _v(100e6);
        uint256 a0 = ledger.balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 shares = v4.buy(id, MarketsV4.Outcome.No, 50e6, 0);
        assertEq(_lastFee(), 0, "Bought.fee == 0");
        assertEq(shares, 150e6 - (uint256(100e6) * 100e6 + 150e6 - 1) / 150e6);
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = v4.sell(id, MarketsV4.Outcome.No, shares, 0);
        assertEq(_lastFee(), 0, "Sold.fee == 0");
        assertEq(ledger.balanceOf(alice), a0 - 50e6 + out);
        assertApproxEqAbs(out, 50e6, 2);
        assertEq(ledger.balanceOf(address(v4)), v4.collateralOf(id));
        assertEq(ledger.balanceOf(treasury), 0);
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

    // ───────────────────────── resolve: 1% of C, 30/20/50 ─────────────────────────

    function test_perennial_resolveFee_exactSplit_winnersPaidNetOverGross_lpPot() public {
        bytes32 id = _p(100e6);
        vm.prank(alice);
        uint256 aYes = perennial.buy(id, MarketsPerennial.Outcome.Yes, 600e6, 0);
        vm.prank(bob);
        uint256 bNo = perennial.buy(id, MarketsPerennial.Outcome.No, 300e6, 0);
        assertEq(perennial.collateralOf(id), 1_000e6);
        MarketsPerennial.Market memory m = perennial.getMarket(id);

        uint256 c0 = ledger.balanceOf(creator);
        _attestAndFinalize(m.expiry, 1); // YES
        vm.expectEmit(true, false, false, true, address(perennial));
        emit FeesPaid(id, 3e6, 5e6, 2e6);
        perennial.resolve(id);

        // C = 1000: fee 10 -> creator 3, agent 2, commons 5
        assertEq(ledger.balanceOf(creator) - c0, 3e6, "creator 30%");
        assertEq(ledger.balanceOf(agent), 2e6, "agent 20%");
        assertEq(ledger.balanceOf(address(pool)), 5e6, "commons 50%");
        assertEq(perennial.settledGross(id), 1_000e6);
        assertEq(perennial.settledNet(id), 990e6);
        assertEq(ledger.balanceOf(address(perennial)), 990e6);

        uint256 aPay = (aYes * 990e6) / 1_000e6;
        assertEq(perennial.redeemable(id, alice), aPay);
        assertEq(perennial.redeemable(id, bob), 0, "loser");
        vm.prank(alice);
        assertEq(perennial.redeem(id), aPay, "shares * net / gross");
        vm.prank(bob);
        vm.expectRevert(MarketsPerennial.InsufficientShares.selector);
        perennial.redeem(id);
        assertGt(bNo, 0);

        uint256 lpPot = (m.yesReserve * 990e6) / 1_000e6;
        assertEq(perennial.lpPotAtResolution(id), lpPot, "LP pot = winning reserve * net / gross");
        assertEq(perennial.claimableLP(id, creator), lpPot);
        vm.prank(creator);
        assertEq(perennial.claimLP(id), lpPot);
        assertEq(perennial.claimableLP(id, creator), 0);
        assertLe(ledger.balanceOf(address(perennial)), 2, "dust");
        _solvent();
    }

    function test_v4_resolveFee_exactSplit_toTreasury() public {
        bytes32 id = _v(100e6);
        vm.prank(alice);
        uint256 aNo = v4.buy(id, MarketsV4.Outcome.No, 900e6, 0);
        MarketsV4.Market memory m = v4.getMarket(id);
        uint256 c0 = ledger.balanceOf(creator);
        _attestAndFinalize(m.expiry, 0); // NO wins (0 < 1)
        vm.expectEmit(true, false, false, true, address(v4));
        emit FeesPaid(id, 3e6, 5e6, 2e6);
        v4.resolve(id);
        assertEq(ledger.balanceOf(creator) - c0, 3e6);
        assertEq(ledger.balanceOf(agent), 2e6);
        assertEq(ledger.balanceOf(treasury), 5e6, "the 50% leg is the treasury's");
        vm.prank(alice);
        assertEq(v4.redeem(id), (aNo * 990e6) / 1_000e6);
        vm.prank(creator);
        assertEq(v4.claimLP(id), (m.noReserve * 990e6) / 1_000e6);
        assertLe(ledger.balanceOf(address(v4)), 2);
        _solvent();
    }

    /// The fee legs never strand a unit: commons takes the remainder.
    function testFuzz_feeLegsSumToFee(uint256 buyIn) public {
        buyIn = bound(buyIn, 1, 1_000_000e6);
        bytes32 id = _p(5e6);
        vm.prank(alice);
        try perennial.buy(id, MarketsPerennial.Outcome.Yes, buyIn, 0) {} catch {}
        uint256 c = perennial.collateralOf(id);
        uint256 c0 = ledger.balanceOf(creator);
        _attestAndFinalize(perennial.getMarket(id).expiry, 1);
        perennial.resolve(id);
        uint256 fee = (c * 100) / 10_000;
        uint256 paid = (ledger.balanceOf(creator) - c0) + ledger.balanceOf(agent) + ledger.balanceOf(address(pool));
        assertEq(paid, fee);
        assertEq(ledger.balanceOf(address(perennial)), c - fee);
    }

    // ───────────────────────── void: net cost minus 1% ─────────────────────────

    function test_perennial_void_refundsNetCostMinusOnePercent_afterPartialSell() public {
        bytes32 id = _p(100e6);
        vm.prank(alice);
        uint256 aYes = perennial.buy(id, MarketsPerennial.Outcome.Yes, 400e6, 0);
        vm.prank(bob);
        perennial.buy(id, MarketsPerennial.Outcome.No, 200e6, 0);
        vm.prank(alice);
        uint256 out = perennial.sell(id, MarketsPerennial.Outcome.Yes, aYes / 4, 0);
        assertLt(out, 400e6);
        uint256 aCost = 400e6 - out;
        assertEq(perennial.netCost(id, alice), aCost);
        uint256 c = perennial.collateralOf(id);
        assertEq(c, 700e6 - out);

        vm.warp(perennial.getMarket(id).expiry + WINDOW + 1);
        perennial.voidMarket(id);
        uint256 fee = c / 100;
        uint256 pool_ = ((aCost + 200e6) * 9_900) / 10_000;
        assertEq(perennial.voidTraderPool(id), pool_);
        assertEq(perennial.voidNetCostTotal(id), aCost + 200e6);

        uint256 aPay = (aCost * pool_) / (aCost + 200e6);
        assertApproxEqAbs(aPay, (aCost * 99) / 100, 1, "alice: net cost minus 1%");
        assertEq(perennial.redeemable(id, alice), aPay);
        vm.prank(alice);
        assertEq(perennial.redeem(id), aPay);
        vm.prank(bob);
        assertApproxEqAbs(perennial.redeem(id), 198e6, 1, "bob: 200 minus 1%");
        vm.prank(creator);
        assertEq(perennial.claimLP(id), c - fee - pool_, "LP gets the rest");
        assertLe(ledger.balanceOf(address(perennial)), 2);
        _solvent();
    }

    /// The rare case: an early seller's profit exceeds the LP seed, so the market
    /// holds less than 99% of the traders' net costs. They share what there is
    /// pro rata; the LP gets nothing; nobody is paid more than the market holds.
    function test_perennial_void_proRata_whenEarlySellerProfitExceedsLpSeed() public {
        bytes32 id = _p(5e6); // minimum seed
        vm.prank(bob);
        perennial.buy(id, MarketsPerennial.Outcome.No, 1_000e6, 0); // YES becomes cheap
        vm.prank(alice);
        uint256 aYes = perennial.buy(id, MarketsPerennial.Outcome.Yes, 10e6, 0);
        vm.prank(carol);
        perennial.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // YES becomes dear
        vm.prank(alice);
        uint256 out = perennial.sell(id, MarketsPerennial.Outcome.Yes, aYes, 0);
        assertGt(out - 10e6, 5e6, "alice's profit exceeds the LP seed");
        assertEq(perennial.netCost(id, alice), 0, "a profit is not a negative cost");

        uint256 c = perennial.collateralOf(id);
        uint256 tnc = perennial.totalNetCost(id);
        assertEq(tnc, 3_000e6);
        assertGt(tnc, c, "the traders put in more than the market still holds");

        vm.warp(perennial.getMarket(id).expiry + WINDOW + 1);
        perennial.voidMarket(id);
        uint256 avail = c - c / 100;
        assertEq(perennial.voidTraderPool(id), avail, "capped at what the market holds");
        uint256 bPay = (1_000e6 * avail) / 3_000e6;
        uint256 cPay = (2_000e6 * avail) / 3_000e6;
        assertLt(bPay, 990e6, "less than net cost minus 1%: pro rata");
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

    function test_v4_void_refundsNetCostMinusOnePercent() public {
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
        assertEq(v4.claimLP(id), 99e6);
        assertEq(ledger.balanceOf(address(v4)), 0);
    }

    // ───────────────────────── void: challenger reward ─────────────────────────

    /// Full Dispute flow: the agent attests inside the settlement window, a
    /// challenger disputes, the resolver rules Invalid, the window passes, the
    /// market voids — and the agent's 20% goes to that challenger.
    function test_perennial_void_paysTheSuccessfulChallenger() public {
        bytes32 id = _p(100e6);
        vm.prank(alice);
        perennial.buy(id, MarketsPerennial.Outcome.Yes, 900e6, 0); // C = 1000, fee 10
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
        emit VoidFeesPaid(id, 3e6, 5e6, 2e6, challenger);
        perennial.voidMarket(id);
        assertEq(ledger.balanceOf(challenger), 2e6, "challenger reward = the agent's 20%");
        assertEq(ledger.balanceOf(agent), 0, "the agent earns nothing");
        assertEq(ledger.balanceOf(address(pool)), 5e6, "commons its 50%");
        assertEq(ledger.balanceOf(creator) - c0, 3e6);
        vm.prank(alice);
        assertEq(perennial.redeem(id), 891e6, "900 minus 1%");
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
        emit VoidFeesPaid(id, 3e6, 5e6, 2e6, challenger);
        v4.voidMarket(id);
        assertEq(ledger.balanceOf(challenger), 2e6);
        assertEq(ledger.balanceOf(treasury), 5e6);
    }

    /// No successful challenger: the 20% goes to the commons / treasury.
    function test_void_noChallenger_agentLegToCommonsAndTreasury() public {
        bytes32 p = _p(100e6);
        bytes32 q = _v(100e6);
        vm.startPrank(alice);
        perennial.buy(p, MarketsPerennial.Outcome.Yes, 900e6, 0);
        v4.buy(q, MarketsV4.Outcome.Yes, 900e6, 0);
        vm.stopPrank();
        vm.warp(perennial.getMarket(p).expiry + WINDOW + 1);
        vm.expectEmit(true, false, false, true, address(perennial));
        emit VoidFeesPaid(p, 3e6, 7e6, 0, address(0));
        perennial.voidMarket(p);
        vm.expectEmit(true, false, false, true, address(v4));
        emit VoidFeesPaid(q, 3e6, 7e6, 0, address(0));
        v4.voidMarket(q);
        assertEq(ledger.balanceOf(address(pool)), 7e6, "commons 50% + 20%");
        assertEq(ledger.balanceOf(treasury), 7e6, "treasury 50% + 20%");
        assertEq(ledger.balanceOf(agent), 0);
    }

    /// A successful challenge of an attestation OUTSIDE the settlement window earns
    /// no share of the market's fee: it did not remove the market's reading.
    function test_void_outOfWindowChallenge_earnsNothing() public {
        bytes32 id = _p(100e6);
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
        emit VoidFeesPaid(id, 3e5, 7e5, 0, address(0));
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
        assertEq(ledger.balanceOf(userAgent), 2e6, "the user's agent earns 20% of the 1% fee");
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
        pool.addProgress(builder, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        pool.closeEpoch();
        assertEq(pool.PROTOCOL_FEE_BPS(), 100);
        assertEq(pool.PROTOCOL_TREASURY(), protocolTreasury);
        assertEq(pool.claimable(0, builder), 990e6, "claimable is net");

        vm.expectEmit(true, true, false, true, address(pool));
        emit ProtocolFeePaid(0, builder, 10e6);
        uint256 net = pool.claimFor(0, builder);
        assertEq(net, 990e6);
        assertEq(ledger.balanceOf(protocolTreasury), 10e6, "1% to the protocol treasury");
        (, address to,, uint256 cap,,,) = ledger.streams(pool.streamIdOf(0, builder));
        assertEq(to, builder);
        assertEq(cap, 990e6, "the stream carries 99%");
        assertEq(pool.claimable(0, builder), 0);
        assertEq(pool.unclaimedReserved(), 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        ledger.settleStream(pool.streamIdOf(0, builder));
        assertEq(ledger.balanceOf(builder), 990e6);
        _solvent();
    }

    function test_progressPool_rejectsZeroProtocolTreasury() public {
        vm.expectRevert(ProgressPool.ZeroAddress.selector);
        new ProgressPool(ledger, builders, caretakers, address(this), 1 days, 1 hours, address(0));
    }

    // ───────────────────────── solvency fuzz ─────────────────────────

    struct Books {
        uint256 totalIn; // LP seed + every buy
        uint256 sold; // every sell's proceeds
        uint256 fees; // what left at resolve / void
        uint256 redeemed;
        uint256 lp;
    }

    function testFuzz_perennial_solvency(uint256 seed, uint8 n, bool settle, uint256 liq) public {
        n = uint8(bound(n, 1, 30));
        liq = bound(liq, 5e6, 20_000e6);
        address[4] memory who = [alice, bob, carol, dave];
        Books memory b;
        bytes32 id = _p(liq);
        b.totalIn = liq;
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address t = who[r % 4];
            MarketsPerennial.Outcome o = (r >> 8) % 2 == 0 ? MarketsPerennial.Outcome.Yes : MarketsPerennial.Outcome.No;
            if ((r >> 16) % 3 == 0) {
                uint256 bal = o == MarketsPerennial.Outcome.Yes ? perennial.yesBalance(id, t) : perennial.noBalance(id, t);
                if (bal == 0) continue;
                vm.prank(t);
                try perennial.sell(id, o, bound(r >> 32, 1, bal), 0) returns (uint256 out) {
                    b.sold += out;
                } catch {}
            } else {
                uint256 amt = bound(r >> 32, 1, 20_000e6);
                vm.prank(t);
                try perennial.buy(id, o, amt, 0) {
                    b.totalIn += amt;
                } catch {}
            }
            assertEq(ledger.balanceOf(address(perennial)), perennial.collateralOf(id), "balance == C while trading");
        }
        uint256 c = perennial.collateralOf(id);
        assertEq(c, b.totalIn - b.sold);

        uint256 expiry = perennial.getMarket(id).expiry;
        if (settle) {
            _attestAndFinalize(expiry, int256(r2(seed) % 2));
            perennial.resolve(id);
        } else {
            vm.warp(expiry + WINDOW + 1);
            perennial.voidMarket(id);
        }
        b.fees = c - ledger.balanceOf(address(perennial));
        assertEq(b.fees, c / 100, "exactly the 1% fee left the market");

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
        assertLe(dust, 6, "only rounding dust left");
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
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address t = who[r % 4];
            MarketsV4.Outcome o = (r >> 8) % 2 == 0 ? MarketsV4.Outcome.Yes : MarketsV4.Outcome.No;
            if ((r >> 16) % 3 == 0) {
                uint256 bal = o == MarketsV4.Outcome.Yes ? v4.yesBalance(id, t) : v4.noBalance(id, t);
                if (bal == 0) continue;
                vm.prank(t);
                try v4.sell(id, o, bound(r >> 32, 1, bal), 0) returns (uint256 out) {
                    b.sold += out;
                } catch {}
            } else {
                uint256 amt = bound(r >> 32, 1, 20_000e6);
                vm.prank(t);
                try v4.buy(id, o, amt, 0) {
                    b.totalIn += amt;
                } catch {}
            }
        }
        uint256 c = v4.collateralOf(id);
        assertEq(c, b.totalIn - b.sold);
        assertEq(ledger.balanceOf(address(v4)), c);

        uint256 expiry = v4.getMarket(id).expiry;
        if (settle) {
            _attestAndFinalize(expiry, int256(r2(seed) % 2));
            v4.resolve(id);
        } else {
            vm.warp(expiry + WINDOW + 1);
            v4.voidMarket(id);
        }
        b.fees = c - ledger.balanceOf(address(v4));
        assertEq(b.fees, c / 100);

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
        assertLe(dust, 6, "only rounding dust left");
        assertEq(b.sold + b.redeemed + b.lp + b.fees + dust, b.totalIn, "every unit in is accounted for");
        _solvent();
    }

    function r2(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, "value")));
    }
}
