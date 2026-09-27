// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SourceKey} from "./SourceKey.sol";

/// @title ProjectNominations. The on-chain list of projects Registrai nominated.
/// @notice The builders gallery's anchor for projects that have not joined yet: the
/// owner invites a project (off chain), investigates it, and nominates it here. A
/// nomination records the canonical source (SourceKey: github:<owner>/<repo> or
/// domain:<host>), an optional hash of the investigated profile (the public
/// profile served at builder.registrai.cc/api/projects/<source>), who nominated and
/// when. It holds no funds and gates nothing: markets on nominated projects come
/// with the Perennial contracts, which take this list over.
///
/// Roles: DEFAULT_ADMIN (the Admin Safe) manages NOMINATOR_ROLE; NOMINATOR_ROLE (the
/// Safe and the onboarder wallet) nominates and un-nominates.
contract ProjectNominations is AccessControl {
    bytes32 public constant NOMINATOR_ROLE = keccak256("NOMINATOR_ROLE");

    struct Nomination {
        bool active;
        /// keccak256 of the investigated profile (0 = none recorded).
        bytes32 profileHash;
        address by;
        uint64 at;
    }

    /// @notice key => the latest nomination state of that source.
    mapping(bytes32 => Nomination) public nominationOf;
    /// @notice key => its canonical source.
    mapping(bytes32 => string) public sourceOf;
    /// @notice Every source ever nominated, in first-nomination order.
    bytes32[] public keys;

    event Nominated(bytes32 indexed key, string source, bytes32 profileHash, address indexed by);
    event Unnominated(bytes32 indexed key, string source, address indexed by);

    error ZeroAddress();
    error NotNominated();

    constructor(address admin, address onboarder) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(NOMINATOR_ROLE, admin);
        if (onboarder != address(0)) _grantRole(NOMINATOR_ROLE, onboarder);
    }

    /// @notice Nominate `source` (canonical), recording `profileHash`. Re-nominating
    /// updates the hash, nominator and time.
    function nominate(string calldata source, bytes32 profileHash) external onlyRole(NOMINATOR_ROLE) {
        bytes32 key = SourceKey.keyOf(source);
        if (bytes(sourceOf[key]).length == 0) {
            sourceOf[key] = source;
            keys.push(key);
        }
        nominationOf[key] = Nomination({active: true, profileHash: profileHash, by: msg.sender, at: uint64(block.timestamp)});
        emit Nominated(key, source, profileHash, msg.sender);
    }

    /// @notice Withdraw `source`'s nomination (a team that opted out, or a mistake).
    function unnominate(string calldata source) external onlyRole(NOMINATOR_ROLE) {
        bytes32 key = SourceKey.keyOf(source);
        Nomination storage n = nominationOf[key];
        if (!n.active) revert NotNominated();
        n.active = false;
        n.by = msg.sender;
        n.at = uint64(block.timestamp);
        emit Unnominated(key, source, msg.sender);
    }

    /// @notice Same name and meaning as MarketsPerennial.nominated.
    function nominated(bytes32 key) external view returns (bool) {
        return nominationOf[key].active;
    }

    function count() external view returns (uint256) {
        return keys.length;
    }

    /// @notice Sources [start, start + n) with their state, for the gallery.
    function page(uint256 start, uint256 n) external view returns (string[] memory sources, Nomination[] memory ns) {
        uint256 len = keys.length;
        uint256 end = start >= len ? start : (start + n > len ? len : start + n);
        uint256 size = end - start;
        sources = new string[](size);
        ns = new Nomination[](size);
        for (uint256 i; i < size; ++i) {
            bytes32 k = keys[start + i];
            sources[i] = sourceOf[k];
            ns[i] = nominationOf[k];
        }
    }
}
