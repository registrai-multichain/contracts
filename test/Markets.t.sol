// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {Markets} from "../src/Markets.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract MarketsTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    Markets markets;

    address creator = makeAddr("creator");
    address agent = makeAddr("agent");
    address resolver = makeAddr("resolver");
    address marketCreator = makeAddr("marketCreator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    bytes32 constant METHODOLOGY = keccak256("ipfs://methodology");
    bytes32 constant AGENT_METHODOLOGY = keccak256("ipfs://agent-methodology");
    uint256 constant DISPUTE_WINDOW = 1 days;
    uint256 constant MIN_BOND = 100e6;

    bytes32 feedId;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        markets = new Markets(attestation, registry, usdc, treasury);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        // Seed everyone with USDC
        usdc.mint(agent, 10_000e6);
        usdc.mint(marketCreator, 100_000e6);
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        // Set up a feed and an active agent
        vm.prank(creator);
        feedId = registry.createFeed("Warsaw resi PLN/sqm", METHODOLOGY, MIN_BOND, DISPUTE_WINDOW, resolver);
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgent(feedId, AGENT_METHODOLOGY, MIN_BOND);
        vm.stopPrank();
    }

    function _attest(int256 value) internal returns (bytes32 attId) {
        vm.prank(agent);
        attId = attestation.attest(feedId, value, keccak256(abi.encode(value, block.timestamp)));
    }

    function _createMarket(int256 threshold, uint256 expiry, uint256 liquidity)
        internal
        returns (bytes32 marketId)
    {
        vm.startPrank(marketCreator);
        usdc.approve(address(markets), liquidity);
        marketId = markets.createMarket(
            feedId,
            agent,
            threshold,
            Markets.Comparator.GreaterThan,
            expiry,
            liquidity
        );
        vm.stopPrank();
    }

    // --- create ---

    function test_create_initialState() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);
        Markets.Market memory m = markets.getMarket(mid);
        assertEq(m.feedId, feedId);
        assertEq(m.agent, agent);
        assertEq(m.threshold, 17_000);
        assertEq(m.yesReserve, 1000e6);
        assertEq(m.noReserve, 1000e6);
        assertEq(uint8(m.phase), uint8(Markets.Phase.Trading));
        // 50/50 odds at creation
        assertEq(markets.priceOf(mid, Markets.Outcome.Yes), 0.5e18);
        assertEq(markets.priceOf(mid, Markets.Outcome.No), 0.5e18);
    }

    function test_create_revertsBadExpiry() public {
        vm.startPrank(marketCreator);
        usdc.approve(address(markets), 1000e6);
        vm.expectRevert(Markets.BadExpiry.selector);
        markets.createMarket(feedId, agent, 17_000, Markets.Comparator.GreaterThan, block.timestamp, 1000e6);
        vm.stopPrank();
    }

    function test_create_revertsIfAgentNotRegistered() public {
        address rogue = makeAddr("rogue");
        vm.startPrank(marketCreator);
        usdc.approve(address(markets), 100e6);
        vm.expectRevert(Markets.AgentNotRegistered.selector);
        markets.createMarket(
            feedId,
            rogue, // not registered on this feed
            17_000,
            Markets.Comparator.GreaterThan,
            block.timestamp + 1 days,
            100e6
        );
        vm.stopPrank();
    }

    function test_create_revertsLowLiquidity() public {
        uint256 floor = markets.MIN_LIQUIDITY();
        vm.startPrank(marketCreator);
        usdc.approve(address(markets), floor - 1);
        vm.expectRevert(Markets.LiquidityTooLow.selector);
        markets.createMarket(
            feedId,
            agent,
            17_000,
            Markets.Comparator.GreaterThan,
            block.timestamp + 1 days,
            floor - 1
        );
        vm.stopPrank();
    }

    function test_create_uniqueIds() public {
        // Same params, same creator, different nonce → different IDs
        bytes32 a = _createMarket(17_000, block.timestamp + 7 days, 1000e6);
        bytes32 b = _createMarket(17_000, block.timestamp + 7 days, 1000e6);
        assertTrue(a != b);
    }

    // --- buy ---

    function test_buy_yesShares() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(markets), 100e6);
        uint256 shares = markets.buy(mid, Markets.Outcome.Yes, 100e6, 0);
        vm.stopPrank();

        // 100 USDC into a 1000/1000 pool: shares = 1100 - 1000000/1100 ≈ 190.9
        // (ceilDiv on 1_000_000e12 / 1100 means we round down sharesOut slightly)
        assertGt(shares, 100e6); // strictly more than collateral, since pool starts at 50/50
        assertLt(shares, 200e6); // bounded above by 2× collateral
        assertEq(markets.yesBalance(mid, alice), shares);
        assertEq(markets.noBalance(mid, alice), 0);

        // YES became more expensive (price rose above 0.5)
        assertGt(markets.priceOf(mid, Markets.Outcome.Yes), 0.5e18);
    }

    function test_buy_slippageReverts() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(markets), 100e6);
        vm.expectRevert(Markets.SlippageExceeded.selector);
        markets.buy(mid, Markets.Outcome.Yes, 100e6, 200e6);
        vm.stopPrank();
    }

    function test_buy_revertsAfterExpiry() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 1 days, 1000e6);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(alice);
        usdc.approve(address(markets), 100e6);
        vm.expectRevert(Markets.MarketExpired.selector);
        markets.buy(mid, Markets.Outcome.Yes, 100e6, 0);
        vm.stopPrank();
    }

    // --- sell ---

    function test_sell_roundTripsWithFees() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(markets), 100e6);
        uint256 shares = markets.buy(mid, Markets.Outcome.Yes, 100e6, 0);
        uint256 cash = markets.sell(mid, Markets.Outcome.Yes, shares, 0);
        vm.stopPrank();

        // Buy charges 70 bps on the 100 USDC in, sell charges 70 bps on the
        // gross out. Round-trip should return ~98.6 USDC (within rounding).
        assertApproxEqAbs(cash, 98_604_900, 1_000_000);
        // And fees are non-zero on both sides — verify accounting.
        uint256 creatorFees = markets.feeEarnings(marketCreator);
        assertGt(creatorFees, 0);
    }

    function test_fees_paidOnBuy() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);
        uint256 creatorBefore = usdc.balanceOf(marketCreator);
        uint256 agentBefore = usdc.balanceOf(agent);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.startPrank(alice);
        usdc.approve(address(markets), 100e6);
        markets.buy(mid, Markets.Outcome.Yes, 100e6, 0);
        vm.stopPrank();

        // Expect fee = 100e6 * 70 / 10000 = 700_000
        // creator 40bps = 400_000, agent 20bps = 200_000, treasury 10bps = 100_000
        assertEq(usdc.balanceOf(marketCreator) - creatorBefore, 400_000);
        assertEq(usdc.balanceOf(agent) - agentBefore, 200_000);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 100_000);
    }

    function test_sell_insufficientShares() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);
        vm.prank(alice);
        vm.expectRevert(Markets.InsufficientShares.selector);
        markets.sell(mid, Markets.Outcome.Yes, 1, 0);
    }

    // --- resolve ---

    function test_resolve_yesWinsAndRedeems() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 2 days, 1000e6);

        // Alice buys YES
        vm.startPrank(alice);
        usdc.approve(address(markets), 200e6);
        uint256 aliceYes = markets.buy(mid, Markets.Outcome.Yes, 200e6, 0);
        vm.stopPrank();

        // Bob buys NO
        vm.startPrank(bob);
        usdc.approve(address(markets), 200e6);
        markets.buy(mid, Markets.Outcome.No, 200e6, 0);
        vm.stopPrank();

        // Warp to just before expiry, attest a value above the threshold
        vm.warp(block.timestamp + 1 days);
        _attest(17_500);

        // Warp past expiry AND past dispute window (so attestation is finalized)
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        markets.resolve(mid);

        Markets.Market memory m = markets.getMarket(mid);
        assertEq(uint8(m.phase), uint8(Markets.Phase.Resolved));
        assertTrue(m.yesWon);

        // Alice redeems winning YES shares (1 USDC per share)
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = markets.redeem(mid);
        assertEq(payout, aliceYes);
        assertEq(usdc.balanceOf(alice), aliceBalBefore + aliceYes);

        // Bob's NO redeems nothing
        vm.prank(bob);
        vm.expectRevert(Markets.InsufficientShares.selector);
        markets.redeem(mid);
    }

    function test_resolve_noWins() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 2 days, 1000e6);

        vm.warp(block.timestamp + 1 days);
        _attest(16_500); // below threshold

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        markets.resolve(mid);

        Markets.Market memory m = markets.getMarket(mid);
        assertFalse(m.yesWon);
    }

    function test_resolve_revertsBeforeExpiry() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);
        vm.expectRevert(Markets.MarketNotExpired.selector);
        markets.resolve(mid);
    }

    function test_resolve_revertsIfAttestationNotFinalized() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 1 days, 1000e6);

        // Attest right before expiry — attestation won't be finalized yet
        vm.warp(block.timestamp + 1 days - 60);
        _attest(17_500);

        vm.warp(block.timestamp + 60); // past expiry but not past dispute window

        vm.expectRevert(Markets.AttestationNotFinalized.selector);
        markets.resolve(mid);
    }

    function test_resolve_revertsTwice() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 2 days, 1000e6);
        vm.warp(block.timestamp + 1 days);
        _attest(17_500);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        markets.resolve(mid);

        vm.expectRevert(Markets.AlreadyResolved.selector);
        markets.resolve(mid);
    }

    // --- end-to-end solvency: every losing share's collateral funds winning redemption ---

    function test_solvency_marketIsFullyBacked() public {
        bytes32 mid = _createMarket(17_000, block.timestamp + 2 days, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(markets), 500e6);
        uint256 aliceYes = markets.buy(mid, Markets.Outcome.Yes, 500e6, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(markets), 300e6);
        uint256 bobNo = markets.buy(mid, Markets.Outcome.No, 300e6, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        _attest(17_500); // YES wins
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        markets.resolve(mid);

        // With 0.70% fee on buys, alice's 500e6 deposit becomes 496.5e6 entering
        // the pool, and bob's 300e6 becomes 297.9e6. Total minted complete sets
        // = 1000 + 496.5 + 297.9 = 1794.4 USDC of complete sets in circulation
        // (i.e. 1794.4 YES + 1794.4 NO). Test asserts the YES-side accounting.
        Markets.Market memory m = markets.getMarket(mid);
        uint256 outstandingWinningShares = aliceYes + m.yesReserve;
        uint256 unusedLosingShares = bobNo + m.noReserve;
        // Both sides sum to 2 * (sum of effective collateral deposited).
        // 1000 + 500 * 0.993 + 300 * 0.993 = 1794.4. Allow rounding.
        assertApproxEqAbs(
            outstandingWinningShares + unusedLosingShares,
            2 * (1000e6 + (500e6 * 9930) / 10_000 + (300e6 * 9930) / 10_000),
            10
        );

        // Alice redeems winning shares — pool has the USDC to cover.
        vm.prank(alice);
        uint256 payout = markets.redeem(mid);
        assertEq(payout, aliceYes);
        assertGe(usdc.balanceOf(address(markets)), m.yesReserve);
    }
}
