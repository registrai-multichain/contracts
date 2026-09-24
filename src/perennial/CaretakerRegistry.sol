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
///
/// A payout is stored together with the owner that set it and only honoured
/// while that wallet still owns the builder: after an owner change (transfer or
/// recovery) payouts fall back to the new owner, so a recovered builder is never
/// paid to an address a thief chose with the old key.
contract CaretakerRegistry is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    BuilderRegistry public immutable BUILDERS;

    struct Payout {
        address payout;
        address setBy; // the builder owner at the time it was set
    }

    mapping(uint256 => address) public caretakerOf; // builderId => operator
    mapping(uint256 => Payout) private _payout; // builderId => payout (0 = use owner)

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

    /// @notice Set where this builder's funds land. Builder OWNER only; valid
    /// while the caller remains the owner.
    function setPayout(uint256 builderId, address payout) external {
        if (payout == address(0)) revert ZeroAddress();
        if (msg.sender != BUILDERS.ownerOf(builderId)) revert NotOwner();
        _payout[builderId] = Payout({payout: payout, setBy: msg.sender});
        emit PayoutSet(builderId, payout);
    }

    /// @notice Resolved payout: the set address while its setter still owns the
    /// builder, otherwise the current owner (0 for an unregistered id).
    function payoutOf(uint256 builderId) external view returns (address) {
        address owner = BUILDERS.ownerOf(builderId);
        Payout memory p = _payout[builderId];
        return (p.payout != address(0) && p.setBy == owner) ? p.payout : owner;
    }

    /// @notice The raw stored payout and the owner that set it (may be stale).
    function payoutRecord(uint256 builderId) external view returns (address payout, address setBy) {
        Payout memory p = _payout[builderId];
        return (p.payout, p.setBy);
    }

    function isCaretaker(uint256 builderId, address who) external view returns (bool) {
        return who != address(0) && who == caretakerOf[builderId];
    }
}
