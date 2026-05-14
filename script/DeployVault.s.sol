// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Markets} from "../src/Markets.sol";
import {MarketMakerVault} from "../src/MarketMakerVault.sol";

/// @notice Deploys the MarketMakerVault against the USDC Markets instance,
///         with the deployer wired as both owner and operator. Owner can
///         rotate the operator later via rotateOperator().
contract DeployVault is Script {
    function run() external returns (MarketMakerVault vault) {
        address markets = vm.envAddress("MARKETS");
        address usdc = vm.envAddress("USDC");
        address operator = vm.envOr("OPERATOR", msg.sender);

        vm.startBroadcast();
        vault = new MarketMakerVault(IERC20(usdc), Markets(markets), operator);
        vm.stopBroadcast();

        console2.log("USDC      :", usdc);
        console2.log("Markets   :", markets);
        console2.log("Operator  :", operator);
        console2.log("Vault     :", address(vault));
    }
}
