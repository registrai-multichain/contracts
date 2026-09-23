// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../src/nanopay/MarketsPerennial.sol";
import {ProgressPool} from "../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";

/// @notice Deploys Perennial Phase 0 wired together: BuilderRegistry +
///         ProgressPool (commons) + MarketsPerennial (markets whose treasury fee
///         leg routes to the pool), over the existing NanoLedger + Registry +
///         Attestation. Deployer keeps governor + progress roles (testnet).
///
/// @dev env: RPC, PRIVATE_KEY, REGISTRY, ATTESTATION, NANO_LEDGER;
///      optional EPOCH_LENGTH (default 0 for a same-session demo; set 30 days
///      for production).
contract DeployPerennial is Script {
    function run()
        external
        returns (BuilderRegistry builderReg, CaretakerRegistry caretakers, ProgressPool pool, MarketsPerennial markets)
    {
        address registry = vm.envAddress("REGISTRY");
        address attestation = vm.envAddress("ATTESTATION");
        address ledger = vm.envAddress("NANO_LEDGER");
        uint256 epochLength = vm.envOr("EPOCH_LENGTH", uint256(0));
        uint256 streamWindow = vm.envOr("STREAM_WINDOW", uint256(30 days));

        vm.startBroadcast();
        builderReg = new BuilderRegistry(msg.sender);
        caretakers = new CaretakerRegistry(builderReg, msg.sender);
        pool = new ProgressPool(NanoLedger(ledger), builderReg, caretakers, msg.sender, epochLength, streamWindow);
        markets = new MarketsPerennial(
            NanoLedger(ledger), Registry(registry), Attestation(attestation), builderReg, msg.sender, address(pool)
        );
        vm.stopBroadcast();

        console2.log("BuilderRegistry:", address(builderReg));
        console2.log("CaretakerRegistry:", address(caretakers));
        console2.log("ProgressPool:   ", address(pool));
        console2.log("MarketsPerennial:", address(markets));
        console2.log("  commons -> pool:", markets.commons());
        console2.log("  epochLength:", epochLength);
        console2.log("  streamWindow:", streamWindow);
    }
}
