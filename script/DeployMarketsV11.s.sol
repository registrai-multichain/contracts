// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Attestation} from "../src/Attestation.sol";
import {Registry} from "../src/Registry.sol";
import {Markets} from "../src/Markets.sol";

/// @notice Deploys a Markets instance bound to Attestation v1.1, so markets
///         can resolve against verifiable (rule-bound) feeds. Treasury is
///         the deployer. USDC collateral.
contract DeployMarketsV11 is Script {
    function run() external returns (Markets markets) {
        address attestation = vm.envAddress("ATTESTATION_V1_1");
        address registry = vm.envAddress("REGISTRY_V1_1");
        address usdc = vm.envAddress("USDC");

        vm.startBroadcast();
        address treasury = msg.sender;
        markets = new Markets(
            Attestation(attestation),
            Registry(registry),
            IERC20(usdc),
            treasury
        );
        vm.stopBroadcast();

        console2.log("Attestation v1.1 :", attestation);
        console2.log("Registry v1.1    :", registry);
        console2.log("Markets v1.1     :", address(markets));
    }
}
