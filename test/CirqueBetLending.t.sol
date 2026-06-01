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

contract CirqueBetLendingTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    MarketsV3 markets;
    CirqueBetLending lending;

    address creator = makeAddr("creator");
    address agent = creator;
    address resolver = makeAddr("resolver");
    address mm = makeAddr("mm");
    address alice = makeAddr("alice");   // borrower (holds a bet)
    address lola = makeAddr("lola");     // USDC supplier
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

        lending = new CirqueBetLending(usdc, markets, address(this));

        usdc.mint(agent, 10_000e6);
        usdc.mint(mm, 5_000_000e6);
        usdc.mint(alice, 100_000e6);
        usdc.mint(lola, 1_000_000e6);
        usdc.mint(liquidator, 100_000e6);

        vm.prank(creator);
        feedId = registry.createFeed("f", METH, MIN_BOND, DW, resolver);
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgent(feedId, METH, MIN_BOND);
        vm.stopPrank();

        // Supplier seeds 50,000 USDC (markets are 50k-deep post-gate, so the
        // pool must be able to fund borrows against them).
        vm.startPrank(lola);
        usdc.approve(address(lending), 50_000e6);
        lending.supplyUSDC(50_000e6);
        vm.stopPrank();
    }

    // Seed well above MIN_POOL_DEPTH (1,000 USDC) so both reserves stay
    // eligible after trading — the depth gate is a borrow-time requirement.
    function _market(uint256 expiry) internal returns (bytes32 mid) {
        vm.startPrank(mm);
        usdc.approve(address(markets), 50_000e6);
        mid = markets.createMarket(feedId, agent, 17_000, Markets.Comparator.GreaterThan, expiry, 50_000e6);
        vm.stopPrank();
    }

    // Alice buys a YES position and approves the lending contract as operator.
    function _aliceHoldsBet(bytes32 mid, uint256 spend) internal returns (uint256 sh) {
        vm.startPrank(alice);
        usdc.approve(address(markets), spend);
        sh = markets.buy(mid, Markets.Outcome.Yes, spend, 0);
        markets.setShareOperator(address(lending), true);
        vm.stopPrank();
    }

    // ── borrow against a held bet ──
    function test_borrowAgainstBet_locksPositionLendsUSDC() public {
        bytes32 mid = _market(block.timestamp + 30 days);
        uint256 sh = _aliceHoldsBet(mid, 200e6);

        uint256 markV = lending.maxBorrow(mid, true, sh) * 2; // mark = 2× maxBorrow (50% LTV)
        uint256 borrow = lending.maxBorrow(mid, true, sh) / 2; // borrow well under max
        assertGt(markV, 0);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 health = lending.borrowAgainstBet(mid, true, sh, borrow);

        // collateral now held by lending contract, not alice
        assertEq(markets.yesBalance(mid, address(lending)), sh);
        assertEq(markets.yesBalance(mid, alice), 0);
        // USDC delivered
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, borrow);
        // health < 50% (we borrowed half the max)
        assertLt(health, lending.MAX_LTV_BPS());

        (bytes32 lm,, uint256 ls, uint256 lp,, bool active,) = lending.loans(alice);
        assertEq(lm, mid); assertEq(ls, sh); assertEq(lp, borrow); assertTrue(active);
    }

    function test_borrow_aboveMaxLtv_reverts() public {
        bytes32 mid = _market(block.timestamp + 30 days);
        uint256 sh = _aliceHoldsBet(mid, 200e6);
        uint256 tooMuch = lending.maxBorrow(mid, true, sh) + 10e6;
        vm.prank(alice);
        vm.expectRevert(CirqueBetLending.LTVTooHigh.selector);
        lending.borrowAgainstBet(mid, true, sh, tooMuch);
    }

    function test_borrow_inForceCloseWindow_reverts() public {
        bytes32 mid = _market(block.timestamp + 1 hours); // expiry < FORCE_CLOSE_WINDOW away
        uint256 sh = _aliceHoldsBet(mid, 200e6);
        vm.prank(alice);
        vm.expectRevert(CirqueBetLending.MarketResolvedOrExpired.selector);
        lending.borrowAgainstBet(mid, true, sh, 10e6);
    }

    // ── repay returns the position ──
    function test_repay_returnsPosition() public {
        bytes32 mid = _market(block.timestamp + 30 days);
        uint256 sh = _aliceHoldsBet(mid, 200e6);
        uint256 borrow = lending.maxBorrow(mid, true, sh) / 2;
        vm.prank(alice);
        lending.borrowAgainstBet(mid, true, sh, borrow);

        vm.warp(block.timestamp + 30 days); // accrue interest
        uint256 owed = borrow + lending.interestOwed(alice);
        vm.startPrank(alice);
        usdc.approve(address(lending), owed);
        lending.repayBet();
        vm.stopPrank();

        assertEq(markets.yesBalance(mid, alice), sh); // got it back
        (,,,,, bool active,) = lending.loans(alice);
        assertFalse(active);
    }

    // ── health-based liquidation when the mark drops ──
    function test_liquidate_whenMarkDrops() public {
        bytes32 mid = _market(block.timestamp + 30 days);
        uint256 sh = _aliceHoldsBet(mid, 200e6);
        uint256 borrow = lending.maxBorrow(mid, true, sh); // borrow at exactly 50% LTV
        vm.prank(alice);
        lending.borrowAgainstBet(mid, true, sh, borrow);

        // Push YES price down: a big NO buy moves the mark against alice's YES.
        vm.startPrank(mm);
        usdc.approve(address(markets), 80_000e6);
        markets.buy(mid, Markets.Outcome.No, 80_000e6, 0);
        vm.stopPrank();

        // Health should now breach the 60% threshold.
        assertGt(lending.healthBps(alice), lending.LIQ_LTV_BPS());

        uint256 owed = borrow + lending.interestOwed(alice);
        vm.startPrank(liquidator);
        usdc.approve(address(lending), owed + 1e6);
        lending.liquidateBet(alice);
        vm.stopPrank();

        // Loan cleared; collateral split between liquidator (≈owed×1.05 worth)
        // and borrower (surplus). Whole position is accounted for, none stuck
        // in the lending contract.
        uint256 liqGot = markets.yesBalance(mid, liquidator);
        uint256 aliceGot = markets.yesBalance(mid, alice);
        assertGt(liqGot, 0);
        assertEq(liqGot + aliceGot, sh);
        assertEq(markets.yesBalance(mid, address(lending)), 0);
        (,,,,, bool active,) = lending.loans(alice);
        assertFalse(active);
    }

    function test_liquidate_healthyLoan_reverts() public {
        bytes32 mid = _market(block.timestamp + 30 days);
        uint256 sh = _aliceHoldsBet(mid, 200e6);
        uint256 borrow = lending.maxBorrow(mid, true, sh) / 2; // safe
        vm.prank(alice);
        lending.borrowAgainstBet(mid, true, sh, borrow);

        vm.startPrank(liquidator);
        usdc.approve(address(lending), 1_000e6);
        vm.expectRevert(CirqueBetLending.NotLiquidatable.selector);
        lending.liquidateBet(alice);
        vm.stopPrank();
    }

    // ── THE CLIFF GUARD: force-liquidatable in the expiry window regardless
    //    of health, so no position survives into resolution ──
    function test_forceLiquidate_inExpiryWindow_evenIfHealthy() public {
        uint256 expiry = block.timestamp + 30 days;
        bytes32 mid = _market(expiry);
        uint256 sh = _aliceHoldsBet(mid, 200e6);
        uint256 borrow = lending.maxBorrow(mid, true, sh) / 2; // very healthy
        vm.prank(alice);
        lending.borrowAgainstBet(mid, true, sh, borrow);

        // Healthy right now — normal liquidation must fail.
        vm.startPrank(liquidator);
        usdc.approve(address(lending), 1_000e6);
        vm.expectRevert(CirqueBetLending.NotLiquidatable.selector);
        lending.liquidateBet(alice);
        vm.stopPrank();

        // Warp into the force-close window (< 2h before expiry). Now anyone
        // can liquidate regardless of health — the cliff guard.
        vm.warp(expiry - 1 hours);
        vm.startPrank(liquidator);
        usdc.approve(address(lending), 1_000e6);
        lending.liquidateBet(alice);
        vm.stopPrank();

        // FIX #3: a HEALTHY borrower force-closed near expiry keeps their
        // upside — the liquidator takes only ≈(owed×1.05) worth, the borrower
        // gets the rest back. Since this loan was very healthy (borrowed half
        // the max → ~20% LTV), the borrower's surplus should be the majority.
        uint256 liqGot = markets.yesBalance(mid, liquidator);
        uint256 aliceGot = markets.yesBalance(mid, alice);
        assertEq(liqGot + aliceGot, sh);          // whole position accounted for
        assertGt(aliceGot, liqGot);               // borrower keeps the majority
        (,,,,, bool active,) = lending.loans(alice);
        assertFalse(active);
    }

    // ── FIX #2/#3: liquidating an in-the-money position pays the liquidator a
    //    real bonus (the force-close incentive) and returns surplus to borrower ──
    function test_liquidation_paysBonus_returnsSurplus() public {
        bytes32 mid = _market(block.timestamp + 30 days);
        uint256 sh = _aliceHoldsBet(mid, 2_000e6); // sizeable position
        uint256 borrow = lending.maxBorrow(mid, true, sh) / 2; // healthy, ~20% LTV
        vm.prank(alice);
        lending.borrowAgainstBet(mid, true, sh, borrow);

        // Force-window liquidation of a healthy, in-the-money position.
        // (use the mark-drop path to make it liquidatable now)
        vm.startPrank(mm);
        usdc.approve(address(markets), 80_000e6);
        markets.buy(mid, Markets.Outcome.No, 80_000e6, 0);
        vm.stopPrank();
        // health breached but collateral still worth more than owed×1.05
        uint256 owed = borrow + lending.interestOwed(alice);

        vm.startPrank(liquidator);
        usdc.approve(address(lending), owed + 1e6);
        lending.liquidateBet(alice);
        vm.stopPrank();

        // Liquidator received a positive share allocation (their bonus is the
        // incentive that makes force-close self-executing); borrower got the
        // surplus; nothing stranded.
        uint256 liqGot = markets.yesBalance(mid, liquidator);
        uint256 aliceGot = markets.yesBalance(mid, alice);
        assertGt(liqGot, 0);
        assertEq(liqGot + aliceGot, sh);
        assertEq(markets.yesBalance(mid, address(lending)), 0);
    }

    // ── REGRESSION (re-review HIGH): a liquidator cannot crash the spot price
    //    in the same tx to over-seize the borrower's surplus. The split is
    //    sized off markValueAtBorrow (fixed at origination), not live priceOf,
    //    so manipulation does not change how many shares the liquidator gets.
    //    Under the old spot-based sizing the liquidator took the WHOLE position;
    //    here the borrower keeps essentially the same surplus either way. ──
    function test_liquidator_cannotManipulateSpot_toStealSurplus() public {
        uint256 expiry = block.timestamp + 30 days;
        bytes32 mid = _market(expiry);
        uint256 sh = _aliceHoldsBet(mid, 2_000e6);
        uint256 borrow = lending.maxBorrow(mid, true, sh) / 2; // healthy, ~20% LTV
        vm.prank(alice);
        lending.borrowAgainstBet(mid, true, sh, borrow);

        // Enter the force-close window (health check bypassed — the path where
        // the old bug let a liquidator seize a healthy borrower's whole upside).
        vm.warp(expiry - 1 hours);
        uint256 owed = borrow + lending.interestOwed(alice); // after accrual

        // Liquidator ATTACKS: dump a large NO buy to crash the YES spot price
        // toward zero, then immediately force-liquidate.
        vm.startPrank(liquidator);
        usdc.approve(address(markets), 90_000e6);
        markets.buy(mid, Markets.Outcome.No, 90_000e6, 0);
        // spot YES price is crashed far below its fair ~0.5 (a 4×+ swing — under
        // the old spot-based sizing this alone gave the liquidator the whole
        // position, since liquidatorShares = reward × 1e18 / price balloons).
        assertLt(markets.priceOf(mid, Markets.Outcome.Yes), 0.2e18);
        usdc.approve(address(lending), owed + 1e6);
        lending.liquidateBet(alice);
        vm.stopPrank();

        // The borrower STILL keeps the majority of the position — the crashed
        // spot did not inflate the liquidator's cut. (Sized off markValueAtBorrow
        // at ~20% LTV: liquidator ≈ owed×1.05 worth, borrower keeps the rest.)
        uint256 liqGot = markets.yesBalance(mid, liquidator);
        uint256 aliceGot = markets.yesBalance(mid, alice);
        assertEq(liqGot + aliceGot, sh);
        assertGt(aliceGot, liqGot);                 // borrower keeps the majority
        assertGt(aliceGot, (sh * 60) / 100);        // and it's a real surplus (>60%)
    }

    // ── pool invariant: supplier yield after a repay ──
    function test_supplierEarnsYield() public {
        bytes32 mid = _market(block.timestamp + 60 days);
        uint256 sh = _aliceHoldsBet(mid, 200e6);
        uint256 borrow = lending.maxBorrow(mid, true, sh) / 2;
        vm.prank(alice);
        lending.borrowAgainstBet(mid, true, sh, borrow);

        vm.warp(block.timestamp + 365 days);
        uint256 owed = borrow + lending.interestOwed(alice);
        vm.startPrank(alice);
        usdc.approve(address(lending), owed);
        lending.repayBet();
        vm.stopPrank();

        // Lola's claim grew by the interest (she's the only supplier).
        assertGt(lending.balanceOfUSDC(lola), 50_000e6);
    }

    function test_doubleBorrow_reverts() public {
        bytes32 mid = _market(block.timestamp + 30 days);
        uint256 sh = _aliceHoldsBet(mid, 200e6);
        uint256 borrow = lending.maxBorrow(mid, true, sh) / 4;
        vm.startPrank(alice);
        lending.borrowAgainstBet(mid, true, sh / 2, borrow);
        vm.expectRevert(CirqueBetLending.ActiveLoanExists.selector);
        lending.borrowAgainstBet(mid, true, sh / 4, borrow);
        vm.stopPrank();
    }
}
