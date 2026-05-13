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
    error NoAvailableBond();
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

        Registry.Feed memory f = REGISTRY.getFeed(att.feedId);
        Registry.Agent memory a = REGISTRY.getAgent(att.feedId, att.agent);
        uint256 available = a.bond - a.lockedBond;
        if (available == 0) revert NoAvailableBond();

        // Symmetric stake: challenger matches the agent's available bond.
        uint256 bond = available;
        USDC.safeTransferFrom(msg.sender, address(this), bond);
        REGISTRY.lockBond(att.feedId, att.agent, bond);

        disputeId = keccak256(abi.encode(attestationId, msg.sender, block.timestamp));
        _disputes[disputeId] = DisputeData({
            attestationId: attestationId,
            challenger: msg.sender,
            challengerBond: bond,
            evidenceHash: evidenceHash,
            openedAt: block.timestamp,
            resolver: f.resolver,
            outcome: DisputeOutcome.Pending
        });
        disputeOf[attestationId] = disputeId;

        ATTESTATION.setStatus(attestationId, Attestation.DisputeStatus.Pending);

        emit Challenged(disputeId, attestationId, msg.sender, bond, evidenceHash);
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
            // Agent receives the full challenger bond; agent's own bond is unlocked intact.
            USDC.safeTransfer(att.agent, d.challengerBond);
            REGISTRY.unlockBond(att.feedId, att.agent, d.challengerBond);
            ATTESTATION.setStatus(d.attestationId, Attestation.DisputeStatus.ResolvedValid);
        } else {
            // Return challenger's own posted bond, then slash an equal amount from the
            // agent (which is currently locked) and send it to the challenger.
            USDC.safeTransfer(d.challenger, d.challengerBond);
            REGISTRY.slash(att.feedId, att.agent, d.challengerBond, d.challenger);
            ATTESTATION.setStatus(d.attestationId, Attestation.DisputeStatus.ResolvedInvalid);
        }

        emit Resolved(disputeId, outcome);
    }

    function getDispute(bytes32 disputeId) external view returns (DisputeData memory) {
        return _disputes[disputeId];
    }
}
