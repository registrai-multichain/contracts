// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MedianRule} from "../src/rules/MedianRule.sol";
import {TrimmedMeanRule} from "../src/rules/TrimmedMeanRule.sol";

/// @notice Deploys the two reference rule contracts. Stateless; one
///         deployment per chain is enough to back unlimited agents.
contract DeployRules is Script {
    function run() external returns (MedianRule median, TrimmedMeanRule trim10) {
        vm.startBroadcast();
        median = new MedianRule();
        trim10 = new TrimmedMeanRule(1000); // 10% per tail
        vm.stopBroadcast();

        console2.log("MedianRule        :", address(median));
        console2.log("TrimmedMeanRule10 :", address(trim10));
    }
}
