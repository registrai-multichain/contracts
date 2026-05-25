// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Registry} from "./Registry.sol";
import {IAgentRule} from "./rules/IAgentRule.sol";
import {IRegistraiPoints} from "./IRegistraiPoints.sol";
import {PointsValues} from "./PointsValues.sol";

/// @title Attestation
/// @notice Stores attestations from registered agents and exposes read functions.
contract Attestation {
    enum DisputeStatus {
        None,
        Pending,
        ResolvedValid,
        ResolvedInvalid
    }

    struct AttestationData {
        bytes32 feedId;
        address agent;
        int256 value;
        uint256 timestamp;
        bytes32 inputHash;
        bytes32 methodologyHash;
        DisputeStatus status;
        uint256 finalizedAt;
    }

    Registry public immutable REGISTRY;
    address public dispute;
    address public immutable DEPLOYER;
    IRegistraiPoints public points;
    bool public pointsSet;

    mapping(bytes32 => AttestationData) internal _attestations;
    mapping(bytes32 => mapping(address => bytes32[])) internal _history;
    /// @notice Cached pointer to the latest non-invalidated attestation in each history.
    /// Stored as `index + 1` so that 0 means "no valid attestation yet".
    mapping(bytes32 => mapping(address => uint256)) internal _latestValidPlusOne;

    event PointsContractSet(address indexed oldPoints, address indexed newPoints);
    event Attested(
        bytes32 indexed attestationId,
        bytes32 indexed feedId,
        address indexed agent,
        int256 value,
        bytes32 inputHash,
        uint256 finalizedAt
    );
    event StatusUpdated(bytes32 indexed attestationId, DisputeStatus status);

    error AgentInactive();
    error InsufficientAvailableBond();
    error FeedMissing();
    error DuplicateAttestation();
    error AttestationMissing();
    error NotAuthorized();
    error AlreadyWired();
    error AgentHasRule();
    error AgentHasNoRule();
    error InvalidStatusTransition();

    constructor(Registry registry_) {
        REGISTRY = registry_;
        DEPLOYER = msg.sender;
    }

    function wire(address dispute_) external {
        if (msg.sender != DEPLOYER) revert NotAuthorized();
        if (dispute != address(0)) revert AlreadyWired();
        if (dispute_ == address(0)) revert NotAuthorized();
        dispute = dispute_;
    }

    /// @notice One-shot: wire the points contract. Deployer-only, callable only once.
    function setPoints(address points_) external {
        if (msg.sender != DEPLOYER) revert NotAuthorized();
        if (pointsSet) revert AlreadyWired();
        pointsSet = true;
        emit PointsContractSet(address(0), points_);
        points = IRegistraiPoints(points_);
    }

    function attest(bytes32 feedId, int256 value, bytes32 inputHash) external returns (bytes32 attestationId) {
        // Plain attestation path — agent posts the value directly. Disallowed
        // when the agent is bound to a rule contract; use attestWithRule then.
        if (REGISTRY.ruleOf(feedId, msg.sender) != address(0)) revert AgentHasRule();
        return _record(feedId, msg.sender, value, inputHash, false);
    }

    /// @notice Verifiable-agent attestation. Agent must be registered via
    /// `Registry.registerAgentWithRule`. The submitted `rawInputs` are passed
    /// to the bound rule contract; its deterministic output is the recorded
    /// value, and `inputHash = keccak256(abi.encode(rawInputs))` so disputes
    /// can re-derive the exact input vector.
    function attestWithRule(bytes32 feedId, int256[] calldata rawInputs)
        external
        returns (bytes32 attestationId)
    {
        address rule = REGISTRY.ruleOf(feedId, msg.sender);
        if (rule == address(0)) revert AgentHasNoRule();
        int256 value = IAgentRule(rule).submit(rawInputs);
        bytes32 inputHash = keccak256(abi.encode(rawInputs));
        return _record(feedId, msg.sender, value, inputHash, true);
    }

    function _record(bytes32 feedId, address agent, int256 value, bytes32 inputHash, bool verifiable)
        internal
        returns (bytes32 attestationId)
    {
        Registry.Feed memory f = REGISTRY.getFeed(feedId);
        if (!f.exists) revert FeedMissing();

        Registry.Agent memory a = REGISTRY.getAgent(feedId, agent);
        if (!a.active) revert AgentInactive();
        // Must keep enough free bond to back every outstanding attestation. A new attestation
        // requires at least `minBond` available so a challenger can match it.
        if (a.bond - a.lockedBond < f.minBond) revert InsufficientAvailableBond();

        attestationId = keccak256(abi.encode(feedId, agent, block.timestamp, value, inputHash));
        if (_attestations[attestationId].timestamp != 0) revert DuplicateAttestation();

        _attestations[attestationId] = AttestationData({
            feedId: feedId,
            agent: agent,
            value: value,
            timestamp: block.timestamp,
            inputHash: inputHash,
            methodologyHash: a.agentMethodologyHash,
            status: DisputeStatus.None,
            finalizedAt: block.timestamp + f.disputeWindow
        });
        _history[feedId][agent].push(attestationId);
        _latestValidPlusOne[feedId][agent] = _history[feedId][agent].length;

        REGISTRY.recordAttestation(feedId, agent);

        emit Attested(attestationId, feedId, agent, value, inputHash, block.timestamp + f.disputeWindow);

        if (address(points) != address(0)) {
            uint256 pts = PointsValues.POINTS_ATTEST +
                (verifiable ? PointsValues.POINTS_ATTEST_RULE_BONUS : 0);
            try points.awardFlat(agent, pts, "attest") {} catch {}
        }
    }

    // --- Privileged: Dispute ---

    function setStatus(bytes32 attestationId, DisputeStatus status) external {
        if (msg.sender != dispute) revert NotAuthorized();
        AttestationData storage att = _attestations[attestationId];
        if (att.timestamp == 0) revert AttestationMissing();
        // Enforce state machine: None→Pending, Pending→ResolvedValid|ResolvedInvalid only.
        // Prevents re-resolving an already-settled attestation from a future contract path.
        if (att.status == DisputeStatus.ResolvedValid || att.status == DisputeStatus.ResolvedInvalid) {
            revert InvalidStatusTransition();
        }
        bool wasSlashable = att.status == DisputeStatus.Pending;
        att.status = status;
        emit StatusUpdated(attestationId, status);

        if (status == DisputeStatus.ResolvedInvalid) {
            _repairLatestPointer(att.feedId, att.agent, attestationId);
            // Only slash if transitioning from Pending (M1: idempotency guard).
            if (wasSlashable && address(points) != address(0)) {
                try points.slashPoints(att.agent, PointsValues.POINTS_SLASH_PENALTY) {} catch {}
            }
        }
    }

    /// @dev If the just-invalidated attestation was the cached "latest valid", walk back to
    /// find the most recent prior non-invalidated entry and update the pointer.
    function _repairLatestPointer(bytes32 feedId, address agent, bytes32 invalidatedId) internal {
        bytes32[] storage h = _history[feedId][agent];
        uint256 idxPlusOne = _latestValidPlusOne[feedId][agent];
        if (idxPlusOne == 0) return;
        if (h[idxPlusOne - 1] != invalidatedId) return; // it wasn't the latest

        for (uint256 i = idxPlusOne - 1; i > 0; i--) {
            if (_attestations[h[i - 1]].status != DisputeStatus.ResolvedInvalid) {
                _latestValidPlusOne[feedId][agent] = i;
                return;
            }
        }
        _latestValidPlusOne[feedId][agent] = 0;
    }

    // --- Views ---

    function getAttestation(bytes32 attestationId) external view returns (AttestationData memory) {
        return _attestations[attestationId];
    }

    function isFinalized(bytes32 attestationId) public view returns (bool) {
        AttestationData memory att = _attestations[attestationId];
        if (att.timestamp == 0) return false;
        if (att.status == DisputeStatus.ResolvedInvalid) return false;
        if (att.status == DisputeStatus.Pending) return false;
        if (att.status == DisputeStatus.ResolvedValid) return true;
        return block.timestamp >= att.finalizedAt;
    }

    function latestValue(bytes32 feedId, address agent)
        external
        view
        returns (int256 value, uint256 timestamp, bool finalized)
    {
        uint256 idxPlusOne = _latestValidPlusOne[feedId][agent];
        if (idxPlusOne == 0) return (0, 0, false);
        bytes32 id = _history[feedId][agent][idxPlusOne - 1];
        AttestationData memory att = _attestations[id];
        return (att.value, att.timestamp, isFinalized(id));
    }

    function valueAt(bytes32 feedId, address agent, uint256 atTimestamp)
        external
        view
        returns (int256 value, bool finalized)
    {
        bytes32[] storage h = _history[feedId][agent];
        for (uint256 i = h.length; i > 0; i--) {
            bytes32 id = h[i - 1];
            AttestationData memory att = _attestations[id];
            if (att.timestamp > atTimestamp) continue;
            if (att.status == DisputeStatus.ResolvedInvalid) continue;
            return (att.value, isFinalized(id));
        }
        return (0, false);
    }

    function historyLength(bytes32 feedId, address agent) external view returns (uint256) {
        return _history[feedId][agent].length;
    }

    function historyAt(bytes32 feedId, address agent, uint256 index) external view returns (bytes32) {
        return _history[feedId][agent][index];
    }
}
