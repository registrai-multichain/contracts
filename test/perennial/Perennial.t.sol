// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// Full Perennial loop: fees from a builder market flow to the commons
/// (ProgressPool), progress is recorded per builder, the epoch closes, and
/// builders claim a progress-weighted share. Ledger solvency holds throughout.
contract PerennialTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    ProgressPool pool;
    BuilderRegistry builderReg;
    CaretakerRegistry caretakers;

    address oracle = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address taker = address(0x7A4E);
    address builderA = address(0xB111);
    address builderB = address(0xB222);
    bytes32 feedId;
    uint256 constant DW = 1 hours;
    uint256 constant EPOCH = 1 days;
    uint256 constant WINDOW = 1 days;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builderReg = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builderReg, address(this));
        builderReg.registerFor(builderA, "ipfs://a");
        builderReg.registerFor(builderB, "ipfs://b");
        pool = new ProgressPool(ledger, builderReg, caretakers, address(this), EPOCH, WINDOW);
        pool.grantRole(pool.PROGRESS_ROLE(), address(this)); // direct unit-test writer
        markets = new MarketsPerennial(ledger, registry, attestation, builderReg, address(this), address(pool), 1 hours, 1 days);

        usdc.mint(oracle, 1_000e6);
        vm.startPrank(oracle);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("BTC", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 10e6);
        vm.stopPrank();

        _fund(creator);
        _fund(taker);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
    }

    function _market() internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(
            1,
            feedId,
            oracle,
            int256(100_000),
            MarketsPerennial.Comparator.GreaterOrEqual,
            block.timestamp + 2 hours,
            10e6
        );
    }

    // ── BuilderRegistry ──

    function test_builderRegistry() public {
        assertEq(builderReg.builderIdOf(builderA), 1);
        assertFalse(builderReg.isUniqueBuilder(builderA));
        vm.prank(builderA);
        builderReg.linkIdentity(hex"01");
        assertTrue(builderReg.isUniqueBuilder(builderA));
        vm.prank(builderA);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        builderReg.registerBuilder("ipfs://dup");
    }

    function test_inactiveBuilderCannotReceiveProgressOrMarkets() public {
        builderReg.setActive(1, false);
        vm.expectRevert(ProgressPool.BuilderInactive.selector);
        pool.addProgress(builderA, 1);
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.BuilderInactive.selector);
        markets.createMarket(
            1, feedId, oracle, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 1 days, 10e6
        );
    }

    // ── fees flow to the commons, not to the builder the market is about ──

    function test_marketFees_fundTheCommons() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // fee 14, commons 7
        assertEq(ledger.balanceOf(address(pool)), 7e6, "commons funded by market fee");
        assertEq(pool.pendingPot(), 7e6);
        _solvent();
    }

    // ── full distribution loop ──

    function test_progress_distribution() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // commons gets 7 USDC

        // keeper records verified progress: builderA weight 3, builderB weight 1
        pool.addProgress(builderA, 3);
        pool.addProgress(builderB, 1);
        assertEq(pool.totalWeight(0), 4);

        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();
        assertEq(pool.epochPot(0), 7e6, "pot snapshotted");

        uint256 a = pool.claimFor(0, builderA);
        uint256 b = pool.claimFor(0, builderB);
        assertEq(a, 525e4, "A share 3/4 of 7 USDC");
        assertEq(b, 175e4, "B share 1/4 of 7 USDC");
        // funds stream, not lump: nothing withdrawable yet
        assertEq(ledger.balanceOf(builderA), 0, "no instant credit");

        uint256 idA = pool.streamIdOf(0, builderA);
        uint256 idB = pool.streamIdOf(0, builderB);
        vm.warp(pool.epochStart() + 2 * WINDOW);
        ledger.settleStream(idA);
        ledger.settleStream(idB);
        assertEq(ledger.balanceOf(builderA), 525e4, "A fully streamed");
        assertEq(ledger.balanceOf(builderB), 175e4, "B fully streamed");
        _solvent();

        vm.expectRevert(ProgressPool.AlreadyClaimed.selector);
        pool.claimFor(0, builderA);
        vm.expectRevert(ProgressPool.NoProgress.selector);
        pool.claimFor(0, taker);
    }

    function test_claimFor_creditsBuilderNotCaller() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // commons 7

        pool.addProgress(builderA, 3);
        pool.addProgress(builderB, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();

        address caretaker = address(0xCA4E);
        vm.prank(caretaker);
        uint256 a = pool.claimFor(0, builderA);
        assertEq(a, 525e4, "A share");
        uint256 streamId = pool.streamIdOf(0, builderA);
        (, address to,, uint256 cap,,,) = ledger.streams(streamId);
        assertEq(to, builderA, "stream pays the builder");
        assertEq(cap, 525e4, "stream cap = share");
        assertEq(ledger.balanceOf(caretaker), 0, "caretaker got nothing");
        vm.warp(pool.epochStart() + 2 * WINDOW);
        ledger.settleStream(streamId);
        assertEq(ledger.balanceOf(builderA), 525e4, "builder credited after settle");
        _solvent();
    }

    function test_claimFor_doubleClaimReverts() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0);
        pool.addProgress(builderA, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();

        pool.claimFor(0, builderA);
        vm.expectRevert(ProgressPool.AlreadyClaimed.selector);
        pool.claimFor(0, builderA);
    }

    function test_claimFor_noProgressReverts() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0);
        pool.addProgress(builderA, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();

        vm.expectRevert(ProgressPool.NoProgress.selector);
        pool.claimFor(0, builderB); // B had no weight
    }

    function test_claim_beforeCloseReverts() public {
        pool.addProgress(builderA, 1);
        vm.prank(builderA);
        vm.expectRevert(ProgressPool.EpochNotClosed.selector);
        pool.claim(0);
    }

    function test_closeEpoch_noProgressRollsOver() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // commons 7
        // no progress this epoch
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();
        assertEq(pool.epochPot(0), 0, "nothing allocated");
        assertEq(pool.pendingPot(), 7e6, "funds roll into next epoch");
        _solvent();
    }

    function test_closeEpoch_beforeEnd_reverts() public {
        vm.expectRevert(ProgressPool.EpochNotOver.selector);
        pool.closeEpoch();
    }

    function test_claimFor_partialSettle() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0);
        pool.addProgress(builderA, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();

        pool.claimFor(0, builderA); // share = 7e6
        uint256 streamId = pool.streamIdOf(0, builderA);
        vm.warp(pool.epochStart() + WINDOW / 2);
        ledger.settleStream(streamId);
        uint256 half = ledger.balanceOf(builderA);
        assertApproxEqAbs(half, 35e5, 1e5, "about half streamed at half window");
        _solvent();
    }

    function test_pendingPot_unchangedByClaim() public {
        bytes32 id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0);
        pool.addProgress(builderA, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();
        uint256 before = pool.pendingPot();
        pool.claimFor(0, builderA);
        assertEq(pool.pendingPot(), before, "opening a stream does not change pendingPot");
    }

    function test_setStreamWindow_governed() public {
        pool.setStreamWindow(2 days);
        assertEq(pool.streamWindow(), 2 days);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        pool.setStreamWindow(3 days);
        vm.expectRevert(ProgressPool.ZeroWindow.selector);
        pool.setStreamWindow(0);
    }
}
