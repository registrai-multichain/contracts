// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {RoleTable} from "./lib/RoleTable.sol";

/// @notice Read-only. Prints and asserts the role table of a deployed stack
///         (the same assertions Handoff.s.sol ends with). Run it after Handoff
///         and whenever roles may have changed. Sends no transaction.
///
/// @dev env: ADMIN, DEPLOYER, REGISTRY, ATTESTATION, NANO_LEDGER,
///      BUILDER_REGISTRY, CARETAKER_REGISTRY, PROGRESS_POOL, MARKETS_PERENNIAL,
///      MARKETS_V4, PROGRESS_ARBITER — all required.
contract VerifyRoles is RoleTable {
    function run() external view {
        _guardChain();
        verify(_loadStack(), vm.envAddress("ADMIN"), vm.envAddress("DEPLOYER"));
    }

    function verify(Stack memory s, address admin, address deployer) public view {
        _guardChain();
        console2.log("chainid:", block.chainid);
        console2.log("ADMIN:   ", admin);
        console2.log("DEPLOYER:", deployer);
        _verifyRoles(s, admin, deployer, true);
        console2.log("OK: role table verified");
    }
}
