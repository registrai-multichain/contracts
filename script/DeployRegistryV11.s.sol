// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";

/// @notice Deploys a v1.1 set of Registry + Attestation + Dispute alongside
///         the existing v1.0 deployment. v1.1 adds rule-bound agent
///         registration (registerAgentWithRule) and rule-gated attestation
///         (attestWithRule). v1.0 stays running with its existing feeds,
///         agents, markets, and the MM vault — none of those break.
///
///         v1.1 is the home for verifiable agents until Markets v1.1 lands
///         (next milestone) at which point markets-against-v1.1-feeds become
///         possible.
contract DeployRegistryV11 is Script {
    function run() external returns (Registry registry, Attestation attestation, Dispute dispute) {
        address usdc = vm.envAddress("USDC");

        vm.startBroadcast();
        registry = new Registry(IERC20(usdc));
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, IERC20(usdc));
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        vm.stopBroadcast();

        console2.log("Registry v1.1    :", address(registry));
        console2.log("Attestation v1.1 :", address(attestation));
        console2.log("Dispute v1.1     :", address(dispute));
    }
}
