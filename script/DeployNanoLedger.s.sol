// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";

/// @notice Step 2 of the mainnet order. Deploys NanoLedger, the on-chain
///         nanopayment settlement layer, with the deployer as admin/governor so
///         the following steps can wire it (DeployNanoStack registers MarketsV4
///         as a source).
///
/// Admin handoff is NOT done here. `script/Handoff.s.sol` is the single handoff
/// for the whole stack and runs last. The old HANDOFF=true path (a timelock
/// proposed/executed by the deployer, and the deployer renouncing before
/// setSource) broke the forced order and has been retired: setting it reverts.
///
/// @dev env: USDC [0x3600…0000] (must be 0x3600…0000 on mainnet).
contract DeployNanoLedger is DeployBase {
    struct Config {
        address deployer;
        address usdc;
    }

    function run() external returns (NanoLedger ledger) {
        _guardChain();
        require(!vm.envOr("HANDOFF", false), "HANDOFF is retired: run script/Handoff.s.sol after the whole stack");
        ledger = deploy(Config({deployer: msg.sender, usdc: vm.envOr("USDC", ARC_USDC)}));
        console2.log("NanoLedger:", address(ledger));
        console2.log("  USDC:", address(ledger.USDC()));
        console2.log("  admin/governor (until Handoff):", msg.sender);
    }

    function deploy(Config memory c) public returns (NanoLedger ledger) {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        if (_isMainnet()) require(c.usdc == ARC_USDC, "mainnet USDC must be 0x3600...0000");
        vm.startBroadcast(c.deployer);
        ledger = new NanoLedger(IERC20(c.usdc), c.deployer);
        vm.stopBroadcast();
    }
}
