// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {Markets} from "../src/Markets.sol";

/// @notice Deploys Registry, Attestation, Dispute, Markets and wires them together.
/// @dev Requires env var USDC (test USDC address on Arc testnet).
contract Deploy is Script {
    function run()
        external
        returns (Registry registry, Attestation attestation, Dispute dispute, Markets markets)
    {
        address usdc = vm.envAddress("USDC");

        vm.startBroadcast();
        registry = new Registry(IERC20(usdc));
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, IERC20(usdc));
        // Treasury defaults to the deployer; rotate via redeploy if needed.
        address treasury = msg.sender;
        markets = new Markets(attestation, registry, IERC20(usdc), treasury);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        vm.stopBroadcast();

        console2.log("USDC       :", usdc);
        console2.log("Registry   :", address(registry));
        console2.log("Attestation:", address(attestation));
        console2.log("Dispute    :", address(dispute));
        console2.log("Markets    :", address(markets));
        console2.log("Treasury   :", treasury);
    }
}
