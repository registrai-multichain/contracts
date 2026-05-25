// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Markets} from "../src/Markets.sol";
import {Attestation} from "../src/Attestation.sol";
import {CirqueLending, IBTCPriceOracle} from "../src/CirqueLending.sol";
import {AttestedBTCOracle} from "../src/AttestedBTCOracle.sol";

/// @notice Deploys v0.5 alpha CirqueLending on Arc testnet using
///         Registrai's own bonded-agent oracle layer (NO owner-set oracle).
///
/// What gets deployed:
///   1. AttestedBTCOracle — adapter that reads BTC price from a Registrai
///       bonded-agent attestation. Implements IBTCPriceOracle.
///   2. CirqueLending     — lending contract pointing at cirBTC + USDC +
///                           Markets v2 + the adapter above.
///
/// PREREQUISITES (must be done BEFORE this script):
///   - Register a BTC/USD feed on Registry v2 via `Registry.createFeed`.
///     Description: "BTC/USD reference rate (cirque internal)"
///     Min dispute window: 1 hour
///     Min bond: 25 USDC (recommended)
///   - Register the bonded BTC agent: `Registry.registerAgent(feedId, methodologyHash, bond)`.
///     Use a dedicated keeper wallet (NOT the deployer, NOT MINTER).
///   - First attestation: `Attestation.attest(feedId, initialPrice, inputHash)`
///     so the oracle returns a value immediately at deploy time.
///
/// What does NOT happen automatically here:
///   - USDC seeding (do via seedUSDC() in follow-up).
///   - cirBTC acquisition (faucet.circle.com is interactive).
///
/// @dev Required env vars:
///         RPC, PRIVATE_KEY    — deployer
///         USDC                — Arc-testnet USDC address
///         CIRBTC              — cirBTC address (0xf0C4...32BF on Arc testnet)
///         MARKETS_V2          — existing Markets v2 deployment
///         ATTESTATION_V2      — existing Attestation v2 deployment
///         BTC_FEED_ID         — feedId returned by Registry.createFeed
///         BTC_AGENT           — the bonded agent's wallet (= keeper wallet)
///         TREASURY            — defaults to deployer
contract DeployCirqueLending is Script {
    function run()
        external
        returns (AttestedBTCOracle oracle, CirqueLending lending)
    {
        address usdc = vm.envAddress("USDC");
        address cirbtc = vm.envAddress("CIRBTC");
        address markets = vm.envAddress("MARKETS_V2");
        address attestation = vm.envAddress("ATTESTATION_V2");
        bytes32 btcFeedId = vm.envBytes32("BTC_FEED_ID");
        address btcAgent = vm.envAddress("BTC_AGENT");

        require(usdc != address(0), "USDC not configured");
        require(cirbtc != address(0), "CIRBTC not configured");
        require(markets != address(0), "MARKETS_V2 not configured");
        require(attestation != address(0), "ATTESTATION_V2 not configured");
        require(btcFeedId != bytes32(0), "BTC_FEED_ID not configured");
        require(btcAgent != address(0), "BTC_AGENT not configured");

        vm.startBroadcast();

        // 1. Oracle adapter — points at the bonded agent's feed.
        oracle = new AttestedBTCOracle(
            Attestation(attestation),
            btcFeedId,
            btcAgent
        );

        // 2. Lending contract. Interest accrues to USDC suppliers via
        //    share appreciation; no treasury wallet needed in v0.5 alpha.
        lending = new CirqueLending(
            IERC20(cirbtc),
            IERC20(usdc),
            Markets(payable(markets)),
            IBTCPriceOracle(address(oracle)),
            msg.sender // owner — admin escape hatch only
        );

        vm.stopBroadcast();

        console2.log("AttestedBTCOracle deployed at:", address(oracle));
        console2.log("CirqueLending     deployed at:", address(lending));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Anyone approves USDC + calls supplyUSDC(amount) to fund borrows");
        console2.log("  2. Start the keeper cron - it attests BTC prices");
        console2.log("     every 30 minutes if cirBTC integrity passes");
        console2.log("  3. Acquire cirBTC from faucet.circle.com (Arc testnet)");
    }
}
