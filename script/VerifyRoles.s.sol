// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {RoleTable} from "./lib/RoleTable.sol";

/// @notice Read-only. Prints and asserts the role table of a deployed stack
///         (the same assertions Handoff.s.sol ends with). Run it after Handoff
///         and whenever roles may have changed. Sends no transaction.
///
/// @dev env: ADMIN, DEPLOYER, REGISTRY, ATTESTATION, NANO_LEDGER,
///      BUILDER_REGISTRY, CARETAKER_REGISTRY, BUILDER_FUND, SEASON_POOL,
///      MARKETS_PERENNIAL, MARKETS_V4 — all required. ONBOARDER optional: the
///      phase-1 hot wallet, asserted to hold no market/admin role.
///      FROM_BLOCK (with OPERATOR and ONBOARDER): also the EXACT check (audit L-2),
///      nobody but the expected holders on the builder side and the Perennial
///      stack, from every RoleGranted log since FROM_BLOCK (the phase-1 deploy
///      block; read in 5,000-block windows, the public RPC caps getLogs).
contract VerifyRoles is RoleTable {
    uint256 internal constant LOG_WINDOW = 5_000;

    function run() external {
        _guardChain();
        Stack memory s = _loadStack();
        verify(s, vm.envAddress("ADMIN"), vm.envAddress("DEPLOYER"));
        address onboarder = vm.envOr("ONBOARDER", address(0));
        _verifyOnboarder(s, onboarder, true);
        uint256 fromBlock = vm.envOr("FROM_BLOCK", uint256(0));
        if (fromBlock != 0) {
            verifyExact(s, vm.envAddress("ADMIN"), vm.envAddress("OPERATOR"), onboarder, _roleLogs(s, fromBlock, block.number));
        }
    }

    /// @notice The exact check over `logs` (see RoleTable._verifyExact).
    function verifyExact(Stack memory s, address admin, address operator, address onboarder, Vm.Log[] memory logs)
        public
        view
    {
        _verifyExact(s, admin, operator, onboarder, logs);
        console2.log("OK: exact role table (no stray holder), from logs:", logs.length);
    }

    /// @dev Every RoleGranted log of the covered contracts in [fromBlock, toBlock].
    function _roleLogs(Stack memory s, uint256 fromBlock, uint256 toBlock) internal returns (Vm.Log[] memory out) {
        address[6] memory targets = [s.builders, s.caretakers, s.fund, s.seasonPool, s.perennial, s.escrow];
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = ROLE_GRANTED;
        Vm.Log[] memory buf = new Vm.Log[](4096);
        uint256 n;
        for (uint256 t; t < targets.length; t++) {
            for (uint256 from = fromBlock; from <= toBlock; from += LOG_WINDOW) {
                uint256 to = from + LOG_WINDOW - 1 < toBlock ? from + LOG_WINDOW - 1 : toBlock;
                VmSafe.EthGetLogs[] memory got = vm.eth_getLogs(from, to, targets[t], topics);
                for (uint256 i; i < got.length; i++) {
                    require(n < buf.length, "too many RoleGranted logs");
                    buf[n++] = VmSafe.Log({topics: got[i].topics, data: got[i].data, emitter: got[i].emitter});
                }
            }
        }
        out = new Vm.Log[](n);
        for (uint256 i; i < n; i++) out[i] = buf[i];
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
