// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Attestation} from "../src/Attestation.sol";
import {Registry} from "../src/Registry.sol";
import {MarketsV3} from "../src/MarketsV3.sol";
import {CirqueBetLending} from "../src/CirqueBetLending.sol";

/// @notice Deploys the "borrow USDC against a prediction-market bet" stack:
///   1. MarketsV3   — Markets v2 + a share-transfer primitive so YES/NO
///                    positions can be pulled in as collateral. SIBLING deploy;
///                    reuses the existing v2 Registry + Attestation, no
///                    migration of the live v2 markets.
///   2. CirqueBetLending — two-sided USDC pool that lends against a held
///                    MarketsV3 position at the depth-capped mark.
///
/// @dev Required env vars:
///        RPC, PRIVATE_KEY  — deployer
///        USDC              — Arc-testnet USDC (0x3600…0000)
///        REGISTRY_V2       — existing Registry v2
///        ATTESTATION_V2    — existing Attestation v2
///        TREASURY          — defaults to deployer (fee sink, no supplier privilege)
contract DeployBetLending is Script {
    function run() external returns (MarketsV3 markets, CirqueBetLending lending) {
        address usdc = vm.envAddress("USDC");
        address registry = vm.envAddress("REGISTRY_V2");
        address attestation = vm.envAddress("ATTESTATION_V2");
        address treasury = vm.envOr("TREASURY", msg.sender);
        // Per-side eligibility floor. Mainnet should use DEFAULT_MIN_POOL_DEPTH
        // (1,000 USDC = 1000e6); a testnet deploy may scale it down to match
        // play-money liquidity (the ratio-based defense is unchanged).
        uint256 minPoolDepth = vm.envOr("MIN_POOL_DEPTH", uint256(1000e6));

        require(usdc != address(0), "USDC not configured");
        require(registry != address(0), "REGISTRY_V2 not configured");
        require(attestation != address(0), "ATTESTATION_V2 not configured");

        // Reuse an already-deployed MarketsV3 if MARKETS_V3_REUSE is set (so a
        // CirqueBetLending re-deploy doesn't churn the markets address); else
        // deploy a fresh sibling MarketsV3.
        address reuse = vm.envOr("MARKETS_V3_REUSE", address(0));

        vm.startBroadcast();

        markets = reuse != address(0)
            ? MarketsV3(reuse)
            : new MarketsV3(
                Attestation(attestation),
                Registry(registry),
                IERC20(usdc),
                treasury
            );

        lending = new CirqueBetLending(
            IERC20(usdc),
            markets,
            msg.sender, // owner — no privilege over supplier funds; writeOff is permissionless
            minPoolDepth
        );

        vm.stopBroadcast();

        console2.log("MIN_POOL_DEPTH (per side, 6dp):", minPoolDepth);

        console2.log("MarketsV3         deployed at:", address(markets));
        console2.log("CirqueBetLending  deployed at:", address(lending));
        console2.log("treasury:", treasury);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Create one or more markets on MarketsV3 (createMarket).");
        console2.log("  2. Supply USDC to CirqueBetLending (supplyUSDC) to fund borrows.");
        console2.log("  3. Wire MarketsV3 + CirqueBetLending into the frontend + keeper env.");
    }
}
