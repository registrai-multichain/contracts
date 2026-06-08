// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SuffixTreasury} from "../src/suffix/SuffixTreasury.sol";
import {SuffixSenior} from "../src/suffix/SuffixSenior.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// Revenue engine: the protocol-owned AMM + fee skim that ratchets the floor,
/// and the arbitrage that defends the pool price against the redeem floor.
contract SuffixRevenueTest is Test {
    MockUSDC usdc;
    SuffixTreasury t;
    SuffixSenior senior;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        t = new SuffixTreasury(usdc, owner);
        senior = t.senior();
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(owner, 1_000_000e6);
    }

    function _seedSenior(address who, uint256 amt) internal {
        vm.startPrank(who);
        usdc.approve(address(t), amt);
        t.seedSenior(amt);
        vm.stopPrank();
    }

    function _provisionPOL(uint256 u, uint256 ai) internal {
        usdc.approve(address(t), u);
        t.provisionPOL(u, ai);
    }

    // ── pool senior is treasury-owned → excluded from the senior claim ──
    function test_polExcludedFromClaim() public {
        _seedSenior(alice, 1_000e6);
        assertEq(t.seniorClaimUSDC(), 1_000e6);

        _provisionPOL(1_000e6, 1_000e6);              // price 1.0
        assertEq(t.aiSpotPrice(), 1e6);
        assertEq(senior.totalSupply(), 2_000e6);      // 1000 external + 1000 pool
        assertEq(t.externalSeniorSupply(), 1_000e6);  // pool excluded
        assertEq(t.seniorClaimUSDC(), 1_000e6);       // claim unchanged by POL
    }

    // ── buying $ai banks a fee and turns pool $ai into an external claim ──
    function test_buyAi_banksFee_raisesClaim() public {
        _provisionPOL(1_000e6, 1_000e6);
        uint256 priceBefore = t.aiSpotPrice();

        vm.startPrank(alice);
        usdc.approve(address(t), 100e6);
        uint256 aiOut = t.buyAi(100e6, 0);
        vm.stopPrank();

        assertEq(senior.balanceOf(alice), aiOut);
        assertEq(t.feesBankUsdc(), (100e6 * 30) / 10_000);   // 0.30%
        assertEq(t.externalSeniorSupply(), aiOut);           // now a claim
        assertGt(t.aiSpotPrice(), priceBefore);              // price moved up
    }

    // ── selling $ai banks a fee too ──
    function test_sellAi_banksFee() public {
        _provisionPOL(1_000e6, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(t), 100e6);
        uint256 aiOut = t.buyAi(100e6, 0);
        uint256 feeAfterBuy = t.feesBankUsdc();
        senior.approve(address(t), aiOut);
        uint256 usdcOut = t.sellAi(aiOut, 0);
        vm.stopPrank();
        assertGt(usdcOut, 0);
        assertGt(t.feesBankUsdc(), feeAfterBuy);             // sell added another fee
        assertEq(t.externalSeniorSupply(), 0);               // $ai returned to pool
    }

    // ── the revenue transmission: churn → fees → a higher floor ──
    function test_skimRatchetsFloor() public {
        _seedSenior(alice, 1_000e6);
        _provisionPOL(1_000e6, 1_000e6);
        uint256 floorBefore = t.floorPar();

        // generate fees with a round-trip
        vm.startPrank(bob);
        usdc.approve(address(t), 200e6);
        uint256 got = t.buyAi(200e6, 0);
        senior.approve(address(t), got);
        t.sellAi(got, 0);
        vm.stopPrank();

        uint256 fees = t.feesBankUsdc();
        assertGt(fees, 0);
        uint256 reserveBefore = t.totalUSDC();

        t.skimRevenueToFloor(t.BPS());                       // all to senior floor
        assertEq(t.feesBankUsdc(), 0);
        assertEq(t.totalUSDC(), reserveBefore + fees);       // fees → reserve
        assertGt(t.floorPar(), floorBefore);                 // floor ratcheted up
    }

    // ── arbitrage defends the floor: a pool below the redeem floor is a free
    //    profit (buy cheap from pool → redeem at floor), which pushes price up.
    //    So no front-runnable keeper order is needed to defend the band. ──
    function test_arbitrageDefendsFloor() public {
        _seedSenior(alice, 1_000e6);                 // reserve 1000 to honor redeems
        _provisionPOL(500e6, 1_000e6);               // pool price 0.5 < floor 0.9

        uint256 before = usdc.balanceOf(bob);
        vm.startPrank(bob);
        usdc.approve(address(t), 100e6);
        uint256 aiOut = t.buyAi(100e6, 0);           // buy cheap (~0.6 avg)
        uint256 redeemed = t.redeemSeniorAtFloor(aiOut); // redeem at 0.9
        vm.stopPrank();

        assertGt(redeemed, 100e6);                   // profit ⇒ arb exists
        assertGt(usdc.balanceOf(bob), before);       // bob ended up ahead
        assertGt(t.aiSpotPrice(), 0.5e6);            // and the buy pushed price up
    }
}
