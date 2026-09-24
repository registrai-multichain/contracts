// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {ProgressPool} from "../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";
import {ProgressArbiter} from "../src/perennial/ProgressArbiter.sol";

/// @notice Step 4 of the mainnet order. Deploys ProgressArbiter against the
///         Perennial stack and makes it the only writer of progress into the
///         pool: weight then reaches the pool ONLY through
///         propose -> (challenge window) -> finalize, backed by a proposer bond.
///
/// ProgressPool never grants PROGRESS_ROLE to anyone at construction, so the
/// only holder after this script is the arbiter (asserted). The deployer keeps
/// DEFAULT_ADMIN on pool and arbiter until Handoff.s.sol moves them to ADMIN;
/// Handoff/VerifyRoles then assert the deployer holds nothing.
///
/// @dev env (MAINNET = required on 5042, no default; else default in brackets):
///      NANO_LEDGER, PROGRESS_POOL, BUILDER_REGISTRY, CARETAKER_REGISTRY   always required
///      PROPOSER, RESOLVER  always required; distinct; never the deployer on mainnet
///      CHALLENGE_WINDOW         MAINNET [1h]
///      STAKE_PER_PROPOSAL       MAINNET [50e6]  6-dec USDC
///      MAX_WEIGHT_PER_PROPOSAL  MAINNET [10]
///      RESOLVE_TIMEOUT          MAINNET [7d]   immutable; after it anyone may
///                                              expire an unruled challenge
contract DeployArbiter is DeployBase {
    struct Config {
        address deployer;
        address ledger;
        address pool;
        address builders;
        address caretakers;
        address proposer;
        address resolver;
        uint256 challengeWindow;
        uint256 stakePerProposal;
        uint256 maxWeight;
        uint256 resolveTimeout;
    }

    function run() external returns (ProgressArbiter arbiter) {
        Config memory c = load(msg.sender);
        arbiter = deploy(c);
        console2.log("ProgressArbiter:", address(arbiter));
        console2.log("  challengeWindow:", c.challengeWindow);
        console2.log("  stakePerProposal:", c.stakePerProposal);
        console2.log("  maxWeightPerProposal:", c.maxWeight);
        console2.log("  resolveTimeout:", c.resolveTimeout);
        console2.log("  proposer:", c.proposer);
        console2.log("  resolver:", c.resolver);
    }

    function load(address deployer) public view returns (Config memory c) {
        _guardChain();
        c.deployer = deployer;
        c.ledger = vm.envAddress("NANO_LEDGER");
        c.pool = vm.envAddress("PROGRESS_POOL");
        c.builders = vm.envAddress("BUILDER_REGISTRY");
        c.caretakers = vm.envAddress("CARETAKER_REGISTRY");
        c.proposer = vm.envAddress("PROPOSER");
        c.resolver = vm.envAddress("RESOLVER");
        c.challengeWindow = _uintReq("CHALLENGE_WINDOW", 1 hours);
        c.stakePerProposal = _uintReq("STAKE_PER_PROPOSAL", 50e6);
        c.maxWeight = _uintReq("MAX_WEIGHT_PER_PROPOSAL", 10);
        c.resolveTimeout = _uintReq("RESOLVE_TIMEOUT", 7 days);
    }

    function deploy(Config memory c) public returns (ProgressArbiter arbiter) {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        require(c.proposer != address(0) && c.resolver != address(0), "proposer/resolver not set");
        // Separation of duties is the whole point: the party that proposes
        // progress must not also be the party that adjudicates a challenge to it.
        require(c.proposer != c.resolver, "proposer == resolver");
        if (_isMainnet()) {
            require(c.proposer != c.deployer && c.resolver != c.deployer, "mainnet: deployer must not propose/resolve");
        }
        ProgressPool pool = ProgressPool(c.pool);

        vm.startBroadcast(c.deployer);
        arbiter = new ProgressArbiter(
            NanoLedger(c.ledger),
            pool,
            BuilderRegistry(c.builders),
            CaretakerRegistry(c.caretakers),
            c.deployer,
            c.challengeWindow,
            c.stakePerProposal,
            c.maxWeight,
            c.resolveTimeout
        );
        pool.grantRole(pool.PROGRESS_ROLE(), address(arbiter));
        arbiter.grantRole(arbiter.PROPOSER_ROLE(), c.proposer);
        arbiter.grantRole(arbiter.RESOLVER_ROLE(), c.resolver);
        vm.stopBroadcast();

        require(pool.hasRole(pool.PROGRESS_ROLE(), address(arbiter)), "arbiter not wired");
        require(arbiter.RESOLVE_TIMEOUT() == c.resolveTimeout, "timeout");
    }
}
