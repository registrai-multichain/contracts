// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../src/perennial/VerifiedBuilderBadge.sol";

/// @notice Mainnet PHASE 1 — builders before markets. Deploys only the builder
///         side: BuilderRegistry + CaretakerRegistry + VerifiedBuilderBadge, so
///         builders can claim, be onboarded by the Safe and hold their badge
///         (the /builders gallery) while no market, pool, oracle or milestone
///         feed exists on the chain yet.
///
/// Every role goes straight to ADMIN in the constructors (STATUS on the badge to
/// the keeper's OPERATOR); the deployer holds nothing afterwards (asserted), so
/// phase 1 needs no Handoff. Phase 2 (the markets) runs the normal order with
/// DeployPerennial reusing these registries via BUILDER_REGISTRY /
/// CARETAKER_REGISTRY — builder ids, caretakers and badges carry over.
///
/// @dev env (MAINNET = required on 5042, no default; else default in brackets):
///      ADMIN, OPERATOR        always required; distinct; ADMIN a contract on mainnet
///      BADGE_CHAIN_LABEL      MAINNET ["Arc Testnet" / "Local"]
///      BADGE_IMAGE_BASE       MAINNET ["https://registrai.cc/badge/arc-testnet/"]
///      BADGE_EXTERNAL_BASE    MAINNET ["https://registrai.cc/builders/?builder="]
contract DeployBuilders is DeployBase {
    struct Config {
        address deployer;
        address admin;
        address operator;
        string chainLabel;
        string imageBase;
        string externalBase;
    }

    function run() external returns (BuilderRegistry builders, CaretakerRegistry caretakers, VerifiedBuilderBadge badge) {
        Config memory c = load(msg.sender);
        (builders, caretakers, badge) = deploy(c);
        console2.log("BuilderRegistry:     ", address(builders));
        console2.log("CaretakerRegistry:   ", address(caretakers));
        console2.log("VerifiedBuilderBadge:", address(badge));
        console2.log("  admin (all roles): ", c.admin);
        console2.log("  badge status operator:", c.operator);
        console2.log("  imageBase:", c.imageBase);
        console2.log("  externalBase:", c.externalBase);
    }

    function load(address deployer) public view returns (Config memory c) {
        _guardChain();
        c.deployer = deployer;
        c.admin = vm.envAddress("ADMIN");
        c.operator = vm.envAddress("OPERATOR");
        c.chainLabel = _strReq("BADGE_CHAIN_LABEL", block.chainid == ARC_TESTNET ? "Arc Testnet" : "Local");
        c.imageBase = _strReq("BADGE_IMAGE_BASE", "https://registrai.cc/badge/arc-testnet/");
        c.externalBase = _strReq("BADGE_EXTERNAL_BASE", "https://registrai.cc/builders/?builder=");
    }

    function deploy(Config memory c)
        public
        returns (BuilderRegistry builders, CaretakerRegistry caretakers, VerifiedBuilderBadge badge)
    {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        require(c.admin != address(0) && c.operator != address(0), "ADMIN/OPERATOR not set");
        require(c.admin != c.operator, "ADMIN and OPERATOR must differ: the operator may only set badge status");
        require(c.admin != c.deployer, "ADMIN must not be the deployer");
        if (_isMainnet()) {
            require(c.admin.code.length > 0, "mainnet: ADMIN must be a contract (Safe/timelock), not an EOA");
            require(c.operator != c.deployer, "mainnet: OPERATOR must not be the deployer");
        }

        vm.startBroadcast(c.deployer);
        builders = new BuilderRegistry(c.admin);
        caretakers = new CaretakerRegistry(builders, c.admin);
        badge = new VerifiedBuilderBadge(builders, c.admin, c.operator, c.chainLabel, c.imageBase, c.externalBase);
        vm.stopBroadcast();

        // ADMIN holds everything, the deployer nothing, the operator only badge STATUS.
        bytes32 da = 0x00;
        require(builders.hasRole(da, c.admin) && builders.hasRole(builders.REGISTRAR_ROLE(), c.admin), "admin lacks builder roles");
        require(caretakers.hasRole(da, c.admin) && caretakers.hasRole(caretakers.GOVERNOR_ROLE(), c.admin), "admin lacks caretaker roles");
        require(badge.hasRole(da, c.admin) && badge.hasRole(badge.ISSUER_ROLE(), c.admin), "admin lacks badge roles");
        require(badge.hasRole(badge.STATUS_ROLE(), c.operator), "operator lacks badge STATUS");
        require(!badge.hasRole(badge.ISSUER_ROLE(), c.operator) && !badge.hasRole(da, c.operator), "operator must only set status");
        require(
            !builders.hasRole(da, c.deployer) && !builders.hasRole(builders.REGISTRAR_ROLE(), c.deployer)
                && !caretakers.hasRole(da, c.deployer) && !caretakers.hasRole(caretakers.GOVERNOR_ROLE(), c.deployer)
                && !badge.hasRole(da, c.deployer) && !badge.hasRole(badge.ISSUER_ROLE(), c.deployer),
            "deployer holds a role"
        );
        require(address(caretakers.BUILDERS()) == address(builders) && address(badge.BUILDERS()) == address(builders), "wiring");
    }
}
