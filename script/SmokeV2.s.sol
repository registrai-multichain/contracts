// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Markets} from "../src/Markets.sol";
import {RegistraiPoints} from "../src/RegistraiPoints.sol";

/// @notice End-to-end smoke test of v2 stack:
///   1. createFeed
///   2. registerAgent (same wallet)
///   3. attest
///   4. createMarket
///   5. read points balance
contract SmokeV2 is Script {
    function run() external {
        Registry registry = Registry(0x0529730A961f50997de63ac0aD07f1aEa2dEC0C0);
        Attestation attestation = Attestation(0x060C61Cc315d9e8Baf2a58719f80C01163Bd6F48);
        Markets markets = Markets(0xb653c065E4805F4b2558af7AE01e9622D61Ff394);
        RegistraiPoints points = RegistraiPoints(0xF5897349819B16f4431A61Ad61293C1b31bD3381);
        IERC20 usdc = IERC20(0x3600000000000000000000000000000000000000);

        uint256 startPoints = points.points(msg.sender);
        console2.log("smoke: starting points balance:", startPoints);

        vm.startBroadcast();

        // 1. Create feed
        bytes32 feedId = registry.createFeed(
            "Smoke test feed v2",
            keccak256("ipfs://smoke-v2"),
            10e6,        // 10 USDC min bond
            1 hours,     // dispute window
            msg.sender   // resolver
        );
        console2.log("smoke: feedId");
        console2.logBytes32(feedId);

        // 2. Approve and register as agent (must be feed creator — same wallet)
        usdc.approve(address(registry), 10e6);
        registry.registerAgent(feedId, keccak256("ipfs://smoke-v2-agent"), 10e6);
        console2.log("smoke: registered as agent");

        // 3. Attest
        bytes32 attId = attestation.attest(feedId, 12345, keccak256("smoke-inputs"));
        console2.log("smoke: attested");
        console2.logBytes32(attId);

        // 4. Create market (expiry 2 days out)
        usdc.approve(address(markets), 5e6);
        bytes32 marketId = markets.createMarket(
            feedId,
            msg.sender,
            10000,
            Markets.Comparator.GreaterThan,
            block.timestamp + 2 days,
            5e6
        );
        console2.log("smoke: marketId");
        console2.logBytes32(marketId);

        vm.stopBroadcast();

        uint256 endPoints = points.points(msg.sender);
        console2.log("smoke: ending points balance:", endPoints);
        console2.log("smoke: points earned:", endPoints - startPoints);
        // Expected: 1000 (register) + 50 (attest) + 200 (createMarket) = 1250
    }
}
