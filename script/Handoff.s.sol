// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RoleTable} from "./lib/RoleTable.sol";

/// @notice FINAL step of the mainnet order, and the single admin handoff for the
///         whole stack. The per-step scripts deliberately leave the deployer
///         holding every admin/governor/registrar role, because each step wires
///         the previous one (fund MARKETS_ROLE to the markets, pool FUNDER_ROLE
///         to the fund, allowlists...). This script moves all of them to ADMIN
///         and renounces them from the deployer, then ASSERTS the full role
///         table (RoleTable._verifyRoles): ADMIN holds every admin role, the
///         deployer holds nothing, only the markets credit builder income and
///         only the fund funds the season pool, and the oracle stack's one-shot
///         deployer powers are consumed.
///
/// ADMIN must not be the deployer. On mainnet ADMIN must be a contract (a Safe
/// or a timelock): an EOA admin would be the same single-key risk this removes.
///
/// @dev env: ADMIN, REGISTRY, ATTESTATION, NANO_LEDGER, BUILDER_REGISTRY,
///      CARETAKER_REGISTRY, BUILDER_FUND, SEASON_POOL, MARKETS_PERENNIAL,
///      MARKETS_V4 — all required on every chain.
contract Handoff is RoleTable {
    function run() external {
        _guardChain();
        handoff(_loadStack(), vm.envAddress("ADMIN"), msg.sender);
    }

    function handoff(Stack memory s, address admin, address deployer) public {
        _guardChain();
        require(admin != address(0), "ADMIN not set");
        require(deployer != address(0), "deployer not set");
        require(admin != deployer, "ADMIN must not be the deployer");
        if (_isMainnet()) require(admin.code.length > 0, "mainnet: ADMIN must be a contract (Safe/timelock), not an EOA");

        (address[] memory where, bytes32[] memory roles, string[] memory names) = _adminRoles(s);

        vm.startBroadcast(deployer);
        // Grant everything first, so ADMIN is complete before anything is renounced.
        for (uint256 i; i < where.length; i++) {
            if (!IAccessControl(where[i]).hasRole(roles[i], admin)) IAccessControl(where[i]).grantRole(roles[i], admin);
        }
        // Then renounce, per contract non-admin roles before DEFAULT_ADMIN (table order).
        for (uint256 i; i < where.length; i++) {
            if (IAccessControl(where[i]).hasRole(roles[i], deployer)) {
                IAccessControl(where[i]).renounceRole(roles[i], deployer);
            }
        }
        vm.stopBroadcast();

        for (uint256 i; i < names.length; i++) {
            console2.log(string.concat("handed off: ", names[i]));
        }
        _verifyRoles(s, admin, deployer, true);
        console2.log("Handoff complete. ADMIN:", admin);
        console2.log("Deployer holds no role:", deployer);
    }
}
