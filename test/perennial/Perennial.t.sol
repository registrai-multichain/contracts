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

/// Full Perennial loop: the commons leg of a builder market's trading fees flows
/// to the commons (ProgressPool), progress is recorded per builder, the epoch closes,
/// and builders claim a progress-weighted share, minus the 1% protocol fee.
/// Ledger solvency holds throughout.
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
    uint256 constant A_ID = 1; // builderA's id
    uint256 constant B_ID = 2; // builderB's id
    address protocolTreasury = address(0x7EA5);
    bytes32 feedId;
    uint256 constant DW = 1 hours;
    uint256 constant EPOCH = 1 days;
    uint256 constant WINDOW = 1 days;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builderReg = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builderReg, address(this));
        builderReg.registerFor(builderA, "ipfs://a");
        builderReg.registerFor(builderB, "ipfs://b");
        pool = new ProgressPool(ledger, builderReg, caretakers, address(this), EPOCH, WINDOW, protocolTreasury);
        pool.grantRole(pool.PROGRESS_ROLE(), address(this)); // direct unit-test writer
        markets = new MarketsPerennial(ledger, registry, attestation, builderReg, address(this), address(pool), 1 hours, 1 days);
        markets.setApprovedAgent(oracle, true);
        markets.setApprovedResolver(resolver, true);

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

    /// A settled market: 2000 bought -> trading fee 20, commons 10.
    function _fundCommons() internal returns (bytes32 id) {
        id = _market();
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0);
        vm.warp(markets.getMarket(id).expiry + 1);
        vm.prank(oracle);
        attestation.attest(feedId, int256(123_456), bytes32("ih"));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
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
        pool.addProgress(A_ID, 1);
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
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // fee 20, commons 10
        assertEq(ledger.balanceOf(address(pool)), 10e6, "commons funded by the trading fee");
        vm.warp(markets.getMarket(id).expiry + 1);
        vm.prank(oracle);
        attestation.attest(feedId, int256(123_456), bytes32("ih"));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertEq(ledger.balanceOf(address(pool)), 10e6, "nothing more charged at settlement");
        assertEq(pool.pendingPot(), 10e6);
        _solvent();
    }

    // ── full distribution loop ──

    function test_progress_distribution() public {
        _fundCommons(); // commons gets 10 USDC

        // keeper records verified progress: builderA weight 3, builderB weight 1
        pool.addProgress(A_ID, 3);
        pool.addProgress(B_ID, 1);
        assertEq(pool.totalWeight(0), 4);

        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();
        assertEq(pool.epochPot(0), 10e6, "pot snapshotted");
        assertEq(pool.claimable(0, A_ID), 7_425e3, "claimable is net of the 1% protocol fee");

        uint256 a = pool.claimFor(0, A_ID);
        uint256 b = pool.claimFor(0, B_ID);
        assertEq(a, 7_425e3, "A share 3/4 of 10 USDC, minus 1%");
        assertEq(b, 2_475e3, "B share 1/4 of 10 USDC, minus 1%");
        assertEq(ledger.balanceOf(protocolTreasury), 100e3, "1% of 10 USDC to the protocol treasury");
        // funds stream, not lump: nothing withdrawable yet
        assertEq(ledger.balanceOf(builderA), 0, "no instant credit");

        uint256 idA = pool.streamIdOf(0, A_ID);
        uint256 idB = pool.streamIdOf(0, B_ID);
        vm.warp(pool.epochStart() + 2 * WINDOW);
        ledger.settleStream(idA);
        ledger.settleStream(idB);
        assertEq(ledger.balanceOf(builderA), 7_425e3, "A fully streamed");
        assertEq(ledger.balanceOf(builderB), 2_475e3, "B fully streamed");
        _solvent();

        vm.expectRevert(ProgressPool.AlreadyClaimed.selector);
        pool.claimFor(0, A_ID);
        vm.expectRevert(ProgressPool.NoProgress.selector);
        pool.claimFor(0, 99);
    }

    function test_claimFor_creditsBuilderNotCaller() public {
        _fundCommons(); // commons 10

        pool.addProgress(A_ID, 3);
        pool.addProgress(B_ID, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();

        address caretaker = address(0xCA4E);
        vm.prank(caretaker);
        uint256 a = pool.claimFor(0, A_ID);
        assertEq(a, 7_425e3, "A share, net");
        uint256 streamId = pool.streamIdOf(0, A_ID);
        (, address to,, uint256 cap,,,) = ledger.streams(streamId);
        assertEq(to, builderA, "stream pays the builder");
        assertEq(cap, 7_425e3, "stream cap = share minus the protocol fee");
        assertEq(ledger.balanceOf(caretaker), 0, "caretaker got nothing");
        vm.warp(pool.epochStart() + 2 * WINDOW);
        ledger.settleStream(streamId);
        assertEq(ledger.balanceOf(builderA), 7_425e3, "builder credited after settle");
        _solvent();
    }

    function test_claimFor_doubleClaimReverts() public {
        _fundCommons();
        pool.addProgress(A_ID, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();

        pool.claimFor(0, A_ID);
        vm.expectRevert(ProgressPool.AlreadyClaimed.selector);
        pool.claimFor(0, A_ID);
    }

    function test_claimFor_noProgressReverts() public {
        _fundCommons();
        pool.addProgress(A_ID, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();

        vm.expectRevert(ProgressPool.NoProgress.selector);
        pool.claimFor(0, B_ID); // B had no weight
    }

    function test_claim_beforeCloseReverts() public {
        pool.addProgress(A_ID, 1);
        vm.prank(builderA);
        vm.expectRevert(ProgressPool.EpochNotClosed.selector);
        pool.claim(0);
    }

    function test_closeEpoch_noProgressRollsOver() public {
        _fundCommons(); // commons 10
        // no progress this epoch
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();
        assertEq(pool.epochPot(0), 0, "nothing allocated");
        assertEq(pool.pendingPot(), 10e6, "funds roll into next epoch");
        _solvent();
    }

    function test_closeEpoch_beforeEnd_reverts() public {
        vm.expectRevert(ProgressPool.EpochNotOver.selector);
        pool.closeEpoch();
    }

    function test_claimFor_partialSettle() public {
        _fundCommons();
        pool.addProgress(A_ID, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();

        pool.claimFor(0, A_ID); // share 10e6, streams 9.9e6
        uint256 streamId = pool.streamIdOf(0, A_ID);
        vm.warp(pool.epochStart() + WINDOW / 2);
        ledger.settleStream(streamId);
        uint256 half = ledger.balanceOf(builderA);
        assertApproxEqAbs(half, 495e4, 1e5, "about half streamed at half window");
        _solvent();
    }

    function test_pendingPot_unchangedByClaim() public {
        _fundCommons();
        pool.addProgress(A_ID, 1);
        vm.warp(block.timestamp + EPOCH + 1);
        pool.closeEpoch();
        uint256 before = pool.pendingPot();
        pool.claimFor(0, A_ID);
        assertEq(pool.pendingPot(), before, "opening a stream (and paying the fee) does not change pendingPot");
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
