// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRegistraiPoints} from "./IRegistraiPoints.sol";
import {PointsValues} from "./PointsValues.sol";

/// @title Registry
/// @notice Feed creation, agent registration, and bond accounting for the agent-oracle protocol.
contract Registry {
    using SafeERC20 for IERC20;

    /// @notice Floor for any feed's minBond. Mainnet target is 100 USDC; lowered
    ///         for Arc testnet demo where faucet drips are small. Configurable
    ///         per deploy via constructor would be cleaner — to be revisited.
    uint256 public constant MIN_BOND = 10e6; // 10 USDC (6 decimals) — testnet
    uint256 public constant MIN_DISPUTE_WINDOW = 1 hours;
    uint256 public constant MAX_DISPUTE_WINDOW = 7 days;
    uint256 public constant WITHDRAW_COOLDOWN = 7 days;

    IERC20 public immutable USDC;

    struct Feed {
        address creator;
        string description;
        bytes32 methodologyHash;
        uint256 minBond;
        uint256 disputeWindow;
        address resolver;
        uint256 createdAt;
        bool exists;
    }

    struct Agent {
        bytes32 agentMethodologyHash;
        uint256 bond;
        uint256 lockedBond; // bond reserved by pending disputes; cannot be withdrawn or re-disputed
        uint256 registeredAt;
        uint256 lastAttestationAt;
        bool active;
        bool slashed; // becomes true after any slash; terminal — agent cannot re-activate via top-up
    }

    mapping(bytes32 => Feed) internal _feeds;
    mapping(bytes32 => mapping(address => Agent)) internal _agents;
    /// @notice Optional onchain rule contract per (feedId, agent). When non-zero,
    /// the Attestation contract enforces value == rule.submit(rawInputs).
    /// Agents registered via `registerAgent` (no rule) leave this at address(0)
    /// and continue to post values directly.
    mapping(bytes32 => mapping(address => address)) public ruleOf;

    address public attestation;
    address public dispute;
    address public immutable DEPLOYER;
    IRegistraiPoints public points;
    bool public pointsSet;

    event PointsContractSet(address indexed oldPoints, address indexed newPoints);
    event FeedCreated(
        bytes32 indexed feedId,
        address indexed creator,
        string description,
        bytes32 methodologyHash,
        uint256 minBond,
        uint256 disputeWindow,
        address resolver
    );
    event AgentRegistered(bytes32 indexed feedId, address indexed agent, bytes32 methodologyHash, uint256 bond);
    event RuleBound(bytes32 indexed feedId, address indexed agent, address indexed rule);
    event BondToppedUp(bytes32 indexed feedId, address indexed agent, uint256 amount, uint256 newBond);
    event BondWithdrawn(bytes32 indexed feedId, address indexed agent, uint256 amount);
    event BondLocked(bytes32 indexed feedId, address indexed agent, uint256 amount, uint256 totalLocked);
    event BondUnlocked(bytes32 indexed feedId, address indexed agent, uint256 amount, uint256 totalLocked);
    event AgentSlashed(bytes32 indexed feedId, address indexed agent, uint256 amount, address recipient);
    event AttestationRecorded(bytes32 indexed feedId, address indexed agent, uint256 timestamp);

    error FeedExists();
    error FeedMissing();
    error BondTooLow();
    error BadDisputeWindow();
    error BadResolver();
    error AgentNotRegistered();
    error AlreadyRegistered();
    error AgentInactive();
    error CooldownActive();
    error BondLockedByDispute();
    error NotAuthorized();
    error AlreadyWired();
    error NotFeedCreator();

    constructor(IERC20 usdc) {
        USDC = usdc;
        DEPLOYER = msg.sender;
    }

    /// @notice One-shot wiring. Callable only by deployer, only once.
    function wire(address attestation_, address dispute_) external {
        if (msg.sender != DEPLOYER) revert NotAuthorized();
        if (attestation != address(0) || dispute != address(0)) revert AlreadyWired();
        if (attestation_ == address(0) || dispute_ == address(0)) revert NotAuthorized();
        attestation = attestation_;
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

    function createFeed(
        string calldata description,
        bytes32 methodologyHash,
        uint256 minBond,
        uint256 disputeWindow,
        address resolver
    ) external returns (bytes32 feedId) {
        if (minBond < MIN_BOND) revert BondTooLow();
        if (disputeWindow < MIN_DISPUTE_WINDOW || disputeWindow > MAX_DISPUTE_WINDOW) revert BadDisputeWindow();
        if (resolver == address(0)) revert BadResolver();

        feedId = keccak256(abi.encode(msg.sender, description, block.timestamp));
        if (_feeds[feedId].exists) revert FeedExists();

        _feeds[feedId] = Feed({
            creator: msg.sender,
            description: description,
            methodologyHash: methodologyHash,
            minBond: minBond,
            disputeWindow: disputeWindow,
            resolver: resolver,
            createdAt: block.timestamp,
            exists: true
        });

        emit FeedCreated(feedId, msg.sender, description, methodologyHash, minBond, disputeWindow, resolver);
    }

    function registerAgent(bytes32 feedId, bytes32 agentMethodologyHash, uint256 bondAmount) external {
        _register(feedId, agentMethodologyHash, bondAmount, address(0));
    }

    /// @notice Register an agent whose attestations are gated by an onchain rule
    /// contract. Once set, Attestation.attestWithRule(feedId, rawInputs) is the
    /// only attestation path for this agent; the value is recomputed from raw
    /// inputs and cannot be spoofed.
    function registerAgentWithRule(
        bytes32 feedId,
        bytes32 agentMethodologyHash,
        uint256 bondAmount,
        address ruleContract
    ) external {
        if (ruleContract == address(0)) revert NotAuthorized();
        _register(feedId, agentMethodologyHash, bondAmount, ruleContract);
    }

    function _register(
        bytes32 feedId,
        bytes32 agentMethodologyHash,
        uint256 bondAmount,
        address ruleContract
    ) internal {
        Feed memory f = _feeds[feedId];
        if (!f.exists) revert FeedMissing();
        // v2: feed creator and agent must be the same wallet. Couples data-spec
        // and data-quality responsibility to one accountable party — no
        // Case B (someone else attesting against your feed). The agent bond
        // is then both the spec-author's and the data-runner's skin in the game.
        if (msg.sender != f.creator) revert NotFeedCreator();
        if (bondAmount < f.minBond) revert BondTooLow();

        Agent storage a = _agents[feedId][msg.sender];
        if (a.registeredAt != 0) revert AlreadyRegistered();

        USDC.safeTransferFrom(msg.sender, address(this), bondAmount);

        a.agentMethodologyHash = agentMethodologyHash;
        a.bond = bondAmount;
        a.registeredAt = block.timestamp;
        a.active = true;
        if (ruleContract != address(0)) {
            ruleOf[feedId][msg.sender] = ruleContract;
            emit RuleBound(feedId, msg.sender, ruleContract);
        }

        emit AgentRegistered(feedId, msg.sender, agentMethodologyHash, bondAmount);

        if (address(points) != address(0)) {
            uint256 pts = PointsValues.POINTS_REGISTER +
                (ruleContract != address(0) ? PointsValues.POINTS_REGISTER_RULE_BONUS : 0);
            try points.awardFlat(msg.sender, pts, "register") {} catch {}
        }
    }

    /// @notice Top up an existing agent's bond. Cannot reactivate a slashed or withdrawn agent.
    function topUpBond(bytes32 feedId, uint256 amount) external {
        Agent storage a = _agents[feedId][msg.sender];
        if (a.registeredAt == 0) revert AgentNotRegistered();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        a.bond += amount;
        emit BondToppedUp(feedId, msg.sender, amount, a.bond);
    }

    /// @notice Withdraw the entire bond. Blocked by cooldown and by any pending dispute lock.
    function withdrawBond(bytes32 feedId) external {
        Agent storage a = _agents[feedId][msg.sender];
        if (a.registeredAt == 0) revert AgentNotRegistered();
        if (a.lockedBond > 0) revert BondLockedByDispute();
        uint256 anchor = a.lastAttestationAt == 0 ? a.registeredAt : a.lastAttestationAt;
        if (block.timestamp < anchor + WITHDRAW_COOLDOWN) revert CooldownActive();

        uint256 amount = a.bond;
        a.bond = 0;
        a.active = false;
        USDC.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(feedId, msg.sender, amount);
    }

    // --- Privileged: Attestation ---

    function recordAttestation(bytes32 feedId, address agent) external {
        if (msg.sender != attestation) revert NotAuthorized();
        _agents[feedId][agent].lastAttestationAt = block.timestamp;
        emit AttestationRecorded(feedId, agent, block.timestamp);
    }

    // --- Privileged: Dispute ---

    function lockBond(bytes32 feedId, address agent, uint256 amount) external {
        if (msg.sender != dispute) revert NotAuthorized();
        Agent storage a = _agents[feedId][agent];
        // The Dispute contract is expected to size `amount` against available bond,
        // but we defend in depth here.
        require(a.bond - a.lockedBond >= amount, "Registry: insufficient available bond");
        a.lockedBond += amount;
        emit BondLocked(feedId, agent, amount, a.lockedBond);
    }

    function unlockBond(bytes32 feedId, address agent, uint256 amount) external {
        if (msg.sender != dispute) revert NotAuthorized();
        Agent storage a = _agents[feedId][agent];
        require(a.lockedBond >= amount, "Registry: unlock exceeds locked");
        a.lockedBond -= amount;
        emit BondUnlocked(feedId, agent, amount, a.lockedBond);
    }

    function slash(bytes32 feedId, address agent, uint256 amount, address recipient) external {
        if (msg.sender != dispute) revert NotAuthorized();
        Agent storage a = _agents[feedId][agent];
        uint256 slashAmount = amount > a.bond ? a.bond : amount;
        a.bond -= slashAmount;
        uint256 lockReduction = slashAmount > a.lockedBond ? a.lockedBond : slashAmount;
        a.lockedBond -= lockReduction;
        Feed memory f = _feeds[feedId];
        if (a.bond < f.minBond) {
            a.active = false;
        }
        a.slashed = true;
        // Slashed agents can never re-activate, even if top-up restores bond ≥ minBond.
        USDC.safeTransfer(recipient, slashAmount);
        emit AgentSlashed(feedId, agent, slashAmount, recipient);
    }

    // --- Views ---

    function getFeed(bytes32 feedId) external view returns (Feed memory) {
        return _feeds[feedId];
    }

    function getAgent(bytes32 feedId, address agent) external view returns (Agent memory) {
        return _agents[feedId][agent];
    }

    function isActiveAgent(bytes32 feedId, address agent) external view returns (bool) {
        return _agents[feedId][agent].active;
    }

    function availableBond(bytes32 feedId, address agent) external view returns (uint256) {
        Agent memory a = _agents[feedId][agent];
        return a.bond - a.lockedBond;
    }
}
