// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AgentIdentity
/// @notice Global self-sovereign profile registry for Registrai oracle
///         agents. Decouples "who is this agent" from "what feeds is this
///         agent bonded against" (which Registry handles).
///
///         Inspired by ERC-8004's identity layer, but scoped to oracle
///         agents — no skills taxonomy, no global reputation, no admin.
///         An agent's reputation is the union of their per-feed bonds and
///         attestation history in Registry.sol; this contract only stores
///         the human-readable layer.
///
///         Anyone can register a profile by calling setProfile with their
///         own EOA. The profile is mutable by the same EOA at any time.
///         No fees, no admin, no curation.
contract AgentIdentity {
    struct Profile {
        string name;        // human-readable agent name
        string description; // short pitch / what this agent attests
        string url;         // optional canonical URL (website, methodology doc, github)
        string contact;     // optional contact handle (X, telegram, email)
        uint64 registeredAt;
        uint64 updatedAt;
        bool exists;
    }

    mapping(address => Profile) internal _profiles;

    error NameRequired();
    error NameTooLong();
    error FieldTooLong();

    /// @notice One human-readable bound — names should be reasonable.
    uint256 public constant MAX_NAME_LEN = 64;
    /// @notice Other fields can be longer (descriptions, methodology URLs).
    uint256 public constant MAX_FIELD_LEN = 512;

    event ProfileSet(
        address indexed agent,
        string name,
        string description,
        string url,
        string contact
    );

    /// @notice Register or update the caller's profile. msg.sender-gated;
    /// you can only set your own profile. To rotate the controlling address,
    /// the new address must call setProfile itself.
    function setProfile(
        string calldata name,
        string calldata description,
        string calldata url,
        string calldata contact
    ) external {
        bytes memory nameBytes = bytes(name);
        if (nameBytes.length == 0) revert NameRequired();
        if (nameBytes.length > MAX_NAME_LEN) revert NameTooLong();
        if (bytes(description).length > MAX_FIELD_LEN) revert FieldTooLong();
        if (bytes(url).length > MAX_FIELD_LEN) revert FieldTooLong();
        if (bytes(contact).length > MAX_FIELD_LEN) revert FieldTooLong();

        Profile storage p = _profiles[msg.sender];
        if (!p.exists) {
            p.registeredAt = uint64(block.timestamp);
            p.exists = true;
        }
        p.name = name;
        p.description = description;
        p.url = url;
        p.contact = contact;
        p.updatedAt = uint64(block.timestamp);

        emit ProfileSet(msg.sender, name, description, url, contact);
    }

    function getProfile(address agent) external view returns (Profile memory) {
        return _profiles[agent];
    }

    function hasProfile(address agent) external view returns (bool) {
        return _profiles[agent].exists;
    }
}
