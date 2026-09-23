// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {ProgressPool} from "../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";

/// @notice Deploys the trust spine: CaretakerRegistry + a fresh ProgressPool
/// (with claimFor). The deployer keeps governor/progress roles (testnet). After
/// running, hand-wire: MarketsPerennial.setCommons(newPool), grant the caretaker
/// operator PROGRESS_ROLE on the new pool, registry.setCaretaker(id, op),
/// (builder owner) registry.setPayout(id, payout).
///
/// @dev env: RPC, PRIVATE_KEY, NANO_LEDGER, BUILDER_REGISTRY;
///      optional EPOCH_LENGTH (default 0 for same-session demo).
contract DeployCaretakerSpine is Script {
    function run() external returns (CaretakerRegistry care, ProgressPool pool) {
        address ledger = vm.envAddress("NANO_LEDGER");
        address builderReg = vm.envAddress("BUILDER_REGISTRY");
        uint256 epochLength = vm.envOr("EPOCH_LENGTH", uint256(0));
        uint256 streamWindow = vm.envOr("STREAM_WINDOW", uint256(30 days));

        vm.startBroadcast();
        care = new CaretakerRegistry(BuilderRegistry(builderReg), msg.sender);
        pool = new ProgressPool(
            NanoLedger(ledger), BuilderRegistry(builderReg), care, msg.sender, epochLength, streamWindow
        );
        vm.stopBroadcast();

        console2.log("CaretakerRegistry:", address(care));
        console2.log("ProgressPool(new):", address(pool));
        console2.log("epochLength:", epochLength);
        console2.log("streamWindow:", streamWindow);
    }
}
