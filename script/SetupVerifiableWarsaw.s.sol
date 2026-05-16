// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";

/// @notice One-off: creates a new "Warsaw resi · median (verifiable)" feed
///         alongside the existing one, and registers the deployer as a
///         rule-bound agent against it using MedianRule.
contract SetupVerifiableWarsaw is Script {
    function run() external returns (bytes32 feedId) {
        address registryAddr = vm.envAddress("REGISTRY");
        address usdcAddr = vm.envAddress("USDC");
        address medianRule = vm.envAddress("MEDIAN_RULE");

        // 10 USDC bond (matches existing feeds' MIN_BOND on Registry).
        uint256 bond = 10e6;
        bytes32 methodHash = keccak256("ipfs://warsaw-resi-median-v1");

        vm.startBroadcast();
        Registry registry = Registry(registryAddr);

        // Create feed: 1h dispute window (minimum), msg.sender as resolver,
        // 10 USDC minBond. This deployer becomes the feed creator.
        feedId = registry.createFeed(
            "Warsaw residential PLN/sqm  median of recent Otodom listings  verifiable via MedianRule",
            methodHash,
            bond,
            1 hours,
            msg.sender
        );

        // Approve bond and register as rule-bound agent.
        IERC20(usdcAddr).approve(registryAddr, bond);
        registry.registerAgentWithRule(feedId, methodHash, bond, medianRule);

        vm.stopBroadcast();

        console2.log("Verifiable Warsaw feedId :");
        console2.logBytes32(feedId);
        console2.log("Agent (deployer)         :", msg.sender);
        console2.log("Rule (MedianRule)        :", medianRule);
    }
}
