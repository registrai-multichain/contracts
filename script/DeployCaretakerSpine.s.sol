// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";

/// @notice TESTNET utility. Deploys a CaretakerRegistry over an existing
/// BuilderRegistry; the deployer keeps GOVERNOR (testnet). Afterwards:
/// registry.setCaretaker(id, op) and (builder owner) registry.setPayout(id, payout).
/// The ProgressPool this script used to deploy alongside is retired (builder
/// income now flows through BuilderFund + SeasonPool, see DeployPerennial.s.sol);
/// mainnet uses DeployBuilders.s.sol for the whole builder side.
///
/// @dev env: RPC, PRIVATE_KEY, BUILDER_REGISTRY.
contract DeployCaretakerSpine is Script {
    function run() external returns (CaretakerRegistry care) {
        address builderReg = vm.envAddress("BUILDER_REGISTRY");

        vm.startBroadcast();
        care = new CaretakerRegistry(BuilderRegistry(builderReg), msg.sender);
        vm.stopBroadcast();

        console2.log("CaretakerRegistry:", address(care));
    }
}
