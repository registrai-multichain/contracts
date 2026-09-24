// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";

/// The legacy (July 14) ProgressPool / ProgressArbiter, by role surface only:
/// their sources left the repo with the builder-income redesign (git history).
interface ILegacyProgressPool is IAccessControl {
    function PROGRESS_ROLE() external view returns (bytes32);
}

interface ILegacyProgressArbiter is IAccessControl {
    function PROPOSER_ROLE() external view returns (bytes32);
    function RESOLVER_ROLE() external view returns (bytes32);
}

/// @notice Emergency mitigation for the immutable July 14 deployment while a
/// hardened replacement is prepared. This closes the deployer's direct progress
/// role, assigns builder 2 to the real operator, and separates proposer/resolver.
/// It cannot add the registry checks compiled into the replacement contracts.
contract HardenLegacyRobinhood is Script {
    function run() external {
        ILegacyProgressPool pool = ILegacyProgressPool(vm.envAddress("PROGRESS_POOL"));
        ILegacyProgressArbiter arbiter = ILegacyProgressArbiter(vm.envAddress("PROGRESS_ARBITER"));
        CaretakerRegistry caretakers = CaretakerRegistry(vm.envAddress("CARETAKER_REGISTRY"));
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address resolver = vm.envAddress("RESOLVER_ADDRESS");
        uint256 builderId = vm.envOr("BUILDER_ID", uint256(2));
        address admin = msg.sender;

        require(operator != address(0) && resolver != address(0), "operator/resolver required");
        require(operator != admin && resolver != admin && operator != resolver, "identities must be distinct");

        vm.startBroadcast();
        caretakers.setCaretaker(builderId, operator);
        arbiter.grantRole(arbiter.PROPOSER_ROLE(), operator);
        arbiter.grantRole(arbiter.RESOLVER_ROLE(), resolver);
        if (arbiter.hasRole(arbiter.PROPOSER_ROLE(), admin)) {
            arbiter.revokeRole(arbiter.PROPOSER_ROLE(), admin);
        }
        if (arbiter.hasRole(arbiter.RESOLVER_ROLE(), admin)) {
            arbiter.revokeRole(arbiter.RESOLVER_ROLE(), admin);
        }
        if (pool.hasRole(pool.PROGRESS_ROLE(), admin)) {
            pool.revokeRole(pool.PROGRESS_ROLE(), admin);
        }
        vm.stopBroadcast();

        require(!pool.hasRole(pool.PROGRESS_ROLE(), admin), "direct progress role remains");
        require(caretakers.isCaretaker(builderId, operator), "caretaker not assigned");
        console2.log("Legacy deployer progress bypass revoked; replacement redeploy is still required.");
    }
}
