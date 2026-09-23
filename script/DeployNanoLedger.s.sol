// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";

/// @notice Deploys NanoLedger, the fully on-chain trustless nanopayment
///         settlement layer. USDC defaults to the Arc 6-dec ERC20.
///
/// @dev env: RPC, PRIVATE_KEY; optional USDC (default 0x3600...0000),
///      KEEPER unused, TIMELOCK_DELAY (default 2 days). HANDOFF=true hands
///      GOVERNOR/ADMIN to a TimelockController and the deployer renounces EOA
///      powers; HANDOFF=false (testnet) keeps them so sources can be registered.
contract DeployNanoLedger is Script {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external returns (NanoLedger ledger, TimelockController timelock) {
        address usdc = vm.envOr("USDC", ARC_USDC);
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(2 days));
        bool handoff = vm.envOr("HANDOFF", false); // testnet default: keep roles to register sources

        vm.startBroadcast();

        ledger = new NanoLedger(IERC20(usdc), msg.sender);

        if (handoff) {
            address[] memory props = new address[](1);
            props[0] = msg.sender;
            address[] memory execs = new address[](1);
            execs[0] = msg.sender;
            timelock = new TimelockController(delay, props, execs, address(0));
            ledger.grantRole(ledger.GOVERNOR_ROLE(), address(timelock));
            ledger.grantRole(ledger.DEFAULT_ADMIN_ROLE(), address(timelock));
            ledger.renounceRole(ledger.GOVERNOR_ROLE(), msg.sender);
            ledger.renounceRole(ledger.DEFAULT_ADMIN_ROLE(), msg.sender);
        }

        vm.stopBroadcast();

        console2.log("NanoLedger:", address(ledger));
        console2.log("  USDC:", usdc);
        console2.log("  admin/governor:", handoff ? address(timelock) : msg.sender);
        console2.log("TimelockController:", address(timelock));
    }
}
