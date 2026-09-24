// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {ProgressPool} from "../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";
import {ProgressArbiter} from "../src/perennial/ProgressArbiter.sol";

/// @notice Deploys ProgressArbiter against an ALREADY-DEPLOYED Perennial stack
///         and closes the trusted-progress seam behind it.
///
/// `DeployPerennial.s.sol` deploys the pool without an arbiter, which leaves
/// whoever holds PROGRESS_ROLE able to credit arbitrary weight and claim it —
/// the same "deployer progress-role bypass" recorded against the legacy
/// Robinhood deployment. `DeployRobinhood.s.sol` avoids it by deploying the
/// arbiter inline and asserting the deployer does NOT retain the role, but that
/// script deploys a whole stack from scratch. This is the missing piece for an
/// existing one.
///
/// After this runs, weight can reach the pool ONLY through
/// propose -> (challenge window) -> finalize, backed by a proposer bond.
///
/// @dev env: PRIVATE_KEY, NANO_LEDGER, PROGRESS_POOL, BUILDER_REGISTRY,
///      CARETAKER_REGISTRY, PROPOSER, RESOLVER; optional CHALLENGE_WINDOW
///      (default 1h), STAKE_PER_PROPOSAL (default 50 USDC),
///      MAX_WEIGHT_PER_PROPOSAL (default 10).
contract DeployArbiter is Script {
    function run() external returns (ProgressArbiter arbiter) {
        NanoLedger ledger = NanoLedger(vm.envAddress("NANO_LEDGER"));
        ProgressPool pool = ProgressPool(vm.envAddress("PROGRESS_POOL"));
        BuilderRegistry builders = BuilderRegistry(vm.envAddress("BUILDER_REGISTRY"));
        CaretakerRegistry caretakers = CaretakerRegistry(vm.envAddress("CARETAKER_REGISTRY"));
        address proposer = vm.envAddress("PROPOSER");
        address resolver = vm.envAddress("RESOLVER");
        uint256 challengeWindow = vm.envOr("CHALLENGE_WINDOW", uint256(1 hours));
        uint256 stakePerProposal = vm.envOr("STAKE_PER_PROPOSAL", uint256(50e6));
        uint256 maxWeight = vm.envOr("MAX_WEIGHT_PER_PROPOSAL", uint256(10));
        uint256 resolveTimeout = vm.envOr("RESOLVE_TIMEOUT", uint256(7 days));

        // Separation of duties is the whole point: the party that proposes
        // progress must not also be the party that adjudicates a challenge to it.
        require(proposer != resolver, "proposer == resolver");

        vm.startBroadcast();

        arbiter = new ProgressArbiter(
            ledger, pool, builders, caretakers, msg.sender, challengeWindow, stakePerProposal, maxWeight, resolveTimeout
        );

        // The arbiter becomes the ONLY writer of progress into the pool...
        pool.grantRole(pool.PROGRESS_ROLE(), address(arbiter));
        // ...which only means anything once the direct seam is closed.
        pool.revokeRole(pool.PROGRESS_ROLE(), msg.sender);

        arbiter.grantRole(arbiter.PROPOSER_ROLE(), proposer);
        arbiter.grantRole(arbiter.RESOLVER_ROLE(), resolver);

        vm.stopBroadcast();

        // Mirrors the assertion in DeployRobinhood.s.sol. If this trips, the
        // bypass is still open and the deployment must not be used.
        require(!pool.hasRole(pool.PROGRESS_ROLE(), msg.sender), "deployer progress bypass");
        require(pool.hasRole(pool.PROGRESS_ROLE(), address(arbiter)), "arbiter not wired");

        console2.log("ProgressArbiter:", address(arbiter));
        console2.log("  challengeWindow:", challengeWindow);
        console2.log("  stakePerProposal:", stakePerProposal);
        console2.log("  maxWeightPerProposal:", maxWeight);
        console2.log("  proposer:", proposer);
        console2.log("  resolver:", resolver);
        console2.log("  deployer still has PROGRESS_ROLE:", pool.hasRole(pool.PROGRESS_ROLE(), msg.sender));
    }
}
