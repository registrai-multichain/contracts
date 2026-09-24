// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../test/MockUSDC.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../src/nanopay/MarketsPerennial.sol";
import {ProgressPool} from "../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";

/// @notice LOCAL REHEARSAL ONLY. Stands up the settlement stack on anvil with
/// three markets for the keeper's settlement loop to work through:
///   SERVED    our agent, a feed the keeper has a value provider for
///   UNSERVED  our agent, a feed it has no provider for (must be reported, then void)
///   FOREIGN   someone else's agent (must be ignored)
/// Refuses to run anywhere but anvil (chainid 31337). Uses anvil's well-known
/// dev keys, which hold no value anywhere else.
contract RehearseSettlement is Script {
    uint256 constant DEPLOYER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant AGENT = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant OTHER_AGENT = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant TRADER = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    function run() external {
        require(block.chainid == 31337, "rehearsal runs on anvil only");
        address deployer = vm.addr(DEPLOYER);
        address agent = vm.addr(AGENT);
        address otherAgent = vm.addr(OTHER_AGENT);
        address trader = vm.addr(TRADER);

        vm.startBroadcast(DEPLOYER);
        MockUSDC usdc = new MockUSDC();
        Registry registry = new Registry(usdc, 10e6);
        Attestation attestation = new Attestation(registry);
        Dispute dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        NanoLedger ledger = new NanoLedger(usdc, deployer);
        BuilderRegistry builders = new BuilderRegistry(deployer);
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, deployer);
        builders.registerFor(address(0xB111), "github.com/example/builder");
        ProgressPool pool = new ProgressPool(ledger, builders, caretakers, deployer, 1 days, 1 hours);
        MarketsPerennial markets =
            new MarketsPerennial(ledger, registry, attestation, builders, deployer, address(pool), 1 hours, 1 days);
        // oracle allowlist: our agent, the foreign agent (so its market exists to
        // be ignored), and the deployer as every feed's dispute resolver
        markets.setApprovedAgent(agent, true);
        markets.setApprovedAgent(otherAgent, true);
        markets.setApprovedResolver(deployer, true);
        usdc.mint(agent, 1_000e6);
        usdc.mint(otherAgent, 1_000e6);
        usdc.mint(trader, 10_000e6);
        vm.stopBroadcast();

        vm.startBroadcast(AGENT);
        usdc.approve(address(registry), type(uint256).max);
        bytes32 served = registry.createFeed("served", keccak256("m"), 10e6, 1 hours, deployer);
        registry.registerAgent(served, keccak256("m"), 100e6);
        bytes32 unserved = registry.createFeed("unserved", keccak256("m"), 10e6, 1 hours, deployer);
        registry.registerAgent(unserved, keccak256("m"), 100e6);
        vm.stopBroadcast();

        vm.startBroadcast(OTHER_AGENT);
        usdc.approve(address(registry), type(uint256).max);
        bytes32 foreign = registry.createFeed("foreign", keccak256("m"), 10e6, 1 hours, deployer);
        registry.registerAgent(foreign, keccak256("m"), 100e6);
        vm.stopBroadcast();

        vm.startBroadcast(TRADER);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(5_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        uint256 expiry = block.timestamp + 2 hours;
        bytes32 mServed = markets.createMarket(1, served, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, expiry, 100e6);
        bytes32 mUnserved = markets.createMarket(1, unserved, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, expiry, 100e6);
        bytes32 mForeign = markets.createMarket(1, foreign, otherAgent, 1, MarketsPerennial.Comparator.GreaterOrEqual, expiry, 100e6);
        markets.buy(mServed, MarketsPerennial.Outcome.Yes, 500e6, 0);
        markets.buy(mUnserved, MarketsPerennial.Outcome.No, 500e6, 0);
        vm.stopBroadcast();

        console2.log("REHEARSAL markets", address(markets));
        console2.log("REHEARSAL attestation", address(attestation));
        console2.log("REHEARSAL ledger", address(ledger));
        console2.log("REHEARSAL pool", address(pool));
        console2.log("REHEARSAL agent", agent);
        console2.log("REHEARSAL served_feed", vm.toString(served));
        console2.log("REHEARSAL m_served", vm.toString(mServed));
        console2.log("REHEARSAL m_unserved", vm.toString(mUnserved));
        console2.log("REHEARSAL m_foreign", vm.toString(mForeign));
    }
}
