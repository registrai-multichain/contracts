// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title BuilderRegistry. Opt-in registry of backed builders.
/// @notice Only registered builders can have Perennial markets and milestones.
/// `linkIdentity` binds a builder to a KYA/identity proof; `isUniqueBuilder`
/// gates the (later) quadratic distribution and is false until linked.
contract BuilderRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    struct Builder {
        address owner;
        string profileURI;
        bytes linkedIdentity; // KYA / SAI proof; empty until linked
        uint64 createdAt;
        bool active;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Builder) public builders;
    mapping(address => uint256) public builderIdOf; // one builder per address

    event BuilderRegistered(uint256 indexed id, address indexed owner, string profileURI);
    event IdentityLinked(uint256 indexed id);
    event ProfileUpdated(uint256 indexed id, string profileURI);
    event BuilderStatusSet(uint256 indexed id, bool active);

    error AlreadyRegistered();
    error NotRegistered();
    error NotOwner();
    error ZeroAddress();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, admin);
    }

    /// @notice Onboard a builder on their behalf. Owner is set to `builder`, not
    /// the caller, so the builder keeps ownership (and payout control) while
    /// signing nothing. Registrar-only to prevent builderId squatting.
    function registerFor(address builder, string calldata profileURI)
        external
        onlyRole(REGISTRAR_ROLE)
        returns (uint256 id)
    {
        if (builder == address(0)) revert ZeroAddress();
        if (builderIdOf[builder] != 0) revert AlreadyRegistered();
        id = nextId++;
        builders[id] = Builder({
            owner: builder, profileURI: profileURI, linkedIdentity: "", createdAt: uint64(block.timestamp), active: true
        });
        builderIdOf[builder] = id;
        emit BuilderRegistered(id, builder, profileURI);
    }

    function registerBuilder(string calldata profileURI) external returns (uint256 id) {
        if (builderIdOf[msg.sender] != 0) revert AlreadyRegistered();
        id = nextId++;
        builders[id] = Builder({
            owner: msg.sender,
            profileURI: profileURI,
            linkedIdentity: "",
            createdAt: uint64(block.timestamp),
            active: true
        });
        builderIdOf[msg.sender] = id;
        emit BuilderRegistered(id, msg.sender, profileURI);
    }

    function updateProfile(string calldata profileURI) external {
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
        uint256 id = builderIdOf[msg.sender];
        if (id == 0) revert NotRegistered();
        builders[id].linkedIdentity = kyaProof;
        emit IdentityLinked(id);
    }

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
}
