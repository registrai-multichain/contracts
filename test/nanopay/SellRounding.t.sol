// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// @notice L1: a sell must round in the protocol's favour. The constant product
/// never decreases on a sell, and the gross paid never exceeds the exact curve
/// amount (while staying within 1 unit of it).
contract SellRoundingTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    NanoLedger ledger;
    MarketsPerennial perennial;
    MarketsV4 v4;

    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address trader = address(0x7A4E);
    bytes32 feedId;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        Dispute dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        BuilderRegistry builders = new BuilderRegistry(address(this));
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, address(this));
        builders.registerFor(address(0xB111), "b1");
        ProgressPool pool = new ProgressPool(ledger, builders, caretakers, address(this), 1 days, 1 hours, address(0x7EA5));
        perennial =
            new MarketsPerennial(ledger, registry, attestation, builders, address(this), address(pool), 1 hours, 1 days);
        v4 = new MarketsV4(ledger, registry, attestation, address(this), address(0x7EA), address(pool), 1 hours, 1 days, 40, 20, 10);
        ledger.setSource(address(v4), true);
        perennial.setApprovedAgent(agent, true);
        perennial.setApprovedResolver(resolver, true);
        v4.setApprovedAgent(agent, true);
        v4.setApprovedResolver(resolver, true);

        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("f", keccak256("m"), 10e6, 1 hours, resolver);
        registry.registerAgent(feedId, keccak256("m"), 100e6);
        vm.stopPrank();

        usdc.mint(trader, 1e18);
        vm.startPrank(trader);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1e15);
        ledger.approveSpender(address(perennial), type(uint256).max);
        ledger.approveSpender(address(v4), type(uint256).max);
        vm.stopPrank();
    }

    /// Exact-curve bounds for a sell that moved post-sell reserves (a, b) by g:
    /// (a-g)(b-g) >= k (never over the curve) and (a-g-2)(b-g-2) < k (tight).
    function _checkSell(uint256 k, uint256 a, uint256 b, uint256 g) internal pure {
        assertGe((a - g) * (b - g), k, "sell paid more than the exact curve amount");
        if (a > g + 2 && b > g + 2) assertLt((a - g - 2) * (b - g - 2), k, "sell underpaid by more than rounding");
        // never above what the old floor-sqrt formula paid, never more than 1 below it
        uint256 s = a + b;
        uint256 disc = s * s - 4 * (a * b - k);
        uint256 old = (s - Math.sqrt(disc)) / 2;
        assertLe(g, old);
        assertGe(g + 1, old);
    }

    function testFuzz_perennial_sellNeverDecreasesK(uint256 liq, uint256 buyIn, uint256 sellFrac, bool yes) public {
        liq = bound(liq, 5e6, 1e12);
        buyIn = bound(buyIn, 1, 1e13);
        sellFrac = bound(sellFrac, 1, 1e18);
        vm.prank(trader);
        bytes32 id = perennial.createMarket(
            1, feedId, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 1 days, liq
        );
        MarketsPerennial.Outcome o = yes ? MarketsPerennial.Outcome.Yes : MarketsPerennial.Outcome.No;
        vm.prank(trader);
        try perennial.buy(id, o, buyIn, 0) returns (uint256 shares) {
            uint256 sellShares = (shares * sellFrac) / 1e18;
            if (sellShares == 0) sellShares = 1;
            MarketsPerennial.Market memory m0 = perennial.getMarket(id);
            uint256 k = m0.yesReserve * m0.noReserve;
            uint256 a = m0.yesReserve + (yes ? sellShares : 0);
            uint256 b = m0.noReserve + (yes ? 0 : sellShares);
            vm.prank(trader);
            try perennial.sell(id, o, sellShares, 0) {
                MarketsPerennial.Market memory m1 = perennial.getMarket(id);
                assertGe(m1.yesReserve * m1.noReserve, k, "k decreased on sell");
                assertGt(m1.yesReserve, 0);
                assertGt(m1.noReserve, 0);
                _checkSell(k, a, b, a - m1.yesReserve);
            } catch {}
        } catch {}
    }

    function testFuzz_v4_sellNeverDecreasesK(uint256 liq, uint256 buyIn, uint256 sellFrac, bool yes) public {
        liq = bound(liq, 5e6, 1e12);
        buyIn = bound(buyIn, 1, 1e13);
        sellFrac = bound(sellFrac, 1, 1e18);
        vm.prank(trader);
        bytes32 id = v4.createMarket(feedId, agent, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 1 days, liq);
        MarketsV4.Outcome o = yes ? MarketsV4.Outcome.Yes : MarketsV4.Outcome.No;
        vm.prank(trader);
        try v4.buy(id, o, buyIn, 0) returns (uint256 shares) {
            uint256 sellShares = (shares * sellFrac) / 1e18;
            if (sellShares == 0) sellShares = 1;
            MarketsV4.Market memory m0 = v4.getMarket(id);
            uint256 k = m0.yesReserve * m0.noReserve;
            uint256 a = m0.yesReserve + (yes ? sellShares : 0);
            uint256 b = m0.noReserve + (yes ? 0 : sellShares);
            vm.prank(trader);
            try v4.sell(id, o, sellShares, 0) {
                MarketsV4.Market memory m1 = v4.getMarket(id);
                assertGe(m1.yesReserve * m1.noReserve, k, "k decreased on sell");
                assertGt(m1.yesReserve, 0);
                assertGt(m1.noReserve, 0);
                _checkSell(k, a, b, a - m1.yesReserve);
            } catch {}
        } catch {}
    }

    /// Many interleaved trades: k is monotone non-decreasing across every sell.
    function testFuzz_perennial_kMonotoneAcrossSells(uint256 seed) public {
        vm.prank(trader);
        bytes32 id = perennial.createMarket(
            1, feedId, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 1 days, 7e6
        );
        for (uint256 i; i < 25; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            MarketsPerennial.Outcome o = r & 1 == 0 ? MarketsPerennial.Outcome.Yes : MarketsPerennial.Outcome.No;
            MarketsPerennial.Market memory m0 = perennial.getMarket(id);
            uint256 k = m0.yesReserve * m0.noReserve;
            if ((r >> 1) % 2 == 0) {
                uint256 bal = o == MarketsPerennial.Outcome.Yes
                    ? perennial.yesBalance(id, trader)
                    : perennial.noBalance(id, trader);
                if (bal == 0) continue;
                vm.prank(trader);
                try perennial.sell(id, o, bound(r >> 8, 1, bal), 0) {} catch {}
            } else {
                vm.prank(trader);
                try perennial.buy(id, o, bound(r >> 8, 1, 50e6), 0) {} catch {}
            }
            MarketsPerennial.Market memory m1 = perennial.getMarket(id);
            assertGe(m1.yesReserve * m1.noReserve, k, "k decreased");
            assertGt(m1.yesReserve, 0);
            assertGt(m1.noReserve, 0);
        }
    }
}
