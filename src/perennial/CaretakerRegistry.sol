// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {BuilderRegistry} from "./BuilderRegistry.sol";

/// @title CaretakerRegistry. Per-builder caretaker identity + payout control.
/// @notice The protocol (GOVERNOR_ROLE) assigns a distinct caretaker operator
/// address to each builder ("deployed by us, not the builder"). The builder's
/// OWNER — never the caretaker — controls where that builder's money lands.
/// These two facts are the trust spine: the caretaker is named by the protocol
/// and cannot redirect the builder's payout.
contract CaretakerRegistry is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    BuilderRegistry public immutable BUILDERS;

    mapping(uint256 => address) public caretakerOf; // builderId => operator
    mapping(uint256 => address) private _payout;     // builderId => payout (0 = use owner)

    event CaretakerSet(uint256 indexed builderId, address indexed operator);
    event PayoutSet(uint256 indexed builderId, address indexed payout);

    error ZeroAddress();
    error NotRegistered();
    error NotOwner();

    constructor(BuilderRegistry builders_, address admin) {
        if (address(builders_) == address(0) || admin == address(0)) revert ZeroAddress();
        BUILDERS = builders_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    /// @notice Assign the caretaker operator for a builder. Protocol-only.
    function setCaretaker(uint256 builderId, address operator) external onlyRole(GOVERNOR_ROLE) {
        if (operator == address(0)) revert ZeroAddress();
        if (BUILDERS.ownerOf(builderId) == address(0)) revert NotRegistered();
        caretakerOf[builderId] = operator;
        emit CaretakerSet(builderId, operator);
    }

    /// @notice Set where this builder's funds land. Builder OWNER only.
    function setPayout(uint256 builderId, address payout) external {
        if (payout == address(0)) revert ZeroAddress();
        if (msg.sender != BUILDERS.ownerOf(builderId)) revert NotOwner();
        _payout[builderId] = payout;
        emit PayoutSet(builderId, payout);
    }

    /// @notice Resolved payout: the set address, or the builder owner if unset.
    function payoutOf(uint256 builderId) external view returns (address) {
        address p = _payout[builderId];
        return p == address(0) ? BUILDERS.ownerOf(builderId) : p;
    }

    function isCaretaker(uint256 builderId, address who) external view returns (bool) {
        return who != address(0) && who == caretakerOf[builderId];
    }
}
