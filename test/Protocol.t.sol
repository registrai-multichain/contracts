// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract ProtocolTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;

    address creator = makeAddr("creator");
    // v2 rule: feed creator and agent are the same wallet. Tests reflect that
    // by aliasing agent to creator. A separate non-creator wallet is used
    // by test_registerAgent_revertsOnNonCreator to verify the guard.
    address agent = creator;
    address nonCreator = makeAddr("nonCreator");
    address resolver = makeAddr("resolver");
    address challenger = makeAddr("challenger");
    address challenger2 = makeAddr("challenger2");

    bytes32 constant METHODOLOGY = keccak256("ipfs://methodology");
    bytes32 constant AGENT_METHODOLOGY = keccak256("ipfs://agent-methodology");
    uint256 constant DISPUTE_WINDOW = 1 days;
    uint256 constant MIN_BOND = 100e6;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        usdc.mint(agent, 10_000e6);
        usdc.mint(nonCreator, 10_000e6);
        usdc.mint(challenger, 10_000e6);
        usdc.mint(challenger2, 10_000e6);
    }

    function _createFeed() internal returns (bytes32 feedId) {
        vm.prank(creator);
        feedId = registry.createFeed("Warsaw resi PLN/sqm", METHODOLOGY, MIN_BOND, DISPUTE_WINDOW, resolver);
    }

    function _registerAgent(bytes32 feedId, address who, uint256 bond) internal {
        vm.startPrank(who);
        usdc.approve(address(registry), bond);
        registry.registerAgent(feedId, AGENT_METHODOLOGY, bond);
        vm.stopPrank();
    }

    function _attest(bytes32 feedId, int256 value, bytes32 inputHash) internal returns (bytes32 attId) {
        vm.prank(agent);
        attId = attestation.attest(feedId, value, inputHash);
    }

    function _challenge(bytes32 attId, address who) internal returns (bytes32 disputeId) {
        Registry.Agent memory a = registry.getAgent(attestation.getAttestation(attId).feedId, agent);
        uint256 available = a.bond - a.lockedBond;
        vm.startPrank(who);
        usdc.approve(address(dispute), available);
        disputeId = dispute.challenge(attId, keccak256("evidence"));
        vm.stopPrank();
    }

    // --- Registry ---

    function test_createFeed() public {
        bytes32 feedId = _createFeed();
        Registry.Feed memory f = registry.getFeed(feedId);
        assertEq(f.creator, creator);
        assertEq(f.minBond, MIN_BOND);
        assertEq(f.disputeWindow, DISPUTE_WINDOW);
        assertEq(f.resolver, resolver);
        assertTrue(f.exists);
    }

    function test_createFeed_revertsOnLowBond() public {
        uint256 floor = registry.MIN_BOND();
        vm.prank(creator);
        vm.expectRevert(Registry.BondTooLow.selector);
        registry.createFeed("x", METHODOLOGY, floor - 1, DISPUTE_WINDOW, resolver);
    }

    function test_createFeed_revertsOnBadWindow() public {
        vm.prank(creator);
        vm.expectRevert(Registry.BadDisputeWindow.selector);
        registry.createFeed("x", METHODOLOGY, MIN_BOND, 30 minutes, resolver);

        vm.prank(creator);
        vm.expectRevert(Registry.BadDisputeWindow.selector);
        registry.createFeed("x", METHODOLOGY, MIN_BOND, 8 days, resolver);
    }

    function test_createFeed_revertsOnZeroResolver() public {
        vm.prank(creator);
        vm.expectRevert(Registry.BadResolver.selector);
        registry.createFeed("x", METHODOLOGY, MIN_BOND, DISPUTE_WINDOW, address(0));
    }

    function test_registerAgent() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        Registry.Agent memory a = registry.getAgent(feedId, agent);
        assertEq(a.bond, MIN_BOND);
        assertTrue(a.active);
        assertEq(usdc.balanceOf(address(registry)), MIN_BOND);
    }

    function test_registerAgent_revertsTwice() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        vm.expectRevert(Registry.AlreadyRegistered.selector);
        registry.registerAgent(feedId, AGENT_METHODOLOGY, MIN_BOND);
        vm.stopPrank();
    }

    function test_registerAgent_revertsLowBond() public {
        bytes32 feedId = _createFeed();
        // Feed's minBond is MIN_BOND (set in _createFeed). Try bonding below that.
        uint256 low = MIN_BOND - 1;
        vm.startPrank(agent);
        usdc.approve(address(registry), low);
        vm.expectRevert(Registry.BondTooLow.selector);
        registry.registerAgent(feedId, AGENT_METHODOLOGY, low);
        vm.stopPrank();
    }

    function test_registerAgent_revertsOnNonCreator() public {
        bytes32 feedId = _createFeed();
        vm.startPrank(nonCreator);
        usdc.approve(address(registry), MIN_BOND);
        vm.expectRevert(Registry.NotFeedCreator.selector);
        registry.registerAgent(feedId, AGENT_METHODOLOGY, MIN_BOND);
        vm.stopPrank();
    }

    function test_registerAgent_revertsMissingFeed() public {
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        vm.expectRevert(Registry.FeedMissing.selector);
        registry.registerAgent(bytes32("nope"), AGENT_METHODOLOGY, MIN_BOND);
        vm.stopPrank();
    }

    function test_topUpBond() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        vm.startPrank(agent);
        usdc.approve(address(registry), 50e6);
        registry.topUpBond(feedId, 50e6);
        vm.stopPrank();
        assertEq(registry.getAgent(feedId, agent).bond, MIN_BOND + 50e6);
    }

    function test_withdrawBond_blockedByCooldown() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        vm.prank(agent);
        vm.expectRevert(Registry.CooldownActive.selector);
        registry.withdrawBond(feedId);
    }

    function test_withdrawBond_afterCooldown() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 balBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        registry.withdrawBond(feedId);
        assertEq(usdc.balanceOf(agent), balBefore + MIN_BOND);
        assertFalse(registry.getAgent(feedId, agent).active);
    }

    /// @notice Critical: agent cannot drain bond while a dispute is pending.
    function test_withdrawBond_blockedByPendingDispute() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("a"));
        _challenge(attId, challenger);

        // Even after the cooldown, the locked bond prevents withdrawal.
        vm.warp(block.timestamp + 30 days);
        vm.prank(agent);
        vm.expectRevert(Registry.BondLockedByDispute.selector);
        registry.withdrawBond(feedId);
    }

    function test_wire_onlyOnce() public {
        vm.expectRevert(Registry.AlreadyWired.selector);
        registry.wire(address(1), address(2));
    }

    // --- Attestation ---

    function test_attest() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("inputs"));
        Attestation.AttestationData memory att = attestation.getAttestation(attId);
        assertEq(att.value, 15000);
        assertEq(att.agent, agent);
        assertEq(att.finalizedAt, block.timestamp + DISPUTE_WINDOW);
    }

    function test_attest_revertsIfInactive() public {
        bytes32 feedId = _createFeed();
        vm.prank(agent);
        vm.expectRevert(Attestation.AgentInactive.selector);
        attestation.attest(feedId, 15000, keccak256("x"));
    }

    /// @notice Two attestations in the same block with same value but different inputHash
    /// must produce different attestation IDs (no silent overwrite).
    function test_attest_uniqueByInputHash() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        // Top up so available bond covers two attestations.
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.topUpBond(feedId, MIN_BOND);
        vm.stopPrank();

        bytes32 id1 = _attest(feedId, 15000, keccak256("a"));
        bytes32 id2 = _attest(feedId, 15000, keccak256("b"));
        assertTrue(id1 != id2);
    }

    /// @notice An agent whose entire bond is locked by a pending dispute cannot attest again
    /// (otherwise they could spam bad attestations cheaply).
    function test_attest_revertsWhenAllBondLocked() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("a"));
        _challenge(attId, challenger);

        vm.prank(agent);
        vm.expectRevert(Attestation.InsufficientAvailableBond.selector);
        attestation.attest(feedId, 16000, keccak256("b"));
    }

    function test_latestValue_finalization() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        _attest(feedId, 15000, keccak256("x"));

        (int256 v,, bool fin) = attestation.latestValue(feedId, agent);
        assertEq(v, 15000);
        assertFalse(fin);

        vm.warp(block.timestamp + DISPUTE_WINDOW);
        (,, fin) = attestation.latestValue(feedId, agent);
        assertTrue(fin);
    }

    function test_valueAt_walksHistory() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, 2 * MIN_BOND);

        // Pin timestamps explicitly. via_ir is aggressive about folding
        // repeated `block.timestamp` reads into one local, so we drive the
        // EVM clock with vm.warp and use the same literal we warped to.
        uint256 t1 = 1_000_000;
        vm.warp(t1);
        _attest(feedId, 15000, keccak256("a"));

        uint256 t2 = t1 + 1 days;
        vm.warp(t2);
        _attest(feedId, 16000, keccak256("b"));

        (int256 v1,) = attestation.valueAt(feedId, agent, t1);
        (int256 v2,) = attestation.valueAt(feedId, agent, t2);
        assertEq(v1, 15000);
        assertEq(v2, 16000);
    }

    // --- Dispute ---

    function test_challenge_setsPendingAndLocks() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("x"));
        _challenge(attId, challenger);

        assertEq(uint8(attestation.getAttestation(attId).status), uint8(Attestation.DisputeStatus.Pending));
        assertFalse(attestation.isFinalized(attId));
        assertEq(registry.getAgent(feedId, agent).lockedBond, MIN_BOND);
    }

    function test_challenge_revertsAfterWindow() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("x"));
        vm.warp(block.timestamp + DISPUTE_WINDOW);
        vm.startPrank(challenger);
        usdc.approve(address(dispute), MIN_BOND);
        vm.expectRevert(Dispute.WindowClosed.selector);
        dispute.challenge(attId, keccak256("e"));
        vm.stopPrank();
    }

    function test_challenge_revertsIfAlreadyChallenged() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("x"));
        _challenge(attId, challenger);
        vm.startPrank(challenger2);
        usdc.approve(address(dispute), MIN_BOND);
        vm.expectRevert(Dispute.AlreadyChallenged.selector);
        dispute.challenge(attId, keccak256("e"));
        vm.stopPrank();
    }

    function test_resolve_valid_rewardsAgentFullBond() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("x"));
        bytes32 disputeId = _challenge(attId, challenger);

        uint256 agentBalBefore = usdc.balanceOf(agent);
        vm.prank(resolver);
        dispute.resolve(disputeId, Dispute.DisputeOutcome.AttestationValid);

        // Agent gets the FULL challenger bond, not just half.
        assertEq(usdc.balanceOf(agent), agentBalBefore + MIN_BOND);
        // Agent's own bond unlocked and untouched.
        Registry.Agent memory a = registry.getAgent(feedId, agent);
        assertEq(a.bond, MIN_BOND);
        assertEq(a.lockedBond, 0);
        // Attestation finalizes immediately on Valid (no need to wait for finalizedAt).
        assertTrue(attestation.isFinalized(attId));
        assertEq(
            uint8(attestation.getAttestation(attId).status), uint8(Attestation.DisputeStatus.ResolvedValid)
        );
    }

    function test_resolve_invalid_slashesAgent() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 99999, keccak256("x"));
        bytes32 disputeId = _challenge(attId, challenger);

        uint256 challengerBalBefore = usdc.balanceOf(challenger);
        vm.prank(resolver);
        dispute.resolve(disputeId, Dispute.DisputeOutcome.AttestationInvalid);

        // Challenger gets posted bond back + slashed amount (== posted bond) = 2× MIN_BOND.
        assertEq(usdc.balanceOf(challenger), challengerBalBefore + 2 * MIN_BOND);
        Registry.Agent memory a = registry.getAgent(feedId, agent);
        assertEq(a.bond, 0);
        assertEq(a.lockedBond, 0);
        assertFalse(a.active);
        assertTrue(a.slashed);
        vm.warp(block.timestamp + 365 days);
        assertFalse(attestation.isFinalized(attId));
    }

    function test_resolve_onlyResolver() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("x"));
        bytes32 disputeId = _challenge(attId, challenger);

        vm.expectRevert(Dispute.NotResolver.selector);
        dispute.resolve(disputeId, Dispute.DisputeOutcome.AttestationValid);
    }

    function test_latestValue_skipsInvalidated() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, 2 * MIN_BOND);
        // First attestation is good.
        _attest(feedId, 15000, keccak256("a"));
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        // Second attestation gets invalidated.
        bytes32 bad = _attest(feedId, 99999, keccak256("b"));
        bytes32 d = _challenge(bad, challenger);
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);

        (int256 v,, bool fin) = attestation.latestValue(feedId, agent);
        assertEq(v, 15000);
        assertTrue(fin);
    }

    function test_slashedAgent_cannotReactivateViaTopUp() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 99999, keccak256("x"));
        bytes32 disputeId = _challenge(attId, challenger);
        vm.prank(resolver);
        dispute.resolve(disputeId, Dispute.DisputeOutcome.AttestationInvalid);

        // Slashed agent tries to top up back to minBond.
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.topUpBond(feedId, MIN_BOND);
        vm.stopPrank();

        Registry.Agent memory a = registry.getAgent(feedId, agent);
        assertEq(a.bond, MIN_BOND);
        // Stays inactive — terminal.
        assertFalse(a.active);

        // And cannot attest.
        vm.prank(agent);
        vm.expectRevert(Attestation.AgentInactive.selector);
        attestation.attest(feedId, 15000, keccak256("y"));
    }

    function test_lockBond_onlyDispute() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        vm.expectRevert(Registry.NotAuthorized.selector);
        registry.lockBond(feedId, agent, 1);
    }

    function test_slash_onlyDispute() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        vm.expectRevert(Registry.NotAuthorized.selector);
        registry.slash(feedId, agent, 1, address(this));
    }

    function test_setStatus_onlyDispute() public {
        bytes32 feedId = _createFeed();
        _registerAgent(feedId, agent, MIN_BOND);
        bytes32 attId = _attest(feedId, 15000, keccak256("x"));
        vm.expectRevert(Attestation.NotAuthorized.selector);
        attestation.setStatus(attId, Attestation.DisputeStatus.Pending);
    }

    function test_recordAttestation_onlyAttestation() public {
        bytes32 feedId = _createFeed();
        vm.expectRevert(Registry.NotAuthorized.selector);
        registry.recordAttestation(feedId, agent);
    }
}
