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
/// @dev env: RPC, PRIVATE_KEY, REGISTRY, ATTESTATION, FORFEIT_SINK; optional
///      USDC (default 0x3600...0000), TREASURY (default deployer), NANO_LEDGER
///      (reuse an existing ledger instead of deploying one — on mainnet V4 and
///      Perennial must share a single ledger), SETTLEMENT_WINDOW (default 24h),
///      RESOLUTION_GRACE (default 7d).
///
///      FORFEIT_SINK has no default on purpose: it receives the agent fee of
///      every market the agent fails to settle, and the protocol runs the agent.
///      Pointing it at the treasury would make the penalty a transfer to
///      ourselves, so the script refuses that. Use the commons (ProgressPool),
///      which means deploying Perennial against the ledger first.
contract DeployNanoStack is Script {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external returns (NanoLedger ledger, MarketsV4 markets) {
        address usdc = vm.envOr("USDC", ARC_USDC);
        address registry = vm.envAddress("REGISTRY");
        address attestation = vm.envAddress("ATTESTATION");
        address treasury = vm.envOr("TREASURY", msg.sender);
        address forfeitSink = vm.envAddress("FORFEIT_SINK");
        address existingLedger = vm.envOr("NANO_LEDGER", address(0));
        uint256 settlementWindow = vm.envOr("SETTLEMENT_WINDOW", uint256(24 hours));
        uint256 resolutionGrace = vm.envOr("RESOLUTION_GRACE", uint256(7 days));
        require(registry != address(0) && attestation != address(0), "registry/attestation not set");
        require(forfeitSink != treasury && forfeitSink != msg.sender, "forfeit sink must not be protocol revenue");

        vm.startBroadcast();

        ledger = existingLedger != address(0) ? NanoLedger(existingLedger) : new NanoLedger(IERC20(usdc), msg.sender);
        markets = new MarketsV4(
            ledger,
            Registry(registry),
            Attestation(attestation),
            msg.sender,
            treasury,
            forfeitSink,
            settlementWindow,
            resolutionGrace,
            40,
            20,
            10
        );
        ledger.setSource(address(markets), true);

        vm.stopBroadcast();

        console2.log("NanoLedger:", address(ledger));
        console2.log("MarketsV4: ", address(markets));
        console2.log("  registry:", registry);
        console2.log("  attestation:", attestation);
        console2.log("  treasury:", treasury);
        console2.log("  forfeitSink:", forfeitSink);
        console2.log("  settlementWindow:", settlementWindow);
        console2.log("  resolutionGrace:", resolutionGrace);
        console2.log("  usdc:", usdc);
    }
}
