// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Registry} from "./Registry.sol";
import {Attestation} from "./Attestation.sol";

/// @title Dispute
/// @notice Optimistic-oracle challenge flow with per-feed resolvers and symmetric stakes.
contract Dispute {
    using SafeERC20 for IERC20;

    enum DisputeOutcome {
        Pending,
        AttestationValid,
        AttestationInvalid
    }

    struct DisputeData {
        bytes32 attestationId;
        address challenger;
        uint256 challengerBond;
        bytes32 evidenceHash;
        uint256 openedAt;
        address resolver;
        DisputeOutcome outcome;
        /// The agent bond this dispute holds locked: min(stake, the agent's free
        /// bond at the challenge), possibly 0. An Invalid ruling slashes exactly this.
        uint256 lockedBond;
    }

    Registry public immutable REGISTRY;
    Attestation public immutable ATTESTATION;
    IERC20 public immutable USDC;

    mapping(bytes32 => DisputeData) internal _disputes;
    mapping(bytes32 => bytes32) public disputeOf;

    event Challenged(
        bytes32 indexed disputeId,
        bytes32 indexed attestationId,
        address indexed challenger,
        uint256 bond,
        bytes32 evidenceHash
    );
    event Resolved(bytes32 indexed disputeId, DisputeOutcome outcome);

    error AttestationMissing();
    error WindowClosed();
    error AlreadyChallenged();
    error AgentCannotChallenge();
    error DisputeMissing();
    error NotResolver();
    error AlreadyResolved();
    error BadOutcome();

    constructor(Registry registry_, Attestation attestation_, IERC20 usdc) {
        REGISTRY = registry_;
        ATTESTATION = attestation_;
        USDC = usdc;
    }

    function challenge(bytes32 attestationId, bytes32 evidenceHash) external returns (bytes32 disputeId) {
        Attestation.AttestationData memory att = ATTESTATION.getAttestation(attestationId);
        if (att.timestamp == 0) revert AttestationMissing();
        if (block.timestamp >= att.finalizedAt) revert WindowClosed();
        if (disputeOf[attestationId] != bytes32(0)) revert AlreadyChallenged();
        // The agent disputing its own reading would pre-empt an honest challenger
        // (AlreadyChallenged) and collect its own slash. Defence in depth only: it
        // can use another address; what protects the market is that ANY challenge
        // is accepted and makes the reading Pending (below).
        if (msg.sender == att.agent) revert AgentCannotChallenge();

        Registry.Feed memory f = REGISTRY.getFeed(att.feedId);
        uint256 available = REGISTRY.availableBond(att.feedId, att.agent);

        // A challenge is ALWAYS accepted, whatever the agent has free: a wrong
        // reading must never be shielded by an exhausted bond (audit 2026-09-27
        // H-1: the agent locked its own bond by challenging throwaway readings, so
        // every challenge of its wrong reading reverted and the reading settled the
        // market). The challenger stakes the feed's `minBond`; the agent's bond is
        // locked up to the same amount as far as it is free - possibly 0. An
        // Invalid ruling slashes exactly what was locked and deactivates the agent
        // on the feed either way; the reading is Pending until the ruling, which is
        // what keeps a market from settling on it. Locking no more than minBond
        // leaves the rest of the agent's bond free for its other attestations.
        uint256 stake = f.minBond;
        uint256 locked = available < stake ? available : stake;
        USDC.safeTransferFrom(msg.sender, address(this), stake);
        if (locked > 0) REGISTRY.lockBond(att.feedId, att.agent, locked);

        disputeId = keccak256(abi.encode(attestationId, msg.sender, block.timestamp));
        _disputes[disputeId] = DisputeData({
            attestationId: attestationId,
            challenger: msg.sender,
            challengerBond: stake,
            evidenceHash: evidenceHash,
            openedAt: block.timestamp,
            resolver: f.resolver,
            outcome: DisputeOutcome.Pending,
            lockedBond: locked
        });
        disputeOf[attestationId] = disputeId;

        ATTESTATION.setStatus(attestationId, Attestation.DisputeStatus.Pending);

        emit Challenged(disputeId, attestationId, msg.sender, stake, evidenceHash);
    }

    function resolve(bytes32 disputeId, DisputeOutcome outcome) external {
        DisputeData storage d = _disputes[disputeId];
        if (d.openedAt == 0) revert DisputeMissing();
        if (msg.sender != d.resolver) revert NotResolver();
        if (d.outcome != DisputeOutcome.Pending) revert AlreadyResolved();
        if (outcome != DisputeOutcome.AttestationValid && outcome != DisputeOutcome.AttestationInvalid) {
            revert BadOutcome();
        }

        Attestation.AttestationData memory att = ATTESTATION.getAttestation(d.attestationId);
        d.outcome = outcome;

        if (outcome == DisputeOutcome.AttestationValid) {
            // Agent receives the challenger's stake; its locked bond is released intact.
            USDC.safeTransfer(att.agent, d.challengerBond);
            if (d.lockedBond > 0) REGISTRY.unlockBond(att.feedId, att.agent, d.lockedBond);
            ATTESTATION.setStatus(d.attestationId, Attestation.DisputeStatus.ResolvedValid);
        } else {
            // Return the challenger's stake, then slash what this dispute locked (to
            // the challenger). Registry.slash deactivates the agent on the feed even
            // when nothing was locked: a reading ruled Invalid always costs the agent
            // the feed.
            USDC.safeTransfer(d.challenger, d.challengerBond);
            REGISTRY.slash(att.feedId, att.agent, d.lockedBond, d.challenger);
            ATTESTATION.setStatus(d.attestationId, Attestation.DisputeStatus.ResolvedInvalid);
        }

        emit Resolved(disputeId, outcome);
    }

    /// @notice What a challenge of `attestationId` stakes: the feed's minBond
    /// (always accepted; the agent's bond is locked up to that as far as it is free).
    /// Returns 0 when the attestation is missing.
    function challengeStake(bytes32 attestationId) external view returns (uint256) {
        Attestation.AttestationData memory att = ATTESTATION.getAttestation(attestationId);
        if (att.timestamp == 0) return 0;
        return REGISTRY.getFeed(att.feedId).minBond;
    }

    /// @notice Who removed `attestationId`: the challenger of its dispute when the
    /// resolver ruled it Invalid, else address(0) (never challenged, pending, or
    /// upheld).
    function invalidatedBy(bytes32 attestationId) external view returns (address) {
        DisputeData storage d = _disputes[disputeOf[attestationId]];
        return d.outcome == DisputeOutcome.AttestationInvalid ? d.challenger : address(0);
    }

    function getDispute(bytes32 disputeId) external view returns (DisputeData memory) {
        return _disputes[disputeId];
    }
}
