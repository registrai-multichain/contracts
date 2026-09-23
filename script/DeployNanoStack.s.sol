// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../src/nanopay/MarketsV4.sol";

/// @notice Deploys the nanopay stack together: NanoLedger (with internal
///         allowance) + MarketsV4 (markets settled on the ledger), and wires
///         MarketsV4 as a ledger source so it can create + credit fee pools.
///         Testnet posture: deployer keeps the ledger governor role.
///
/// @dev env: RPC, PRIVATE_KEY, REGISTRY, ATTESTATION; optional USDC
///      (default 0x3600...0000), TREASURY (default deployer).
contract DeployNanoStack is Script {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external returns (NanoLedger ledger, MarketsV4 markets) {
        address usdc = vm.envOr("USDC", ARC_USDC);
        address registry = vm.envAddress("REGISTRY");
        address attestation = vm.envAddress("ATTESTATION");
        address treasury = vm.envOr("TREASURY", msg.sender);
        require(registry != address(0) && attestation != address(0), "registry/attestation not set");

        vm.startBroadcast();

        ledger = new NanoLedger(IERC20(usdc), msg.sender);
        markets = new MarketsV4(ledger, Registry(registry), Attestation(attestation), treasury);
        ledger.setSource(address(markets), true);

        vm.stopBroadcast();

        console2.log("NanoLedger:", address(ledger));
        console2.log("MarketsV4: ", address(markets));
        console2.log("  registry:", registry);
        console2.log("  attestation:", attestation);
        console2.log("  treasury:", treasury);
        console2.log("  usdc:", usdc);
    }
}
