// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";

contract DeployAgentIdentity is Script {
    function run() external returns (AgentIdentity ident) {
        vm.startBroadcast();
        ident = new AgentIdentity();
        vm.stopBroadcast();
        console2.log("AgentIdentity :", address(ident));
    }
}
