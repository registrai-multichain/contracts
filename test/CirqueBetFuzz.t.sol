// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {MarketsV3} from "../src/MarketsV3.sol";
import {Markets} from "../src/Markets.sol";
import {CirqueBetLending} from "../src/CirqueBetLending.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice Adversarial fuzz of the spot-mark manipulation attack against the
/// REAL contracts. For randomized (pool depth, manipulation size, position
/// size), an attacker:
///   1. seeds/holds a YES position,
///   2. buys NO to spike the YES spot mark,
///   3. borrows USDC against the (now-inflated) position,
///   4. unwinds the NO leg,
///   5. defaults (never repays) — gets liquidated.
/// INVARIANT: the lending pool's USDC value must never decrease as a result
/// (suppliers never lose). i.e. attacker's net USDC out ≤ what they put in,
/// OR liquidation fully covers the debt. If the depth-cap design is sound,
/// the fuzzer cannot find a profitable drain.
contract CirqueBetFuzzTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    MarketsV3 markets;
    CirqueBetLending lending;

    address creator = makeAddr("creator");
    address agent = creator;
    address resolver = makeAddr("resolver");
    address lola = makeAddr("lola");          // honest supplier
    address attacker = makeAddr("attacker");
    address liquidator = makeAddr("liquidator");

    bytes32 constant METH = keccak256("m");
    uint256 constant DW = 1 days;
    uint256 constant MIN_BOND = 100e6;
    bytes32 feedId;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        markets = new MarketsV3(attestation, registry, usdc, makeAddr("treasury"));
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        lending = new CirqueBetLending(usdc, markets, address(this), 1000e6);

        usdc.mint(agent, 1_000e6);
        vm.prank(creator);
        feedId = registry.createFeed("f", METH, MIN_BOND, DW, resolver);
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgent(feedId, METH, MIN_BOND);
        vm.stopPrank();
    }

    /// @param seedLiq   pool liquidity per side (bounded into eligible + thin-ish range)
    /// @param manipBps  attacker's NO-buy size as a fraction of pool depth
    /// @param posSpend  attacker's YES position size (the collateral)
    function testFuzz_spotMarkAttack_cannotDrainPool(
        uint256 seedLiq,
        uint256 manipBps,
        uint256 posSpend
    ) public {
        // Bound to realistic-but-adversarial ranges. Include depths right at
        // the eligibility gate and well above it.
        seedLiq = bound(seedLiq, 1_000e6, 200_000e6);
        manipBps = bound(manipBps, 0, 50_000);     // 0–500% of depth in manipulation spend
        posSpend = bound(posSpend, 1e6, 50_000e6);

        // Honest supplier funds the pool generously so borrow liquidity is
        // never the limiter (we're testing solvency, not utilisation).
        uint256 poolUSDC = 500_000e6;
        usdc.mint(lola, poolUSDC);
        vm.startPrank(lola);
        usdc.approve(address(lending), poolUSDC);
        lending.supplyUSDC(poolUSDC);
        vm.stopPrank();
        uint256 poolValueBefore = lending.totalPoolValueUSDC();

        // Create an eligible market (long expiry so no force-close interference).
        usdc.mint(creator, seedLiq * 2);
        vm.startPrank(creator);
        usdc.approve(address(markets), seedLiq);
        bytes32 mid = markets.createMarket(
            feedId, agent, 17_000, Markets.Comparator.GreaterThan, block.timestamp + 30 days, seedLiq
        );
        vm.stopPrank();

        // Attacker buys a YES position (the collateral).
        usdc.mint(attacker, posSpend + (manipBps * seedLiq) / 10_000 + 10e6);
        // Snapshot the attacker's liquid USDC the instant before they act. The
        // core invariant below is that this can only go DOWN: a manipulate →
        // over-borrow → default round-trip must not let them walk away with more
        // cash than they started with (they forfeit the pledged collateral on
        // default, so any net USDC gain would be extracted supplier value).
        uint256 attackerStartBal = usdc.balanceOf(attacker);
        vm.startPrank(attacker);
        usdc.approve(address(markets), type(uint256).max);
        uint256 yesShares = markets.buy(mid, Markets.Outcome.Yes, posSpend, 0);
        markets.setShareOperator(address(lending), true);

        // Manipulate: buy NO to spike the YES spot mark.
        uint256 manipSpend = (manipBps * seedLiq) / 10_000;
        uint256 noShares = 0;
        if (manipSpend > 0) {
            noShares = markets.buy(mid, Markets.Outcome.No, manipSpend, 0);
        }

        // Try to borrow the max the (manipulated) mark allows.
        uint256 want = lending.maxBorrow(mid, true, yesShares);
        bool borrowed;
        if (want > 0) {
            try lending.borrowAgainstBet(mid, true, yesShares, want) {
                borrowed = true;
            } catch {
                borrowed = false;
            }
        }

        // Unwind the manipulation leg (recover NO value).
        if (noShares > 0) {
            try markets.sell(mid, Markets.Outcome.No, noShares, 0) {} catch {}
        }
        vm.stopPrank();

        if (borrowed) {
            // Attacker defaults. A RATIONAL liquidator only acts when the live
            // collateral covers what they must pay (owed) — they will NOT pay
            // owed for sub-owed collateral. This models the real incentive
            // rather than an altruistic backstop that masks losses.
            (, , , uint256 principal, , ,) = lending.loans(attacker);
            uint256 owed = principal + lending.interestOwed(attacker);
            uint256 cv = lending.collateralValueUSDC(attacker);
            if (cv >= owed) {
                usdc.mint(liquidator, owed + 1e6);
                vm.startPrank(liquidator);
                usdc.approve(address(lending), owed + 1e6);
                try lending.liquidateBet(attacker) {} catch {}
                vm.stopPrank();
            }
        }

        // PRIMARY INVARIANT: the manipulate→borrow→default round-trip is not
        // profitable. The attacker forfeited the pledged collateral, so if they
        // ended with MORE liquid USDC than they started with, they extracted
        // supplier funds. (Holds even when no liquidator acts — it's about what
        // the attacker could borrow vs. what they irreversibly gave up.)
        assertLe(
            usdc.balanceOf(attacker),
            attackerStartBal,
            "ATTACKER PROFITED: manipulation extracted supplier value"
        );

        // SECONDARY: with a rational liquidator, the pool's accounted value is
        // not dragged below where it started by the attack itself (any residual
        // is bounded, honest lending loss recognized via writeOffBadDebt — not
        // tested here since this market never resolves).
        uint256 poolValueAfter = lending.totalPoolValueUSDC();
        assertGe(
            poolValueAfter,
            poolValueBefore,
            "POOL DRAINED: attacker extracted supplier value"
        );
    }
}
