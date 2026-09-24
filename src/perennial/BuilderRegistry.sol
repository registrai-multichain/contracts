// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title BuilderRegistry. Opt-in registry of backed builders and their projects.
/// @notice Only registered builders can have Perennial markets and milestones.
///
/// A BUILDER is a person/team with one wallet (its owner). A PROJECT is one
/// claimed source ("github:owner/repo" / "domain:host") under a builder; a
/// builder may hold up to MAX_PROJECTS_PER_BUILDER of them. The registry does
/// not enforce uniqueness of a source: validity is the off-chain signed proof
/// (`.registrai.json` names the builder wallet and the source), so a squatter
/// without the proof simply reads as lapsed.
///
/// Ownership moves two ways: the owner proposes and the new wallet accepts
/// (two-step), or — for a lost or stolen key — the REGISTRAR starts a recovery
/// that the current owner may cancel for RECOVERY_DELAY, after which anyone
/// can finish it. A new owner is always a wallet with no builder of its own.
///
/// `linkIdentity` binds a builder to a KYA/identity proof; `isUniqueBuilder`
/// gates the (later) quadratic distribution and is false until linked.
///
/// @dev No immutables: DeployPerennial checks a reused registry's code hash
/// against this contract's runtime code.
contract BuilderRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    /// Builder-controlled strings are bounded so none can be priced out of an
    /// eth_call (the site and the keeper read them back).
    uint256 public constant MAX_PROFILE_LEN = 256;
    uint256 public constant MAX_IDENTITY_LEN = 1024;
    uint256 public constant MAX_SOURCE_LEN = 128;
    /// Counts every project ever added, so remove + add cannot cycle past it.
    uint256 public constant MAX_PROJECTS_PER_BUILDER = 16;
    /// How long the current owner has to cancel a REGISTRAR recovery.
    uint256 public constant RECOVERY_DELAY = 7 days;

    struct Builder {
        address owner;
        string profileURI; // free-form; no longer carries the claim
        bytes linkedIdentity; // KYA / SAI proof; empty until linked
        uint64 createdAt;
        bool active;
    }

    struct Project {
        uint256 builderId;
        string source; // "github:owner/repo" | "domain:host"
        bool active;
        uint64 addedAt;
    }

    struct Recovery {
        address newOwner;
        uint64 readyAt;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Builder) public builders;
    mapping(address => uint256) public builderIdOf; // one builder per address

    uint256 public nextProjectId = 1;
    mapping(uint256 => Project) public projects;
    mapping(uint256 => uint256[]) private _projectsOf; // builderId => projectIds, in add order
    mapping(uint256 => uint256) public activeProjectCount; // builderId => active projects

    mapping(uint256 => address) public pendingOwner; // builderId => proposed owner (0 = none)
    mapping(uint256 => Recovery) private _recovery; // builderId => pending recovery

    event BuilderRegistered(uint256 indexed id, address indexed owner, string profileURI);
    event IdentityLinked(uint256 indexed id);
    event ProfileUpdated(uint256 indexed id, string profileURI);
    event BuilderStatusSet(uint256 indexed id, bool active);
    event ProjectAdded(uint256 indexed builderId, uint256 indexed projectId, string source);
    event ProjectStatusSet(uint256 indexed projectId, bool active);
    event OwnerProposed(uint256 indexed builderId, address indexed newOwner);
    event RecoveryStarted(uint256 indexed builderId, address indexed newOwner, uint64 readyAt);
    event RecoveryCancelled(uint256 indexed builderId);
    event OwnerChanged(uint256 indexed builderId, address indexed from, address indexed to, bool recovered);

    error AlreadyRegistered();
    error NotRegistered();
    error NotOwner();
    error ZeroAddress();
    error TooLong();
    error EmptySource();
    error TooManyProjects();
    error UnknownProject();
    error InactiveBuilder();
    error NotPendingOwner();
    error NoRecovery();
    error RecoveryNotReady();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, admin);
    }

    // ───────────────────────────── builders ─────────────────────────────

    /// @notice Onboard a builder on their behalf. Owner is set to `builder`, not
    /// the caller, so the builder keeps ownership (and payout control) while
    /// signing nothing. Registrar-only to prevent builderId squatting.
    function registerFor(address builder, string calldata profileURI)
        external
        onlyRole(REGISTRAR_ROLE)
        returns (uint256 id)
    {
        if (builder == address(0)) revert ZeroAddress();
        id = _register(builder, profileURI);
    }

    function registerBuilder(string calldata profileURI) external returns (uint256 id) {
        id = _register(msg.sender, profileURI);
    }

    /// @notice Register and add the first project in one transaction.
    function registerBuilderWithProject(string calldata profileURI, string calldata source)
        external
        returns (uint256 builderId, uint256 projectId)
    {
        builderId = _register(msg.sender, profileURI);
        projectId = _addProject(builderId, source);
    }

    function updateProfile(string calldata profileURI) external {
        if (bytes(profileURI).length > MAX_PROFILE_LEN) revert TooLong();
        uint256 id = builderIdOf[msg.sender];
        if (id == 0) revert NotRegistered();
        builders[id].profileURI = profileURI;
        emit ProfileUpdated(id, profileURI);
    }

    /// @notice Emergency/governance switch used by downstream contracts to stop
    /// new markets and progress proposals for a builder without deleting history.
    function setActive(uint256 id, bool active) external onlyRole(REGISTRAR_ROLE) {
        if (builders[id].owner == address(0)) revert NotRegistered();
        builders[id].active = active;
        emit BuilderStatusSet(id, active);
    }

    /// @notice Bind to a KYA/identity proof. Verification of the proof is left to
    /// the identity layer; storing it is what flips isUniqueBuilder true.
    function linkIdentity(bytes calldata kyaProof) external {
        if (kyaProof.length > MAX_IDENTITY_LEN) revert TooLong();
        uint256 id = builderIdOf[msg.sender];
        if (id == 0) revert NotRegistered();
        builders[id].linkedIdentity = kyaProof;
        emit IdentityLinked(id);
    }

    // ───────────────────────────── projects ─────────────────────────────

    /// @notice Add a project (a claimed source) to the caller's builder.
    function addProject(string calldata source) external returns (uint256 projectId) {
        uint256 id = builderIdOf[msg.sender];
        if (id == 0) revert NotRegistered();
        projectId = _addProject(id, source);
    }

    /// @notice Add a project on a (gasless) builder's behalf.
    function addProjectFor(uint256 builderId, string calldata source)
        external
        onlyRole(REGISTRAR_ROLE)
        returns (uint256 projectId)
    {
        if (builders[builderId].owner == address(0)) revert NotRegistered();
        projectId = _addProject(builderId, source);
    }

    /// @notice The builder owner retires a project. The id and its history stay;
    /// it still counts toward MAX_PROJECTS_PER_BUILDER.
    function removeProject(uint256 projectId) external {
        uint256 builderId = projects[projectId].builderId;
        if (builderId == 0) revert UnknownProject();
        if (msg.sender != builders[builderId].owner) revert NotOwner();
        _setProjectActive(projectId, builderId, false);
    }

    /// @notice Governance switch for one project (e.g. a fraudulent claim).
    function setProjectActive(uint256 projectId, bool active) external onlyRole(REGISTRAR_ROLE) {
        uint256 builderId = projects[projectId].builderId;
        if (builderId == 0) revert UnknownProject();
        _setProjectActive(projectId, builderId, active);
    }

    // ───────────────────────────── ownership ─────────────────────────────

    /// @notice Owner proposes a new owner wallet for its builder; `address(0)`
    /// cancels. The new wallet must hold no builder.
    function proposeOwner(address newOwner) external {
        uint256 id = builderIdOf[msg.sender];
        if (id == 0) revert NotRegistered();
        if (newOwner != address(0) && builderIdOf[newOwner] != 0) revert AlreadyRegistered();
        pendingOwner[id] = newOwner;
        emit OwnerProposed(id, newOwner);
    }

    /// @notice The proposed wallet takes the builder over.
    function acceptOwnership(uint256 builderId) external {
        if (msg.sender != pendingOwner[builderId]) revert NotPendingOwner(); // msg.sender is never 0
        if (builderIdOf[msg.sender] != 0) revert AlreadyRegistered();
        _changeOwner(builderId, msg.sender, false);
    }

    /// @notice Start moving a builder to `newOwner` (lost/stolen key). The
    /// current owner may cancel it until `readyAt`; restarting replaces it.
    function startRecovery(uint256 builderId, address newOwner) external onlyRole(REGISTRAR_ROLE) {
        if (builders[builderId].owner == address(0)) revert NotRegistered();
        if (newOwner == address(0)) revert ZeroAddress();
        if (builderIdOf[newOwner] != 0) revert AlreadyRegistered();
        uint64 readyAt = uint64(block.timestamp + RECOVERY_DELAY);
        _recovery[builderId] = Recovery({newOwner: newOwner, readyAt: readyAt});
        emit RecoveryStarted(builderId, newOwner, readyAt);
    }

    /// @notice Cancel a pending recovery: the current owner or the REGISTRAR.
    function cancelRecovery(uint256 builderId) external {
        if (msg.sender != builders[builderId].owner && !hasRole(REGISTRAR_ROLE, msg.sender)) revert NotOwner();
        if (_recovery[builderId].newOwner == address(0)) revert NoRecovery();
        delete _recovery[builderId];
        emit RecoveryCancelled(builderId);
    }

    /// @notice Complete a recovery once RECOVERY_DELAY has passed. Anyone.
    function finishRecovery(uint256 builderId) external {
        Recovery memory r = _recovery[builderId];
        if (r.newOwner == address(0)) revert NoRecovery();
        if (block.timestamp < r.readyAt) revert RecoveryNotReady();
        if (builderIdOf[r.newOwner] != 0) revert AlreadyRegistered();
        _changeOwner(builderId, r.newOwner, true);
    }

    // ───────────────────────────── views ─────────────────────────────

    function isUniqueBuilder(address who) external view returns (bool) {
        uint256 id = builderIdOf[who];
        return id != 0 && builders[id].linkedIdentity.length > 0;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return builders[id].owner;
    }

    function isRegistered(address who) external view returns (bool) {
        return builderIdOf[who] != 0;
    }

    function isActiveBuilder(address who) external view returns (bool) {
        uint256 id = builderIdOf[who];
        return id != 0 && builders[id].active;
    }

    function isActiveBuilderId(uint256 id) external view returns (bool) {
        return builders[id].owner != address(0) && builders[id].active;
    }

    /// @notice Every project id ever added to `builderId`, active or not.
    function projectsOf(uint256 builderId) external view returns (uint256[] memory) {
        return _projectsOf[builderId];
    }

    function hasActiveProject(uint256 builderId) external view returns (bool) {
        return activeProjectCount[builderId] > 0;
    }

    /// @notice The pending recovery of `builderId` (newOwner 0 = none).
    function recoveryOf(uint256 builderId) external view returns (address newOwner, uint64 readyAt) {
        Recovery memory r = _recovery[builderId];
        return (r.newOwner, r.readyAt);
    }

    // ───────────────────────────── internal ─────────────────────────────

    function _register(address owner, string calldata profileURI) internal returns (uint256 id) {
        if (bytes(profileURI).length > MAX_PROFILE_LEN) revert TooLong();
        if (builderIdOf[owner] != 0) revert AlreadyRegistered();
        id = nextId++;
        builders[id] = Builder({
            owner: owner, profileURI: profileURI, linkedIdentity: "", createdAt: uint64(block.timestamp), active: true
        });
        builderIdOf[owner] = id;
        emit BuilderRegistered(id, owner, profileURI);
    }

    function _addProject(uint256 builderId, string calldata source) internal returns (uint256 projectId) {
        if (!builders[builderId].active) revert InactiveBuilder();
        uint256 len = bytes(source).length;
        if (len == 0) revert EmptySource();
        if (len > MAX_SOURCE_LEN) revert TooLong();
        uint256[] storage list = _projectsOf[builderId];
        if (list.length >= MAX_PROJECTS_PER_BUILDER) revert TooManyProjects();
        projectId = nextProjectId++;
        projects[projectId] =
            Project({builderId: builderId, source: source, active: true, addedAt: uint64(block.timestamp)});
        list.push(projectId);
        activeProjectCount[builderId] += 1;
        emit ProjectAdded(builderId, projectId, source);
    }

    /// @dev Idempotent: no state change and no event when already `active`.
    function _setProjectActive(uint256 projectId, uint256 builderId, bool active) internal {
        Project storage p = projects[projectId];
        if (p.active == active) return;
        p.active = active;
        if (active) activeProjectCount[builderId] += 1;
        else activeProjectCount[builderId] -= 1;
        emit ProjectStatusSet(projectId, active);
    }

    function _changeOwner(uint256 builderId, address to, bool recovered) internal {
        address from = builders[builderId].owner;
        delete builderIdOf[from];
        builderIdOf[to] = builderId;
        builders[builderId].owner = to;
        delete pendingOwner[builderId];
        delete _recovery[builderId];
        emit OwnerChanged(builderId, from, to, recovered);
    }
}
