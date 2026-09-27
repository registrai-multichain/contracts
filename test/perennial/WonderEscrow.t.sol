// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../src/perennial/WonderEscrow.sol";
import {SourceKey} from "../../src/perennial/SourceKey.sol";
import {FundKit} from "./FundKit.sol";
import {MarketsKit} from "./MarketsKit.sol";

contract WonderEscrowTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    BuilderFund fund;
    SeasonPool pool;
    VerifiedBuilderBadge badge;
    WonderEscrow escrow;

    address markets = address(0x3A2); // stands in for MarketsPerennial (MARKETS_ROLE)
    address operator = address(0x0FE2); // RELEASER_ROLE
    address team = address(0x7EA3);
    address squatter = address(0x5A7);
    string constant SRC = "github:acme/tool";
    bytes32 KEY = keccak256(bytes(SRC));
    uint256 constant EXPIRY = 180 days;
    uint256 constant EPOCH = 1 days;

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), EPOCH);
        badge = MarketsKit.deployBadge(builders);
        escrow = new WonderEscrow(ledger, fund, badge, address(this), EXPIRY);
        escrow.grantRole(escrow.MARKETS_ROLE(), markets);
        escrow.grantRole(escrow.RELEASER_ROLE(), operator);
        FundKit.wire(fund, address(escrow)); // release credits the fund, sweep the season pool
        usdc.mint(markets, 1_000_000e6);
        vm.startPrank(markets);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000_000e6);
        vm.stopPrank();
    }

    function _credit(uint256 amount) internal {
        vm.startPrank(markets);
        ledger.internalTransfer(address(escrow), amount);
        escrow.credit(KEY, amount);
        vm.stopPrank();
    }

    function test_creditAccumulates() public {
        _credit(10e6);
        _credit(5e6);
        assertEq(escrow.escrowOf(KEY), 15e6);
        assertEq(escrow.totalEscrow(), 15e6);
        assertEq(escrow.firstCreditAt(KEY), block.timestamp);
    }

    function test_creditOnlyMarkets() public {
        vm.expectRevert();
        escrow.credit(KEY, 1);
    }

    function test_creditUnfundedReverts() public {
        vm.prank(markets);
        vm.expectRevert(WonderEscrow.Unfunded.selector);
        escrow.credit(KEY, 1e6); // nothing transferred first
    }

    function test_releaseAfterDelay() public {
        _credit(100e6);
        (uint256 id, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.expectRevert(WonderEscrow.NotReady.selector);
        escrow.executeRelease(KEY);
        vm.warp(block.timestamp + 7 days);
        escrow.executeRelease(KEY);
        assertEq(escrow.escrowOf(KEY), 0);
        assertEq(escrow.totalEscrow(), 0);
        assertEq(escrow.releasedTo(KEY), id);
        assertEq(fund.incomeOf(fund.currentEpoch(), id), 100e6);
        // later credits go straight to the builder's income
        _credit(7e6);
        assertEq(escrow.escrowOf(KEY), 0);
        assertEq(fund.incomeOf(fund.currentEpoch(), id), 107e6);
    }

    function test_queueRequiresMatchingActiveProjectAndLiveBadge() public {
        _credit(1e6);
        (, uint256 otherProject) = MarketsKit.onboard(builders, badge, squatter, "github:other/thing");
        vm.prank(operator);
        vm.expectRevert(WonderEscrow.ProjectMismatch.selector);
        escrow.queueRelease(SRC, otherProject);
        // a registered project with the right source but no badge
        uint256 bare = builders.registerFor(address(0xBA2E), "");
        uint256 p = builders.addProjectFor(bare, SRC);
        vm.prank(operator);
        vm.expectRevert(WonderEscrow.BuilderNotLive.selector);
        escrow.queueRelease(SRC, p);
    }

    function test_queueOnlyReleaser() public {
        (, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.expectRevert();
        escrow.queueRelease(SRC, projectId);
    }

    function test_rejectsNonCanonical() public {
        (, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.prank(operator);
        vm.expectRevert(SourceKey.NotCanonical.selector);
        escrow.queueRelease("github:Acme/Tool", projectId);
    }

    function test_safeCancels() public {
        _credit(50e6);
        (, uint256 projectId) = MarketsKit.onboard(builders, badge, squatter, SRC); // a squatter's project
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        escrow.cancelRelease(KEY); // the test contract is the Safe (GOVERNOR)
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(WonderEscrow.NotReady.selector);
        escrow.executeRelease(KEY);
        assertEq(escrow.escrowOf(KEY), 50e6);
    }

    function test_executeRechecksBuilder() public {
        _credit(50e6);
        (uint256 id, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        builders.setActive(id, false);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(WonderEscrow.BuilderNotLive.selector);
        escrow.executeRelease(KEY);
        assertEq(escrow.escrowOf(KEY), 50e6);
    }

    function test_executeRechecksLapsedBadge() public {
        _credit(50e6);
        (uint256 id, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        badge.setLapsed(id, true);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(WonderEscrow.BuilderNotLive.selector);
        escrow.executeRelease(KEY);
    }

    event Swept(bytes32 indexed key, uint256 toSeason, uint256 toTreasury);

    /// Owner decision 2026-09-27: unclaimed escrow is taxed 10% to the protocol
    /// treasury (the fund's PROTOCOL_TREASURY), 90% to the season pool.
    function test_sweepAfterExpiry_90PctToSeasonPool_10PctToTreasury() public {
        _credit(40e6);
        vm.expectRevert(WonderEscrow.NotExpired.selector);
        escrow.sweep(KEY);
        vm.warp(block.timestamp + EXPIRY);
        address treasury = fund.PROTOCOL_TREASURY();
        uint256 poolBefore = ledger.balanceOf(address(pool));
        uint256 treasuryBefore = ledger.balanceOf(treasury);
        vm.expectEmit(true, false, false, true);
        emit Swept(KEY, 36e6, 4e6);
        escrow.sweep(KEY);
        assertEq(escrow.escrowOf(KEY), 0);
        assertEq(escrow.firstCreditAt(KEY), 0);
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 36e6);
        assertEq(ledger.balanceOf(treasury) - treasuryBefore, 4e6);
        assertEq(escrow.totalEscrow(), 0);
        // a later credit starts a fresh clock
        _credit(3e6);
        assertEq(escrow.firstCreditAt(KEY), block.timestamp);
    }

    function test_sweepRoundsTheTreasuryTaxDown_theSeasonPoolGetsTheRest() public {
        _credit(19); // 1.9 base units of tax -> 1
        vm.warp(block.timestamp + EXPIRY);
        uint256 poolBefore = ledger.balanceOf(address(pool));
        uint256 treasuryBefore = ledger.balanceOf(fund.PROTOCOL_TREASURY());
        escrow.sweep(KEY);
        assertEq(ledger.balanceOf(fund.PROTOCOL_TREASURY()) - treasuryBefore, 1);
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 18);
    }

    function test_pendingReleaseBlocksSweep() public {
        _credit(40e6);
        (, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.warp(block.timestamp + EXPIRY);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.expectRevert(WonderEscrow.ReleasePending.selector);
        escrow.sweep(KEY);
    }

    // ── final-review minors ──

    function test_releaserMayDropAStaleQueue() public {
        _credit(10e6);
        (, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.prank(operator);
        escrow.cancelRelease(KEY);
        (,, uint64 readyAt) = escrow.pendingRelease(KEY);
        assertEq(readyAt, 0);
        vm.prank(squatter);
        vm.expectRevert(WonderEscrow.NotAuthorized.selector);
        escrow.cancelRelease(KEY);
    }

    function test_cancelWithNothingPendingSaysSo() public {
        vm.expectRevert(WonderEscrow.NoPendingRelease.selector);
        escrow.cancelRelease(KEY);
    }

    function test_governorUndoesAWrongRelease() public {
        _credit(10e6);
        (uint256 id, uint256 projectId) = MarketsKit.onboard(builders, badge, squatter, SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.warp(block.timestamp + 7 days);
        escrow.executeRelease(KEY);
        assertEq(escrow.releasedTo(KEY), id);
        vm.prank(operator);
        vm.expectRevert();
        escrow.unrelease(KEY);
        escrow.unrelease(KEY); // the test contract is the Safe
        assertEq(escrow.releasedTo(KEY), 0);
        _credit(3e6); // new fees wait in escrow again
        assertEq(escrow.escrowOf(KEY), 3e6);
        vm.expectRevert(WonderEscrow.NotReleased.selector);
        escrow.unrelease(KEY);
    }
}
