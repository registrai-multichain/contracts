// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CurveMarket} from "../src/curve/CurveMarket.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract CurveMarketTest is Test {
    CurveMarket cm;
    MockUSDC usdc;

    bytes32 constant MID = keccak256("BTC_5M");
    address resolver = address(0x1E50);
    address treasury = address(0xFEE5);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAC0);

    uint64 opensAt;
    uint64 closesAt;
    uint64 resolveAfter;

    function setUp() public {
        usdc = new MockUSDC();
        cm = new CurveMarket(address(usdc));

        opensAt = uint64(block.timestamp);
        closesAt = uint64(block.timestamp + 5 minutes);
        resolveAfter = uint64(block.timestamp + 6 minutes);

        cm.createMarket(
            MID, keccak256("metric"), keccak256("rules"), resolver, treasury, 5, 2000, 100, opensAt, closesAt, resolveAfter
        );

        for (uint160 i = 0; i < 3; i++) {
            address u = [alice, bob, carol][i];
            usdc.mint(u, 1_000_000e6);
            vm.prank(u);
            usdc.approve(address(cm), type(uint256).max);
        }
    }

    /* ------------------------------------------------------- bucketing math */

    /// Must match the Rust `curve_bucket_for_value` exactly, ties included.
    function test_bucketForValue_matchesReference() public view {
        assertEq(cm.bucketForValue(-1_000_000, 5), 0, "lower bound");
        assertEq(cm.bucketForValue(1_000_000, 5), 4, "upper bound");
        assertEq(cm.bucketForValue(0, 5), 2, "zero -> canonical centre");
        // Exact midpoint between buckets 0 and 1 must round to the HIGHER bucket.
        assertEq(cm.bucketForValue(-750_000, 5), 1, "midpoint ties high");
        assertEq(cm.bucketForValue(-500_000, 5), 1);
        assertEq(cm.bucketForValue(500_000, 5), 3);
    }

    function test_bucketForValue_zeroAlwaysCentre() public view {
        for (uint8 n = 3; n <= 41; n += 2) {
            assertEq(cm.bucketForValue(0, n), (n - 1) / 2, "zero must be the centre bucket");
        }
    }

    function test_weightOf_isFullSupport() public view {
        // bucketCount 5, winner 2: weights 3,4,5,4,3 — every bucket earns something.
        assertEq(cm.weightOf(0, 2, 5), 3);
        assertEq(cm.weightOf(1, 2, 5), 4);
        assertEq(cm.weightOf(2, 2, 5), 5);
        assertEq(cm.weightOf(3, 2, 5), 4);
        assertEq(cm.weightOf(4, 2, 5), 3);
    }

    function test_revert_evenBucketCountRejected() public {
        vm.expectRevert(CurveMarket.InvalidBucketCount.selector);
        cm.createMarket(
            keccak256("x"), keccak256("m"), keccak256("r"), resolver, treasury, 4, 0, 0, opensAt, closesAt, resolveAfter
        );
    }

    /* ------------------------------------------------------------- staking */

    function test_stakeAndWithdrawWhileOpen() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);
        assertEq(cm.stakeOf(MID, 2, alice), 100e6);

        vm.prank(alice);
        cm.withdraw(MID, 2, 40e6);
        assertEq(cm.stakeOf(MID, 2, alice), 60e6);
        assertEq(usdc.balanceOf(address(cm)), 60e6, "contract holds exactly recorded stake");
    }

    function test_revert_withdrawAfterClose() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);

        vm.warp(closesAt + 1);
        vm.prank(alice);
        vm.expectRevert(CurveMarket.MarketClosed.selector);
        cm.withdraw(MID, 2, 1e6);
    }

    function test_revert_stakeAfterClose() public {
        vm.warp(closesAt + 1);
        vm.prank(alice);
        vm.expectRevert(CurveMarket.MarketClosed.selector);
        cm.stake(MID, 2, 1e6);
    }

    /* ------------------------------- selling in the closed-unresolved window */

    /// The headline new capability: exit after close, before settlement.
    function test_sellPositionAfterCloseBeforeSettlement() public {
        vm.prank(alice);
        cm.stake(MID, 3, 100e6);

        vm.warp(closesAt + 1); // withdrawal now impossible

        bytes32 lid = keccak256("listing1");
        vm.prank(alice);
        cm.list(lid, MID, 3, 100e6, 80e6); // asking 80 for a 100 stake

        // Escrowed: alice no longer holds it, and cannot double-sell.
        assertEq(cm.stakeOf(MID, 3, alice), 0);
        assertEq(cm.stakeOf(MID, 3, address(cm)), 100e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(bob);
        cm.buyListing(lid);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 80e6, "alice was paid the ask");
        assertEq(cm.stakeOf(MID, 3, bob), 100e6, "bob owns the position");
        assertEq(cm.stakeOf(MID, 3, address(cm)), 0, "escrow released");
    }

    function test_listingCancelReturnsStake() public {
        vm.prank(alice);
        cm.stake(MID, 1, 50e6);

        bytes32 lid = keccak256("l2");
        vm.prank(alice);
        cm.list(lid, MID, 1, 50e6, 40e6);
        vm.prank(alice);
        cm.cancelListing(lid);

        assertEq(cm.stakeOf(MID, 1, alice), 50e6);
        assertEq(cm.stakeOf(MID, 1, address(cm)), 0);
    }

    /// No trading once the outcome is known.
    function test_revert_buyAfterResolution() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);
        bytes32 lid = keccak256("l3");
        vm.prank(alice);
        cm.list(lid, MID, 2, 100e6, 90e6);

        vm.warp(resolveAfter + 1);
        vm.prank(resolver);
        cm.resolve(MID, 0, keccak256("report"));

        vm.prank(bob);
        vm.expectRevert(CurveMarket.AlreadyResolved.selector);
        cm.buyListing(lid);
    }

    /// An unsold listing must not strand the seller's funds after resolution.
    function test_unsoldListingRecoverableAfterResolution() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);
        bytes32 lid = keccak256("l4");
        vm.prank(alice);
        cm.list(lid, MID, 2, 100e6, 999e6); // priced so nobody buys

        vm.warp(resolveAfter + 1);
        vm.prank(resolver);
        cm.resolve(MID, 0, keccak256("report"));

        vm.prank(alice);
        cm.cancelListing(lid);
        assertEq(cm.stakeOf(MID, 2, alice), 100e6, "seller gets the position back");

        vm.prank(alice);
        uint256 payout = cm.claim(MID, 2);
        assertGt(payout, 0, "and can still claim it");
    }

    function test_transferPositionByOperator() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);
        vm.prank(alice);
        cm.setOperator(bob, true);

        vm.warp(closesAt + 1);
        vm.prank(bob);
        cm.transferPosition(MID, 2, alice, carol, 60e6);

        assertEq(cm.stakeOf(MID, 2, alice), 40e6);
        assertEq(cm.stakeOf(MID, 2, carol), 60e6);
    }

    function test_revert_transferWithoutAuthorisation() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);
        vm.prank(bob);
        vm.expectRevert(CurveMarket.NotAuthorized.selector);
        cm.transferPosition(MID, 2, alice, bob, 1e6);
    }

    /* ---------------------------------------------------------- resolution */

    function test_payoutSplitAndSolvency() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6); // exact bucket
        vm.prank(bob);
        cm.stake(MID, 1, 100e6); // one away
        vm.prank(carol);
        cm.stake(MID, 4, 100e6); // two away

        vm.warp(resolveAfter + 1);
        vm.prank(resolver);
        cm.resolve(MID, 0, keccak256("report")); // outcome 0 -> bucket 2

        (,, uint8 winner,, uint256 pool,,,,) = cm.getMarket(MID);
        assertEq(winner, 2);

        uint256 fee = (300e6 * 100) / 10_000; // 1%
        assertEq(usdc.balanceOf(treasury), fee, "fee paid out");
        assertEq(pool, 300e6 - fee, "pool is post-fee stake");

        vm.prank(alice);
        uint256 pa = cm.claim(MID, 2);
        vm.prank(bob);
        uint256 pb = cm.claim(MID, 1);
        vm.prank(carol);
        uint256 pc = cm.claim(MID, 4);

        assertGt(pa, pb, "exact bucket beats one-away");
        assertGt(pb, pc, "one-away beats two-away");
        assertGt(pc, 0, "full support: even the worst bucket earns something");
        assertLe(pa + pb + pc, pool, "SOLVENT: claims never exceed the pool");
    }

    /// Spraying dust across every bucket must not farm the jackpot.
    function test_jackpotLeverageCapBlocksDustSpray() public {
        // Alice sprays 1 unit in every bucket; Bob puts real size one away.
        vm.startPrank(alice);
        for (uint8 b = 0; b < 5; b++) {
            cm.stake(MID, b, 1);
        }
        vm.stopPrank();
        vm.prank(bob);
        cm.stake(MID, 1, 1_000e6);

        vm.warp(resolveAfter + 1);
        vm.prank(resolver);
        cm.resolve(MID, 0, keccak256("r")); // winner = 2, alice has 1 unit there

        vm.prank(alice);
        uint256 aliceExact = cm.claim(MID, 2);

        // Jackpot for the exact bucket is capped at exactStake * leverage cap (4
        // here, since min(10, bucketCount-1) = 4), so 1 unit cannot capture the
        // full 20% target jackpot of a 1000 USDC pool.
        assertLe(aliceExact, 1 * 4 + 10, "jackpot capped by leverage, not by target");
    }

    function test_invalidRefundsAtPar() public {
        vm.prank(alice);
        cm.stake(MID, 0, 100e6);
        vm.prank(bob);
        cm.stake(MID, 4, 250e6);

        vm.prank(resolver);
        cm.resolveInvalid(MID);

        vm.prank(alice);
        assertEq(cm.claim(MID, 0), 100e6, "1:1 refund");
        vm.prank(bob);
        assertEq(cm.claim(MID, 4), 250e6, "1:1 refund");
        assertEq(usdc.balanceOf(treasury), 0, "no fee on invalid");
    }

    function test_forceInvalidOnlyAfterDelayAndOnlyInvalidates() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);

        vm.warp(resolveAfter + 1);
        vm.expectRevert(CurveMarket.TooEarly.selector);
        cm.forceInvalid(MID);

        vm.warp(uint256(resolveAfter) + cm.RESOLVER_RECOVERY_DELAY() + 1);
        cm.forceInvalid(MID); // permissionless
        vm.prank(alice);
        assertEq(cm.claim(MID, 2), 100e6);
    }

    function test_revert_resolveByNonResolver() public {
        vm.warp(resolveAfter + 1);
        vm.prank(alice);
        vm.expectRevert(CurveMarket.NotResolver.selector);
        cm.resolve(MID, 0, keccak256("r"));
    }

    function test_revert_doubleClaim() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);
        vm.warp(resolveAfter + 1);
        vm.prank(resolver);
        cm.resolve(MID, 0, keccak256("r"));

        vm.prank(alice);
        cm.claim(MID, 2);
        vm.prank(alice);
        vm.expectRevert(CurveMarket.AlreadyClaimed.selector);
        cm.claim(MID, 2);
    }

    /// A donation must not enlarge payouts — liabilities come from recorded stake.
    function test_donationCannotInflatePayouts() public {
        vm.prank(alice);
        cm.stake(MID, 2, 100e6);
        usdc.mint(address(cm), 5_000e6); // unsolicited transfer

        vm.warp(resolveAfter + 1);
        vm.prank(resolver);
        cm.resolve(MID, 0, keccak256("r"));

        vm.prank(alice);
        uint256 payout = cm.claim(MID, 2);
        assertLe(payout, 100e6, "payout bounded by recorded stake, not balance");
    }

    /* ------------------------------------------------------------- fuzzing */

    /// Whatever the stake distribution, total claims must never exceed the pool.
    function testFuzz_solventAcrossAllBuckets(uint256 s0, uint256 s1, uint256 s2, uint256 s3, uint256 s4, int256 outcome)
        public
    {
        uint256[5] memory s;
        s[0] = bound(s0, 0, 1_000_000e6);
        s[1] = bound(s1, 0, 1_000_000e6);
        s[2] = bound(s2, 0, 1_000_000e6);
        s[3] = bound(s3, 0, 1_000_000e6);
        s[4] = bound(s4, 0, 1_000_000e6);
        outcome = bound(outcome, -1_000_000, 1_000_000);

        address[5] memory who = [alice, bob, carol, address(0xD1), address(0xD2)];
        uint256 staked;
        for (uint8 b = 0; b < 5; b++) {
            if (s[b] == 0) continue;
            usdc.mint(who[b], s[b]);
            vm.startPrank(who[b]);
            usdc.approve(address(cm), type(uint256).max);
            cm.stake(MID, b, s[b]);
            vm.stopPrank();
            staked += s[b];
        }
        if (staked == 0) return;

        vm.warp(resolveAfter + 1);
        vm.prank(resolver);
        cm.resolve(MID, outcome, keccak256("r"));

        (,,,, uint256 pool,,,,) = cm.getMarket(MID);
        uint256 total;
        for (uint8 b = 0; b < 5; b++) {
            if (s[b] == 0) continue;
            vm.prank(who[b]);
            total += cm.claim(MID, b);
        }
        assertLe(total, pool, "SOLVENCY INVARIANT: claims <= payout pool");
        // Rounding down can strand a few wei; it must never be material.
        assertGe(total + 100, pool, "no material value stranded");
    }

    /// Selling never changes the pool's accounting — only who owns the claim.
    function testFuzz_saleDoesNotAlterPoolAccounting(uint256 amount, uint256 price) public {
        amount = bound(amount, 1e6, 100_000e6);
        price = bound(price, 1, 100_000e6);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(cm), type(uint256).max);
        cm.stake(MID, 2, amount);
        vm.stopPrank();

        (,,, uint256 stakedBefore,,,,,) = cm.getMarket(MID);

        vm.warp(closesAt + 1);
        bytes32 lid = keccak256("fz");
        vm.prank(alice);
        cm.list(lid, MID, 2, amount, price);
        usdc.mint(bob, price);
        vm.prank(bob);
        cm.buyListing(lid);

        (,,, uint256 stakedAfter,,,,,) = cm.getMarket(MID);
        assertEq(stakedAfter, stakedBefore, "totalStaked untouched by a sale");
        assertEq(cm.stakeOf(MID, 2, bob), amount, "buyer holds the full position");
        assertEq(cm.stakeOf(MID, 2, alice), 0);
    }
}
