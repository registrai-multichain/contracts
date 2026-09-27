// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {BinaryMathBase} from "./BinaryMathBase.t.sol";
import {BinaryMarket} from "../../../src/nanopay/BinaryMarket.sol";
import {MarketsV4} from "../../../src/nanopay/MarketsV4.sol";

/// BinaryMarket math audit: rounding, conservation, round trips, void refunds.
contract BinaryMathFuzzTest is BinaryMathBase {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA501);
    address honest = address(0x4045);

    function setUp() public {
        _deploy();
        _fund(alice, 1e15);
        _fund(bob, 1e15);
        _fund(carol, 1e15);
        _fund(honest, 1e15);
    }

    // ───────────── PoC: Sybil split turns a void into profit against the LP ─────────────

    /// Two accounts of one attacker. A buys YES cheap, B buys YES big (moves the
    /// price), A sells into B's price: A's profit is "clamped" out of netCost
    /// (netCost floors at 0) while B's full netCost is refunded on void. The
    /// attacker as a whole traded at a loss on the curve, yet the void pays it a
    /// profit taken from the LP's seed.
    function test_PoC_voidSybilSplit_drainsLP() public {
        uint256 L = 1_000e6;
        bytes32 id = _market(L, 1 hours);
        uint256 a0 = ledger.balanceOf(alice) + ledger.balanceOf(bob);
        uint256 lp0 = ledger.balanceOf(creator);

        uint256 sa = _buy(alice, id, true, 100e6);
        _buy(bob, id, true, 1_000e6);
        _sell(alice, id, true, sa);
        assertEq(markets.netCost(id, alice), 0, "A's profit clamped away");

        _void(id);
        vm.prank(bob);
        markets.redeem(id);
        vm.prank(creator);
        uint256 lpPot = markets.claimLP(id);

        uint256 a1 = ledger.balanceOf(alice) + ledger.balanceOf(bob);
        uint256 creatorFees = ledger.balanceOf(creator) - (lp0 - 0) - lpPot; // creator's 30% fee legs
        console2.log("attacker profit (units)", a1 - a0);
        console2.log("LP pot on void (seed 1000e6)", lpPot);
        console2.log("creator fee legs", creatorFees);
        assertGt(a1, a0, "attacker ends up in profit on a void");
        assertLt(lpPot, L, "LP lost part of its seed on a void");
        _solvent();
    }

    /// Same trick on the production 5-USDC round seed.
    function test_PoC_voidSybilSplit_5usdcSeed() public {
        uint256 L = 5e6;
        bytes32 id = _market(L, 5 minutes);
        uint256 a0 = ledger.balanceOf(alice) + ledger.balanceOf(bob);
        uint256 sa = _buy(alice, id, true, 5e6);
        _buy(bob, id, true, 50e6);
        _sell(alice, id, true, sa);
        _void(id);
        vm.prank(bob);
        markets.redeem(id);
        vm.prank(creator);
        uint256 lpPot = markets.claimLP(id);
        uint256 a1 = ledger.balanceOf(alice) + ledger.balanceOf(bob);
        console2.log("attacker profit (units), 5 USDC seed", a1 - a0);
        console2.log("LP pot", lpPot);
        assertGt(a1, a0);
    }

    /// With the same trades from ONE account the attacker gets nothing on void
    /// beyond its money back less fees: the gain is purely from splitting.
    function test_control_singleAccountSameTradesNoProfitOnVoid() public {
        uint256 L = 1_000e6;
        bytes32 id = _market(L, 1 hours);
        uint256 a0 = ledger.balanceOf(alice);
        uint256 sa = _buy(alice, id, true, 100e6);
        _buy(alice, id, true, 1_000e6);
        _sell(alice, id, true, sa);
        _void(id);
        vm.prank(alice);
        markets.redeem(id);
        uint256 a1 = ledger.balanceOf(alice);
        assertLe(a1, a0, "a single account never profits on void");
    }

    /// Split trick pushed until the clamped profit exceeds the LP seed:
    /// totalNetCost > C, so honest traders' refunds are cut pro rata too.
    function test_PoC_voidSybilSplit_cutsHonestRefund() public {
        uint256 L = 5e6;
        bytes32 id = _market(L, 1 hours);
        _buy(honest, id, false, 20e6); // honest NO buyer
        uint256 hCost = markets.netCost(id, honest);
        uint256 a0 = ledger.balanceOf(alice) + ledger.balanceOf(bob);
        uint256 sa = _buy(alice, id, true, 20e6);
        _buy(bob, id, true, 400e6);
        _sell(alice, id, true, sa);
        _void(id);
        vm.prank(honest);
        uint256 hRefund = markets.redeem(id);
        vm.prank(bob);
        markets.redeem(id);
        uint256 a1 = ledger.balanceOf(alice) + ledger.balanceOf(bob);
        console2.log("honest netCost", hCost);
        console2.log("honest refund", hRefund);
        console2.log("attacker profit", a1 > a0 ? a1 - a0 : 0);
        assertLt(hRefund, hCost, "honest trader refunded less than its net cost");
        assertGt(a1, a0, "attacker in profit");
    }

    /// Fuzz the split: attacker profit on void is bounded by the LP seed plus
    /// honest traders' shortfall (conservation), and per-market solvency holds.
    function testFuzz_voidSybilSplit_bounded(uint256 L, uint256 a, uint256 b, uint256 h) public {
        L = bound(L, 5e6, 10_000e6);
        a = bound(a, 1e6, 10_000e6);
        b = bound(b, 1e6, 100_000e6);
        h = bound(h, 0, 10_000e6);
        bytes32 id = _market(L, 1 hours);
        if (h > 0) _buy(honest, id, false, h);
        uint256 hCost = markets.netCost(id, honest);
        uint256 a0 = ledger.balanceOf(alice) + ledger.balanceOf(bob);
        uint256 sa = _buy(alice, id, true, a);
        _buy(bob, id, true, b);
        _sell(alice, id, true, sa);
        _void(id);
        uint256 hRefund;
        if (hCost > 0) {
            vm.prank(honest);
            hRefund = markets.redeem(id);
        }
        vm.prank(bob);
        markets.redeem(id);
        vm.prank(creator);
        uint256 lpPot = markets.claimLP(id);
        uint256 a1 = ledger.balanceOf(alice) + ledger.balanceOf(bob);
        if (a1 > a0) assertLe(a1 - a0, (L - lpPot) + (hCost - hRefund), "profit beyond LP + honest loss");
        assertLe(markets.unpaid(id), 2, "only rounding dust left");
    }

    // ───────────── sole trader: never extracts on round trips ─────────────

    /// A sole trader doing any sequence of buys and sells and then selling back
    /// everything it can never ends above where it started (fees + rounding
    /// favour the pool; k never decreases).
    function testFuzz_soleTrader_roundTripsNeverProfit(uint256 L, uint256[8] memory amts, uint256 sides) public {
        L = bound(L, 5e6, 1e12);
        bytes32 id = _market(L, 1 hours);
        uint256 t0 = ledger.balanceOf(alice);
        for (uint256 i; i < 8; i++) {
            bool yes = (sides >> i) & 1 == 1;
            bool isSell = (sides >> (i + 8)) & 1 == 1;
            if (isSell) {
                uint256 bal = yes ? markets.yesBalance(id, alice) : markets.noBalance(id, alice);
                uint256 s = bound(amts[i], 0, bal);
                if (s == 0) continue;
                (uint256 q,) = markets.quoteSell(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, s);
                if (q == 0) continue;
                _sell(alice, id, yes, s);
            } else {
                _buy(alice, id, yes, bound(amts[i], 1, 1e12));
            }
        }
        // close out whatever the curve will take
        uint256 y = markets.yesBalance(id, alice);
        if (y > 0) {
            (uint256 q,) = markets.quoteSell(id, BinaryMarket.Outcome.Yes, y);
            if (q > 0) _sell(alice, id, true, y);
        }
        uint256 n = markets.noBalance(id, alice);
        if (n > 0) {
            (uint256 q,) = markets.quoteSell(id, BinaryMarket.Outcome.No, n);
            if (q > 0) _sell(alice, id, false, n);
        }
        assertLe(ledger.balanceOf(alice), t0, "sole trader extracted value via round trips");
        MarketsV4.Market memory m = markets.getMarket(id);
        // pool invariant: every share outside the pool plus the reserve is C
        assertEq(markets.yesBalance(id, alice) + m.yesReserve, markets.collateralOf(id));
        assertEq(markets.noBalance(id, alice) + m.noReserve, markets.collateralOf(id));
        assertGe(m.yesReserve * m.noReserve, L * L, "k fell below the seed");
    }

    /// Fee-free dust trades (buy < 100 units, sell gross < 100 units) repeated
    /// many times: no extraction, k only grows.
    function testFuzz_dustRoundTrips_noExtraction(uint256 L, uint256 pre, uint256 dust, bool preYes) public {
        L = bound(L, 5e6, 1e9);
        pre = bound(pre, 0, 1e10);
        dust = bound(dust, 1, 99);
        bytes32 id = _market(L, 1 hours);
        if (pre > 0) _buy(bob, id, preYes, pre); // skew the pool
        uint256 t0 = ledger.balanceOf(alice);
        for (uint256 i; i < 60; i++) {
            bool yes = i % 2 == 0;
            uint256 s = _buy(alice, id, yes, dust);
            (uint256 q,) = markets.quoteSell(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, s);
            if (q > 0) _sell(alice, id, yes, s);
        }
        // whatever alice still holds is worth at most 1 per share at settlement;
        // count it at 1 (an upper bound) and require no gain.
        uint256 held = markets.yesBalance(id, alice) > markets.noBalance(id, alice)
            ? markets.yesBalance(id, alice)
            : markets.noBalance(id, alice);
        assertLe(ledger.balanceOf(alice) + held, t0 + held, "dust extraction");
        assertLe(ledger.balanceOf(alice), t0);
    }

    // ───────────── sole trader through settlement ─────────────

    /// Sole trader + LP through resolution: every unit is accounted for
    /// (trader + LP + creator fees + treasury + agent == what went in) and the
    /// market ends with no balance once all claim. Trader's gain <= L.
    function testFuzz_soleTrader_resolveConserves(uint256 L, uint256[6] memory amts, uint256 sides, bool yesWins)
        public
    {
        L = bound(L, 5e6, 1e12);
        uint256 cr0 = ledger.balanceOf(creator);
        bytes32 id = _market(L, 1 hours);
        uint256 t0 = ledger.balanceOf(alice);
        for (uint256 i; i < 6; i++) {
            bool yes = (sides >> i) & 1 == 1;
            if ((sides >> (i + 8)) & 1 == 1) {
                uint256 bal = yes ? markets.yesBalance(id, alice) : markets.noBalance(id, alice);
                uint256 s = bound(amts[i], 0, bal);
                if (s == 0) continue;
                (uint256 q,) = markets.quoteSell(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, s);
                if (q == 0) continue;
                _sell(alice, id, yes, s);
            } else {
                _buy(alice, id, yes, bound(amts[i], 1, 1e12));
            }
        }
        _resolve(id, yesWins);
        uint256 win = yesWins ? markets.yesBalance(id, alice) : markets.noBalance(id, alice);
        if (win > 0) {
            vm.prank(alice);
            markets.redeem(id);
        }
        vm.prank(creator);
        markets.claimLP(id);
        assertEq(markets.unpaid(id), 0, "resolved: payouts sum to exactly C");
        assertEq(markets.claimsLeft(id), 0);
        assertEq(ledger.balanceOf(address(markets)), 0, "market fully drained, nothing stuck");
        uint256 t1 = ledger.balanceOf(alice);
        uint256 cr1 = ledger.balanceOf(creator);
        // conservation: alice + creator + treasury + agent unchanged in total
        assertEq(t0 + cr0, t1 + cr1 + ledger.balanceOf(treasury) + ledger.balanceOf(agent), "value created/destroyed");
        if (t1 > t0) assertLe(t1 - t0, L, "trader took more than the LP seed");
        _solvent();
    }

    /// Sole trader on void: gets back at most what it paid (less fees), LP gets
    /// at least its seed less nothing (sole trader cannot take LP profit).
    function testFuzz_soleTrader_voidNoGain(uint256 L, uint256[6] memory amts, uint256 sides) public {
        L = bound(L, 5e6, 1e12);
        bytes32 id = _market(L, 1 hours);
        uint256 t0 = ledger.balanceOf(alice);
        for (uint256 i; i < 6; i++) {
            bool yes = (sides >> i) & 1 == 1;
            if ((sides >> (i + 8)) & 1 == 1) {
                uint256 bal = yes ? markets.yesBalance(id, alice) : markets.noBalance(id, alice);
                uint256 s = bound(amts[i], 0, bal);
                if (s == 0) continue;
                (uint256 q,) = markets.quoteSell(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, s);
                if (q == 0) continue;
                _sell(alice, id, yes, s);
            } else {
                _buy(alice, id, yes, bound(amts[i], 1, 1e12));
            }
        }
        _void(id);
        if (markets.netCost(id, alice) > 0) {
            vm.prank(alice);
            markets.redeem(id);
        }
        vm.prank(creator);
        uint256 lp = markets.claimLP(id);
        assertLe(ledger.balanceOf(alice), t0, "sole trader gained on void");
        assertGe(lp, L, "LP lost seed to a sole trader on void");
        assertEq(markets.claimsLeft(id), 0);
        if (markets.unpaid(id) > 0) markets.sweepDust(id);
        assertEq(ledger.balanceOf(address(markets)), 0, "nothing stuck");
    }

    // ───────────── void pro-rata dust + sweep ─────────────

    function testFuzz_voidProRata_dustSweptAndNothingStuck(uint256 L, uint256[4] memory b, uint256 profitSell) public {
        L = bound(L, 5e6, 1e9);
        bytes32 id = _market(L, 1 hours);
        address[4] memory who = [alice, bob, carol, honest];
        for (uint256 i; i < 4; i++) {
            _buy(who[i], id, i % 2 == 0, bound(b[i], 1, 1e10));
        }
        // someone sells into the price to push totalNetCost above C (pro rata branch)
        uint256 s = bound(profitSell, 0, markets.yesBalance(id, alice));
        if (s > 0) {
            (uint256 q,) = markets.quoteSell(id, BinaryMarket.Outcome.Yes, s);
            if (q > 0) _sell(alice, id, true, s);
        }
        _void(id);
        uint256 paid;
        for (uint256 i; i < 4; i++) {
            if (markets.netCost(id, who[i]) > 0) {
                vm.prank(who[i]);
                paid += markets.redeem(id);
            }
        }
        vm.prank(creator);
        paid += markets.claimLP(id);
        assertEq(markets.claimsLeft(id), 0);
        uint256 dust = markets.unpaid(id);
        assertLe(dust, 4, "dust bounded by #claimants");
        if (dust > 0) markets.sweepDust(id);
        assertEq(ledger.balanceOf(address(markets)), 0, "nothing stuck after sweep");
        // double claims revert
        vm.prank(creator);
        vm.expectRevert(BinaryMarket.NoLPShares.selector);
        markets.claimLP(id);
        vm.prank(bob);
        vm.expectRevert(BinaryMarket.InsufficientShares.selector);
        markets.redeem(id);
        _solvent();
    }

    // ───────────── extreme prices / tiny pools ─────────────

    /// Drive the pool to an extreme price with a huge one-sided buy on the minimum
    /// seed, then trade both ways: no overflow, reserves stay > 0, invariant exact.
    function testFuzz_extremePrices(uint256 big, uint256 small, bool yes) public {
        big = bound(big, 1e6, 1e14); // up to 100M USDC
        small = bound(small, 1, 1e9);
        bytes32 id = _market(5e6, 1 hours);
        _buy(bob, id, yes, big);
        uint256 s = _buy(alice, id, !yes, small);
        (uint256 q,) = markets.quoteSell(id, yes ? BinaryMarket.Outcome.No : BinaryMarket.Outcome.Yes, s);
        if (q > 0) _sell(alice, id, !yes, s);
        uint256 bb = yes ? markets.yesBalance(id, bob) : markets.noBalance(id, bob);
        (q,) = markets.quoteSell(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, bb);
        if (q > 0) _sell(bob, id, yes, bb);
        MarketsV4.Market memory m = markets.getMarket(id);
        assertGt(m.yesReserve, 0);
        assertGt(m.noReserve, 0);
        uint256 c = markets.collateralOf(id);
        assertEq(markets.yesBalance(id, alice) + markets.yesBalance(id, bob) + m.yesReserve, c);
        assertEq(markets.noBalance(id, alice) + markets.noBalance(id, bob) + m.noReserve, c);
        assertEq(ledger.balanceOf(address(markets)), c + markets.agentEscrow(id));
    }

    // ───────────── trading windows ─────────────

    function test_noTradeAtOrAfterExpiry_orAfterSettle() public {
        bytes32 id = _market(5e6, 5 minutes);
        uint256 s = _buy(alice, id, true, 1e6);
        vm.warp(_expiry(id));
        vm.prank(alice);
        vm.expectRevert(BinaryMarket.MarketExpired.selector);
        markets.buy(id, BinaryMarket.Outcome.Yes, 1e6, 0, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(BinaryMarket.MarketExpired.selector);
        markets.sell(id, BinaryMarket.Outcome.Yes, s, 0, type(uint256).max);
        _resolve(id, true);
        vm.prank(alice);
        vm.expectRevert(BinaryMarket.NotTrading.selector);
        markets.sell(id, BinaryMarket.Outcome.Yes, s, 0, type(uint256).max);
    }
}
