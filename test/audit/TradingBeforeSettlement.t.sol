// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {BinaryMarket} from "../../src/nanopay/BinaryMarket.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {FundKit} from "../perennial/FundKit.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// The trading surface both market contracts share (enums are uint8 on the ABI).
interface IM {
    function buy(bytes32, uint8, uint256, uint256, uint256) external returns (uint256);
    function sell(bytes32, uint8, uint256, uint256, uint256) external returns (uint256);
    function yesBalance(bytes32, address) external view returns (uint256);
    function noBalance(bytes32, address) external view returns (uint256);
    function collateralOf(bytes32) external view returns (uint256);
    function agentEscrow(bytes32) external view returns (uint256);
    function netCost(bytes32, address) external view returns (uint256);
    function totalNetCost(bytes32) external view returns (uint256);
    function resolve(bytes32) external;
    function voidMarket(bytes32) external;
    function redeem(bytes32) external returns (uint256);
    function claimLP(bytes32) external returns (uint256);
    function redeemable(bytes32, address) external view returns (uint256);
    function priceOf(bytes32, uint8) external view returns (uint256);
    function quoteBuy(bytes32, uint8, uint256) external view returns (uint256, uint256);
    function quoteSell(bytes32, uint8, uint256) external view returns (uint256, uint256);
    function sweepDust(bytes32) external returns (uint256);
    function unpaid(bytes32) external view returns (uint256);
    function claimsLeft(bytes32) external view returns (uint256);
}

