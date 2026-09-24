// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

/// @notice B1: a market's feed must name a governor-approved dispute resolver
/// that is not its own agent, on both market kinds. Perennial additionally
/// requires a governor-approved agent; common markets (V4) are open to any
/// agent registered and active on the feed.
contract OracleAllowlistTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial perennial;
    MarketsV4 v4;
    ProgressPool pool;
    BuilderRegistry builders;

    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address stranger = address(0x5757);
    bytes32 feedId;

    uint256 constant DW = 1 hours;
    uint256 constant WINDOW = 1 hours;
    uint256 constant GRACE = 1 days;

    event AgentApprovalSet(address indexed agent, bool approved);
    event ResolverApprovalSet(address indexed resolver, bool approved);

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, address(this));
        builders.registerFor(address(0xB111), "b1");
        pool = new ProgressPool(ledger, builders, caretakers, address(this), 1 days, 1 hours, address(0x7EA5));
        perennial =
            new MarketsPerennial(ledger, registry, attestation, builders, address(this), address(pool), WINDOW, GRACE);
        v4 = new MarketsV4(ledger, registry, attestation, address(this), address(0x7EA), WINDOW, GRACE);

        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("f", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 100e6);
        vm.stopPrank();

        usdc.mint(creator, 1_000_000e6);
        vm.startPrank(creator);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(perennial), type(uint256).max);
        ledger.approveSpender(address(v4), type(uint256).max);
        vm.stopPrank();
    }

    function _approveBoth(bool on) internal {
        perennial.setApprovedAgent(agent, on);
        perennial.setApprovedResolver(resolver, on);
        v4.setApprovedResolver(resolver, on);
    }

    function _createP() internal returns (bytes32) {
        vm.prank(creator);
        return perennial.createMarket(
            1, feedId, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 100e6
        );
    }

    function _createV4() internal returns (bytes32) {
        vm.prank(creator);
        return v4.createMarket(feedId, agent, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 100e6);
    }

    // ── create is gated ──

    function test_unapprovedAgent_revertsOnPerennial_butV4IsPermissionless() public {
        perennial.setApprovedResolver(resolver, true);
        v4.setApprovedResolver(resolver, true);
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.AgentNotApproved.selector);
        perennial.createMarket(1, feedId, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 100e6);
        // V4 has no agent allowlist: any active registered agent on the feed
        assertTrue(v4.getMarket(_createV4()).createdAt != 0);
    }

    /// V4 still refuses an agent that is not registered and active on the feed.
    function test_v4_unregisteredAgent_reverts() public {
        v4.setApprovedResolver(resolver, true);
        vm.prank(creator);
        vm.expectRevert(MarketsV4.AgentNotRegistered.selector);
        v4.createMarket(feedId, stranger, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 100e6);
        assertFalse(v4.isApprovedFeed(feedId, stranger), "not registered on the feed");
    }

    function test_unapprovedResolver_reverts() public {
        perennial.setApprovedAgent(agent, true);
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.ResolverNotApproved.selector);
        perennial.createMarket(1, feedId, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 100e6);
        vm.prank(creator);
        vm.expectRevert(MarketsV4.ResolverNotApproved.selector);
        v4.createMarket(feedId, agent, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 100e6);
    }

    function test_approvedOracle_creates() public {
        _approveBoth(true);
        assertTrue(perennial.getMarket(_createP()).createdAt != 0);
        assertTrue(v4.getMarket(_createV4()).createdAt != 0);
    }

    /// One address approved as BOTH agent and resolver must still not be able to
    /// open a market on a feed where it adjudicates its own attestations.
    function test_selfResolvedFeed_reverts_evenWhenApprovedOnBothLists() public {
        vm.startPrank(agent);
        bytes32 selfFeed = registry.createFeed("self", keccak256("s"), 10e6, DW, agent);
        registry.registerAgent(selfFeed, keccak256("s"), 100e6);
        vm.stopPrank();
        perennial.setApprovedAgent(agent, true);
        perennial.setApprovedResolver(agent, true);
        v4.setApprovedResolver(agent, true);

        assertFalse(perennial.isApprovedFeed(selfFeed, agent));
        assertFalse(v4.isApprovedFeed(selfFeed, agent));
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.SelfResolvedFeed.selector);
        perennial.createMarket(1, selfFeed, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 100e6);
        vm.prank(creator);
        vm.expectRevert(MarketsV4.SelfResolvedFeed.selector);
        v4.createMarket(selfFeed, agent, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 100e6);
    }

    // ── isApprovedFeed ──

    function test_isApprovedFeed() public {
        assertFalse(perennial.isApprovedFeed(feedId, agent));
        assertFalse(v4.isApprovedFeed(feedId, agent));
        perennial.setApprovedAgent(agent, true);
        assertFalse(perennial.isApprovedFeed(feedId, agent), "resolver still unapproved");
        assertFalse(v4.isApprovedFeed(feedId, agent), "resolver still unapproved");
        perennial.setApprovedResolver(resolver, true);
        v4.setApprovedResolver(resolver, true);
        assertTrue(perennial.isApprovedFeed(feedId, agent));
        assertTrue(v4.isApprovedFeed(feedId, agent));
        assertFalse(perennial.isApprovedFeed(bytes32("missing"), agent), "unknown feed");
        assertFalse(v4.isApprovedFeed(bytes32("missing"), agent), "unknown feed");
        assertFalse(perennial.isApprovedFeed(feedId, stranger), "other agent");
        assertFalse(v4.isApprovedFeed(feedId, stranger), "other agent is not registered on the feed");
    }

    // ── governance ──

    function test_setters_onlyGovernor() public {
        bytes32 role = perennial.GOVERNOR_ROLE();
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        perennial.setApprovedAgent(agent, true);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        perennial.setApprovedResolver(resolver, true);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        v4.setApprovedResolver(resolver, true);
        vm.stopPrank();
    }

    function test_setters_emitAndRejectZero() public {
        vm.expectEmit(true, false, false, true, address(perennial));
        emit AgentApprovalSet(agent, true);
        perennial.setApprovedAgent(agent, true);
        vm.expectEmit(true, false, false, true, address(v4));
        emit ResolverApprovalSet(resolver, true);
        v4.setApprovedResolver(resolver, true);
        vm.expectRevert(MarketsPerennial.ZeroAddress.selector);
        perennial.setApprovedAgent(address(0), true);
        vm.expectRevert(MarketsV4.ZeroAddress.selector);
        v4.setApprovedResolver(address(0), true);
    }

    function test_v4_constructorRejectsZeroAdmin() public {
        vm.expectRevert(MarketsV4.ZeroAddress.selector);
        new MarketsV4(ledger, registry, attestation, address(0), address(0x7EA), WINDOW, GRACE);
    }

    function test_v4_hasNoAgentAllowlist() public {
        (bool ok,) = address(v4).call(abi.encodeWithSignature("setApprovedAgent(address,bool)", agent, true));
        assertFalse(ok, "setApprovedAgent removed from V4");
        (ok,) = address(v4).call(abi.encodeWithSignature("approvedAgent(address)", agent));
        assertFalse(ok, "approvedAgent removed from V4");
    }

    // ── revoking never strands an open market ──

    function test_revoke_existingMarketsStillResolve() public {
        _approveBoth(true);
        bytes32 p = _createP();
        bytes32 q = _createV4();
        _approveBoth(false);
        assertFalse(perennial.isApprovedFeed(feedId, agent));

        vm.warp(block.timestamp + 2 hours);
        vm.prank(agent);
        attestation.attest(feedId, 1, keccak256("v"));
        vm.warp(block.timestamp + DW);
        perennial.resolve(p);
        v4.resolve(q);
        assertTrue(perennial.getMarket(p).yesWon);
        assertTrue(v4.getMarket(q).yesWon);
        // and new markets on the revoked oracle are refused
        uint256 later = vm.getBlockTimestamp() + 2 hours;
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.AgentNotApproved.selector);
        perennial.createMarket(1, feedId, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, later, 100e6);
        vm.prank(creator);
        vm.expectRevert(MarketsV4.ResolverNotApproved.selector);
        v4.createMarket(feedId, agent, 1, MarketsV4.Comparator.GreaterOrEqual, later, 100e6);
    }

    function test_revoke_existingMarketsStillVoid() public {
        _approveBoth(true);
        bytes32 p = _createP();
        bytes32 q = _createV4();
        _approveBoth(false);
        vm.warp(block.timestamp + 2 hours + WINDOW + 1);
        perennial.voidMarket(p);
        v4.voidMarket(q);
        vm.prank(creator);
        perennial.claimLP(p);
        vm.prank(creator);
        v4.claimLP(q);
    }
}
