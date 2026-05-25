// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {Markets} from "../src/Markets.sol";
import {MarketMakerVault} from "../src/MarketMakerVault.sol";
import {RegistraiPoints} from "../src/RegistraiPoints.sol";

/// @notice Full v2 stack deployment. Bundles:
///         - RegistraiPoints (soulbound credit system, audited)
///         - Registry / Attestation / Dispute / Markets v2 (post-audit fixes)
///         - MarketMakerVault v2 (rebound to v2 Markets)
///
///         Reuses existing rule contracts (MedianRule, TrimmedMeanRule10) and
///         AgentIdentity from v1.1 — those are state-isolated.
///
/// @dev Run with:
///   source contracts/.env && forge script contracts/script/DeployV12.s.sol \
///     --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast
contract DeployV12 is Script {
    function run()
        external
        returns (
            RegistraiPoints points,
            Registry registry,
            Attestation attestation,
            Dispute dispute,
            Markets markets,
            MarketMakerVault vault
        )
    {
        address usdc = vm.envAddress("USDC");
        // MM operator: defaults to deployer, can override via OPERATOR env var.
        address operator = vm.envOr("OPERATOR", msg.sender);

        vm.startBroadcast();

        // 1. Points contract.
        points = new RegistraiPoints();

        // 2. Core protocol stack.
        registry    = new Registry(IERC20(usdc));
        attestation = new Attestation(registry);
        dispute     = new Dispute(registry, attestation, IERC20(usdc));
        markets     = new Markets(attestation, registry, IERC20(usdc), msg.sender);

        // 3. MM vault wired to v2 Markets.
        vault = new MarketMakerVault(IERC20(usdc), markets, operator);

        // 4. Wire protocol internals.
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        // 5. Wire points into each protocol contract (one-shot each).
        registry.setPoints(address(points));
        attestation.setPoints(address(points));
        markets.setPoints(address(points));

        // 6. Grant minter role to each protocol contract so they can award points.
        points.setMinter(address(registry),    true);
        points.setMinter(address(attestation), true);
        points.setMinter(address(markets),     true);

        vm.stopBroadcast();

        console2.log("RegistraiPoints  :", address(points));
        console2.log("Registry v2      :", address(registry));
        console2.log("Attestation v2   :", address(attestation));
        console2.log("Dispute v2       :", address(dispute));
        console2.log("Markets v2       :", address(markets));
        console2.log("MM Vault v2      :", address(vault));
        console2.log("MM Operator      :", operator);
        console2.log("Treasury         :", msg.sender);
    }
}