/// @notice Audit (phase 2): trading positions BEFORE settlement, on both market
/// contracts. Properties asserted strictly — no try/catch around sells:
///   1. exit liveness: any holder can always sell any part of its position while
///      trading, at any price the fuzzer reaches;
///   2. full unwind: when every trader has sold out, the pool is back at 50/50
///      and the LP holds at least its seed (k never falls);
///   3. pricing: a sell never pays more than 1 per share; a buy-then-sell round
///      trip never profits; selling in pieces never beats one sell;
///   4. isolation: two markets in one contract never pay from each other.
contract TradingBeforeSettlementTest is Test {
    uint8 constant YES = 0;
    uint8 constant NO = 1;

    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    BuilderFund fund;
    SeasonPool pool;
    MarketsPerennial perennial;
    MarketsV4 v4;

    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address builder = address(0xB111);
    address[4] traders = [address(0xA11CE), address(0xB0B), address(0xCA201), address(0xDA5E)];
    bytes32 feedId;

    uint256 constant DW = 1 hours;
    uint256 constant WINDOW = 1 hours;
    uint256 constant GRACE = 1 days;
    uint256 constant LIFE = 10 hours;

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
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        perennial = new MarketsPerennial(ledger, registry, attestation, builders, address(this), fund, WINDOW, GRACE);
        FundKit.wire(fund, address(perennial));
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
        for (uint256 i; i < 4; i++) _fund(traders[i]);
    }

    function _fund(address a) internal {
        usdc.mint(a, 100_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000_000e6);
        ledger.approveSpender(address(perennial), type(uint256).max);
        ledger.approveSpender(address(v4), type(uint256).max);
        vm.stopPrank();
    }

    function _market(bool onV4, uint256 liq) internal returns (IM m, bytes32 id) {
        vm.prank(creator);
        if (onV4) {
            id = v4.createMarket(feedId, agent, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + LIFE, liq);
            m = IM(address(v4));
        } else {
            id = perennial.createMarket(
                1, feedId, agent, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + LIFE, liq
            );
            m = IM(address(perennial));
        }
    }

    function _bal(IM m, bytes32 id, address t, uint8 o) internal view returns (uint256) {
        return o == YES ? m.yesBalance(id, t) : m.noBalance(id, t);
    }

    /// Random buys and partial sells by 4 traders. Every call must succeed.
    function _churn(IM m, bytes32 id, uint256 seed, uint256 n, uint256 maxBuy) internal {
        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address t = traders[r % 4];
            uint8 o = uint8((r >> 8) % 2);
            uint256 bal = _bal(m, id, t, o);
            if ((r >> 16) % 3 == 0 && bal > 0) {
                uint256 s = bound(r >> 32, 1, bal);
                (uint256 q, uint256 qFee) = m.quoteSell(id, o, s);
                vm.prank(t);
                if (q == 0) {
                    // the curve values these shares at 0: refused, not burned
                    vm.expectRevert(BinaryMarket.AmountTooLow.selector);
                    m.sell(id, o, s, 0, type(uint256).max);
                    continue;
                }
                uint256 out = m.sell(id, o, s, 0, type(uint256).max); // strict: an exit must never revert
                assertEq(out, q, "sell pays exactly its quote");
                assertLe(out + qFee, s, "a sell never pays more than 1 per share");
            } else {
                // amounts across 7 orders of magnitude so prices reach extremes
                uint256 amt = bound(r >> 32, 1e3, maxBuy) / (10 ** ((r >> 64) % 7));
                if (amt < 1e3) amt = 1e3;
                (uint256 q,) = m.quoteBuy(id, o, amt);
                vm.prank(t);
                assertEq(m.buy(id, o, amt, 0, type(uint256).max), q, "buy fills exactly its quote");
            }
        }
    }

    /// Everyone sells everything. Returns true when some holder kept a position the
    /// curve values at 0 (it cannot be sold, only settled).
    function _unwindAll(IM m, bytes32 id) internal returns (bool dustLeft) {
        for (uint256 i; i < 4; i++) {
            for (uint8 o; o < 2; o++) {
                uint256 b = _bal(m, id, traders[i], o);
                if (b == 0) continue;
                (uint256 q,) = m.quoteSell(id, o, b);
                if (q == 0) {
                    dustLeft = true;
                    continue;
                }
                vm.prank(traders[i]);
                m.sell(id, o, b, 0, type(uint256).max); // strict
                assertEq(_bal(m, id, traders[i], o), 0);
            }
        }
    }

    // ─────────────── 1 + 2. exit liveness and full unwind ───────────────

    function testFuzz_everyoneCanAlwaysExit_thenPoolIsWhole(uint256 seed, uint8 n, uint256 liq, bool onV4)
        public
    {
        n = uint8(bound(n, 1, 60));
        liq = bound(liq, 5e6, 50_000e6);
        (IM m, bytes32 id) = _market(onV4, liq);
        _churn(m, id, seed, n, 2_000_000e6);
        assertEq(ledger.balanceOf(address(m)), m.collateralOf(id) + m.agentEscrow(id), "C + escrow held");

        bool dustLeft = _unwindAll(m, id);
        // nobody holds shares: YES supply == NO supply == C sit in the pool
        if (!dustLeft) assertEq(m.priceOf(id, YES), 0.5e18, "pool back at 50/50 once everyone exits");
        assertGe(m.collateralOf(id), liq, "LP never below its seed after a full unwind (k never falls)");
        assertEq(ledger.balanceOf(address(m)), m.collateralOf(id) + m.agentEscrow(id));
    }

    // ─────────────── 3. pricing sanity ───────────────

    function testFuzz_roundTripNeverProfits(uint256 liq, uint256 pre, uint256 amt, bool preYes, bool yes, bool onV4)
        public
    {
        liq = bound(liq, 5e6, 50_000e6);
        (IM m, bytes32 id) = _market(onV4, liq);
        pre = bound(pre, 0, 1_000_000e6);
        if (pre >= 1e3) {
            vm.prank(traders[1]);
            m.buy(id, preYes ? YES : NO, pre, 0, type(uint256).max); // move the price first
        }
        amt = bound(amt, 1e3, 1_000_000e6);
        uint8 o = yes ? YES : NO;
        vm.startPrank(traders[0]);
        uint256 shares = m.buy(id, o, amt, 0, type(uint256).max);
        uint256 out = m.sell(id, o, shares, 0, type(uint256).max);
        vm.stopPrank();
        assertLt(out, amt, "buy then sell returns less than paid");
        assertLe(out, (amt * 9801) / 10_000 + 1, "at most the two 1% fees' worth is lost");
    }

    function testFuzz_piecesNeverBeatOneSell(uint256 liq, uint256 amt, uint8 pieces, bool yes, bool onV4) public {
        liq = bound(liq, 5e6, 50_000e6);
        amt = bound(amt, 1e6, 1_000_000e6);
        pieces = uint8(bound(pieces, 2, 20));
        uint8 o = yes ? YES : NO;

        uint256 snap = vm.snapshotState();
        (IM m, bytes32 id) = _market(onV4, liq);
        vm.startPrank(traders[0]);
        uint256 shares = m.buy(id, o, amt, 0, type(uint256).max);
        uint256 whole = m.sell(id, o, shares, 0, type(uint256).max);
        vm.stopPrank();

        vm.revertToState(snap);
        (m, id) = _market(onV4, liq);
        vm.startPrank(traders[0]);
        shares = m.buy(id, o, amt, 0, type(uint256).max);
        uint256 sum;
        uint256 left = shares;
        for (uint256 i; i < pieces; i++) {
            uint256 s = i == pieces - 1 ? left : shares / pieces;
            sum += m.sell(id, o, s, 0, type(uint256).max);
            left -= s;
        }
        vm.stopPrank();
        // per-piece fee flooring may round in the seller's favour by < 1 unit a piece
        assertLe(sum, whole + pieces, "splitting a sell gains at most rounding");
    }

    // ─────────────── 4. isolation + settlement after churn ───────────────

    function testFuzz_twoMarkets_isolated_thenSettleAndEveryonePaid(
        uint256 seed,
        uint8 n,
        bool resolveA,
        bool resolveB,
        bool yesWins,
        bool onV4
    ) public {
        n = uint8(bound(n, 1, 40));
        (IM m, bytes32 a) = _market(onV4, 100e6);
        (, bytes32 b) = _market(onV4, 7e6);
        _churn(m, a, seed, n, 500_000e6);
        _churn(m, b, ~seed, n, 500_000e6);
        uint256 cA = m.collateralOf(a);
        uint256 cB = m.collateralOf(b);
        assertEq(ledger.balanceOf(address(m)), cA + cB + m.agentEscrow(a) + m.agentEscrow(b), "both books held");

        uint256 expiry = block.timestamp + LIFE;
        if (resolveA || resolveB) {
            vm.warp(expiry + 1);
            vm.prank(agent);
            attestation.attest(feedId, yesWins ? int256(1) : int256(0), bytes32("v"));
            vm.warp(block.timestamp + DW);
        } else {
            vm.warp(expiry + WINDOW + 1);
        }
        // a market with a finalized in-window reading is Resolvable, never Voidable
        if (resolveA || resolveB) {
            m.resolve(a);
            m.resolve(b);
        } else {
            m.voidMarket(a);
            m.voidMarket(b);
        }

        _payEveryone(m, a, cA);
        _payEveryone(m, b, cB);
        assertLe(ledger.balanceOf(address(m)), 8, "only rounding dust left across both markets");
        assertEq(m.claimsLeft(a), 0, "every claimant of A claimed");
        assertEq(m.claimsLeft(b), 0, "every claimant of B claimed");
        assertEq(ledger.balanceOf(address(m)), m.unpaid(a) + m.unpaid(b), "unpaid is exactly the dust held");
        if (m.unpaid(a) > 0) m.sweepDust(a);
        if (m.unpaid(b) > 0) m.sweepDust(b);
        assertEq(ledger.balanceOf(address(m)), 0, "after the sweep the contract holds nothing");
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger solvent");
    }

    function _payEveryone(IM m, bytes32 id, uint256 c) internal {
        uint256 paid;
        for (uint256 i; i < 4; i++) {
            uint256 owed = m.redeemable(id, traders[i]);
            if (owed == 0) continue;
            vm.prank(traders[i]);
            assertEq(m.redeem(id), owed);
            paid += owed;
        }
        vm.prank(creator);
        paid += m.claimLP(id);
        assertLe(paid, c, "a market never pays more than its own collateral");
        assertGe(paid + 4, c, "and leaves at most rounding behind");
    }

    // ─────────────── boundary: trading closes exactly at expiry ───────────────

    function test_tradingClosesAtExpiry_sellsAndBuysBothStop() public {
        (IM m, bytes32 id) = _market(false, 100e6);
        vm.prank(traders[0]);
        uint256 sh = m.buy(id, YES, 10e6, 0, type(uint256).max);
        vm.warp(block.timestamp + LIFE - 1);
        vm.prank(traders[0]);
        m.sell(id, YES, sh / 2, 0, type(uint256).max); // last second: fine
        vm.warp(block.timestamp + 1);
        vm.prank(traders[0]);
        vm.expectRevert(BinaryMarket.MarketExpired.selector);
        m.sell(id, YES, sh / 2, 0, type(uint256).max);
        vm.prank(traders[1]);
        vm.expectRevert(BinaryMarket.MarketExpired.selector);
        m.buy(id, NO, 1e6, 0, type(uint256).max);
    }

    // ─────────────── findings ───────────────

    /// FIXED: a sell small enough that the curve pays 0 used to burn the shares for
    /// nothing; it now reverts and the shares stay.
    function test_dustSell_reverts_sharesKept() public {
        (IM m, bytes32 id) = _market(false, 100e6);
        vm.prank(traders[0]);
        m.buy(id, NO, 1_000e6, 0, type(uint256).max); // YES now cheap
        vm.prank(traders[1]);
        uint256 sh = m.buy(id, YES, 1e6, 0, type(uint256).max);
        uint256 c0 = m.collateralOf(id);
        (uint256 q,) = m.quoteSell(id, YES, 1);
        assertEq(q, 0, "the curve values 1 unit at 0");
        vm.prank(traders[1]);
        vm.expectRevert(BinaryMarket.AmountTooLow.selector);
        m.sell(id, YES, 1, 0, type(uint256).max);
        assertEq(m.yesBalance(id, traders[1]), sh, "share kept");
        assertEq(m.collateralOf(id), c0);
    }

    /// Void undoes every trade back to cost: a trader that already SOLD OUT at a
    /// loss is refunded that loss, funded by the counterparty's UNREALIZED gain
    /// (which the void erases), not by the LP: the LP gets its seed back exactly.
    function test_void_unwindsClosedPositionsToCost_lpWhole() public {
        (IM m, bytes32 id) = _market(false, 100e6);
        address alice = traders[0];
        address bob = traders[1];
        vm.prank(alice);
        uint256 sh = m.buy(id, YES, 50e6, 0, type(uint256).max);
        vm.prank(bob);
        m.buy(id, NO, 200e6, 0, type(uint256).max); // pushes YES down
        vm.prank(alice);
        uint256 out = m.sell(id, YES, sh, 0, type(uint256).max); // alice exits at a loss
        assertEq(m.yesBalance(id, alice), 0);
        uint256 loss = 50e6 - out;
        emit log_named_decimal_uint("alice realized loss", loss, 6);

        vm.warp(block.timestamp + LIFE + WINDOW + 1); // agent silent -> void
        m.voidMarket(id);
        uint256 refund = m.redeemable(id, alice);
        emit log_named_decimal_uint("alice void refund (holds no shares)", refund, 6);
        assertGt(refund, 0, "a closed position is refunded on void");
        vm.prank(creator);
        uint256 lp = m.claimLP(id);
        emit log_named_decimal_uint("LP gets back (seed 100)", lp, 6);
        assertEq(lp, 100e6, "LP whole: nobody realized a profit");
        assertEq(m.redeemable(id, bob), 198e6, "bob: his net cost (200 less the 1% fee)");
        assertEq(refund, m.netCost(id, alice), "alice: what she put in less what she took out");
    }

    /// DESIGN NOTE: on a market that will void, pump-and-dump across two wallets
    /// extracts the LP seed: wallet A's inflated buy is refunded at cost, wallet B
    /// keeps the profit it sold into A's pump.
    function test_note_void_pumpAndDump_drainsTheLp() public {
        (IM m, bytes32 id) = _market(false, 100e6);
        address a = traders[0];
        address b = traders[1];
        uint256 a0 = ledger.balanceOf(a) + ledger.balanceOf(b);
        vm.prank(b);
        uint256 sh = m.buy(id, YES, 20e6, 0, type(uint256).max);
        vm.prank(a);
        m.buy(id, YES, 500e6, 0, type(uint256).max); // pump
        vm.prank(b);
        m.sell(id, YES, sh, 0, type(uint256).max); // dump into it

        vm.warp(block.timestamp + LIFE + WINDOW + 1);
        m.voidMarket(id);
        vm.prank(a);
        m.redeem(id);
        vm.prank(creator);
        uint256 lp = m.claimLP(id);
        uint256 a1 = ledger.balanceOf(a) + ledger.balanceOf(b);
        emit log_named_decimal_uint("attacker (A+B) net gain", a1 - a0, 6);
        emit log_named_decimal_uint("LP gets back (seed 100)", lp, 6);
        assertGt(a1, a0, "attacker profits");
    }

    // ─────────────── deadline ───────────────

    function testFuzz_deadline(bool onV4, uint256 late) public {
        (IM m, bytes32 id) = _market(onV4, 100e6);
        late = bound(late, 1, LIFE - 1); // still trading
        uint256 dl = vm.getBlockTimestamp(); // not block.timestamp: via-ir reuses it across warps
        vm.prank(traders[0]);
        uint256 sh = m.buy(id, YES, 10e6, 0, dl); // deadline == now: fine
        vm.warp(dl + late);
        vm.startPrank(traders[0]);
        vm.expectRevert(BinaryMarket.DeadlineExpired.selector);
        m.buy(id, YES, 10e6, 0, dl);
        vm.expectRevert(BinaryMarket.DeadlineExpired.selector);
        m.sell(id, YES, sh, 0, dl);
        m.sell(id, YES, sh, 0, vm.getBlockTimestamp()); // a fresh deadline goes through
        vm.stopPrank();
    }

    // ─────────────── quotes ───────────────

    function testFuzz_quotesMatchExecution(uint256 liq, uint256 pre, uint256 amt, uint256 frac, bool yes, bool onV4)
        public
    {
        liq = bound(liq, 5e6, 50_000e6);
        (IM m, bytes32 id) = _market(onV4, liq);
        pre = bound(pre, 0, 2_000_000e6);
        if (pre >= 1e3) {
            vm.prank(traders[1]);
            m.buy(id, yes ? NO : YES, pre, 0, type(uint256).max);
        }
        uint8 o = yes ? YES : NO;
        amt = bound(amt, 1, 2_000_000e6);
        (uint256 qs, uint256 qf) = m.quoteBuy(id, o, amt);
        vm.prank(traders[0]);
        if (qs == 0) {
            vm.expectRevert(BinaryMarket.AmountTooLow.selector);
            m.buy(id, o, amt, 0, type(uint256).max);
            return;
        }
        assertEq(m.buy(id, o, amt, 0, type(uint256).max), qs, "buy == quoteBuy");
        assertEq(qf, (amt * 100) / 10_000, "quoted fee is 1%");
        uint256 s = bound(frac, 1, qs);
        (uint256 qo,) = m.quoteSell(id, o, s);
        vm.prank(traders[0]);
        if (qo == 0) {
            vm.expectRevert(BinaryMarket.AmountTooLow.selector);
            m.sell(id, o, s, 0, type(uint256).max);
        } else {
            assertEq(m.sell(id, o, s, 0, type(uint256).max), qo, "sell == quoteSell");
        }
    }

    function test_quotesAreZeroOutsideTrading() public {
        (IM m, bytes32 id) = _market(false, 100e6);
        (uint256 a,) = m.quoteBuy(id, YES, 0);
        assertEq(a, 0);
        (a,) = m.quoteBuy(bytes32("nope"), YES, 1e6);
        assertEq(a, 0, "unknown market");
        vm.warp(block.timestamp + LIFE);
        (a,) = m.quoteBuy(id, YES, 1e6);
        assertEq(a, 0, "expired: buy would revert");
        (a,) = m.quoteSell(id, YES, 1e6);
        assertEq(a, 0, "expired: sell would revert");
    }

    // ─────────────── claims accounting + dust sweep ───────────────

    function test_sweep_waitsForEveryClaimant_thenPaysTheSink() public {
        (IM m, bytes32 id) = _market(true, 10e6); // V4: dust goes to the treasury
        vm.prank(traders[0]);
        m.buy(id, YES, 3_333_333, 0, type(uint256).max);
        vm.prank(traders[1]);
        m.buy(id, NO, 7_777_777, 0, type(uint256).max);
        vm.prank(traders[2]);
        m.buy(id, YES, 1_111_111, 0, type(uint256).max);
        vm.warp(block.timestamp + LIFE + WINDOW + 1);
        m.voidMarket(id);
        assertEq(m.claimsLeft(id), 4, "3 refundable traders + the LP");

        vm.expectRevert(BinaryMarket.ClaimsOutstanding.selector);
        m.sweepDust(id);
        for (uint256 i; i < 3; i++) {
            vm.prank(traders[i]);
            m.redeem(id);
        }
        vm.expectRevert(BinaryMarket.ClaimsOutstanding.selector);
        m.sweepDust(id); // the LP has not claimed yet
        vm.prank(creator);
        m.claimLP(id);
        assertEq(m.claimsLeft(id), 0);

        uint256 dust = m.unpaid(id);
        assertEq(ledger.balanceOf(address(m)), dust);
        uint256 t0 = ledger.balanceOf(treasury);
        if (dust == 0) {
            vm.expectRevert(BinaryMarket.NothingToSweep.selector);
            m.sweepDust(id);
        } else {
            assertEq(m.sweepDust(id), dust);
            assertEq(ledger.balanceOf(treasury) - t0, dust, "dust to the treasury");
            vm.expectRevert(BinaryMarket.NothingToSweep.selector);
            m.sweepDust(id);
        }
        assertEq(ledger.balanceOf(address(m)), 0);
    }

    function test_sweep_perennialDustGoesToTheSeasonPool() public {
        (IM m, bytes32 id) = _market(false, 10e6);
        vm.prank(traders[0]);
        m.buy(id, YES, 3_333_333, 0, type(uint256).max);
        vm.prank(traders[1]);
        m.buy(id, NO, 7_777_777, 0, type(uint256).max);
        vm.prank(traders[2]);
        m.buy(id, YES, 1_111_111, 0, type(uint256).max);
        vm.warp(block.timestamp + LIFE + WINDOW + 1);
        m.voidMarket(id);
        for (uint256 i; i < 3; i++) {
            vm.prank(traders[i]);
            m.redeem(id);
        }
        vm.prank(creator);
        m.claimLP(id);
        uint256 dust = m.unpaid(id);
        uint256 p0 = pool.unallocated();
        if (dust > 0) {
            m.sweepDust(id);
            assertEq(pool.unallocated() - p0, dust, "dust to the season pool");
        }
        assertEq(ledger.balanceOf(address(m)), 0);
    }

    function test_resolve_claimsCountWinnersAndLp_noDust() public {
        (IM m, bytes32 id) = _market(false, 100e6);
        vm.prank(traders[0]);
        m.buy(id, YES, 10e6, 0, type(uint256).max);
        vm.prank(traders[1]);
        m.buy(id, YES, 5e6, 0, type(uint256).max);
        vm.prank(traders[2]);
        uint256 sh = m.buy(id, NO, 8e6, 0, type(uint256).max);
        vm.prank(traders[3]);
        uint256 sh3 = m.buy(id, YES, 4e6, 0, type(uint256).max);
        vm.prank(traders[3]);
        m.sell(id, YES, sh3, 0, type(uint256).max); // exited: not a claimant
        vm.prank(traders[2]);
        m.sell(id, NO, sh / 2, 0, type(uint256).max);

        vm.warp(block.timestamp + LIFE + 1);
        vm.prank(agent);
        attestation.attest(feedId, 1, bytes32("v")); // YES (>= 1)
        vm.warp(block.timestamp + DW);
        m.resolve(id);
        assertEq(m.claimsLeft(id), 3, "two YES holders + the LP");

        vm.prank(traders[2]);
        vm.expectRevert(BinaryMarket.InsufficientShares.selector); // a loser has nothing to claim
        m.redeem(id);
        vm.prank(traders[3]);
        vm.expectRevert(BinaryMarket.InsufficientShares.selector); // exited before settlement
        m.redeem(id);
        vm.prank(traders[0]);
        m.redeem(id);
        vm.prank(traders[1]);
        m.redeem(id);
        vm.prank(creator);
        m.claimLP(id);
        assertEq(m.claimsLeft(id), 0);
        assertEq(m.unpaid(id), 0, "resolve pays out exactly: no dust");
        assertEq(ledger.balanceOf(address(m)), 0);
    }

    function test_void_dustNetCostClaimant_notStuck() public {
        // A trader whose pro-rata refund floors to 0 must still be able to close
        // its claim, or the market's dust could never be swept.
        (IM m, bytes32 id) = _market(false, 5e6);
        vm.prank(traders[0]);
        uint256 sh = m.buy(id, YES, 50e6, 0, type(uint256).max);
        vm.prank(traders[1]);
        m.buy(id, NO, 1e3, 0, type(uint256).max); // tiny net cost
        vm.prank(traders[2]);
        m.buy(id, YES, 5e6, 0, type(uint256).max);
        vm.prank(traders[0]);
        m.sell(id, YES, sh, 0, type(uint256).max); // early seller takes profit beyond the seed
        vm.warp(block.timestamp + LIFE + WINDOW + 1);
        m.voidMarket(id);
        for (uint256 i; i < 3; i++) {
            if (m.netCost(id, traders[i]) == 0) continue;
            vm.prank(traders[i]);
            m.redeem(id); // never reverts for a claimant, even on a 0 payout
        }
        vm.prank(creator);
        m.claimLP(id);
        assertEq(m.claimsLeft(id), 0);
        if (m.unpaid(id) > 0) m.sweepDust(id);
        assertEq(ledger.balanceOf(address(m)), 0);
    }
}
