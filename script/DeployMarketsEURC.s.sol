// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Attestation} from "../src/Attestation.sol";
import {Registry} from "../src/Registry.sol";
import {Markets} from "../src/Markets.sol";

/// @notice Deploys a second Markets instance using EURC as collateral. Same
///         code, different stablecoin — proves the protocol is currency-agnostic.
contract DeployMarketsEURC is Script {
    function run() external returns (Markets markets) {
        address attestation = vm.envAddress("ATTESTATION");
        address registry = vm.envAddress("REGISTRY");
        address eurc = vm.envAddress("EURC");

        vm.startBroadcast();
        address treasury = msg.sender;
        markets = new Markets(Attestation(attestation), Registry(registry), IERC20(eurc), treasury);
        vm.stopBroadcast();

        console2.log("Attestation :", attestation);
        console2.log("Registry    :", registry);
        console2.log("EURC        :", eurc);
        console2.log("Markets/EURC:", address(markets));
    }
}
