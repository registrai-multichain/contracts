// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {VerifiedBuilderBadge} from "../src/perennial/VerifiedBuilderBadge.sol";

/// @notice Deploys the soulbound VerifiedBuilderBadge. Standalone: it can run
///         any time after DeployPerennial (it only reads BuilderRegistry), and
///         needs no Handoff — the constructor grants DEFAULT_ADMIN + ISSUER to
///         ADMIN and STATUS to the keeper's OPERATOR; the deployer never holds
///         a role (asserted).
///
/// @dev env (MAINNET = required on 5042, no default; else default in brackets):
///      BUILDER_REGISTRY, ADMIN, OPERATOR   always required; distinct; neither the deployer on mainnet
///      BADGE_CHAIN_LABEL      MAINNET ["Arc Testnet" / "Local"]
///      BADGE_IMAGE_BASE       MAINNET ["https://registrai.cc/badge/arc-testnet/"]
///      BADGE_EXTERNAL_BASE    MAINNET ["https://builder.registrai.cc/builders/?builder="]
contract DeployBadge is DeployBase {
    struct Config {
        address deployer;
        address builders;
        address admin;
        address operator;
        string chainLabel;
        string imageBase;
        string externalBase;
    }

    function run() external returns (VerifiedBuilderBadge badge) {
        Config memory c = load(msg.sender);
        badge = deploy(c);
        console2.log("VerifiedBuilderBadge:", address(badge));
        console2.log("  admin/issuer:", c.admin);
        console2.log("  status operator:", c.operator);
        console2.log("  chainLabel:", c.chainLabel);
        console2.log("  imageBase:", c.imageBase);
        console2.log("  externalBase:", c.externalBase);
    }

    function load(address deployer) public view returns (Config memory c) {
        _guardChain();
        c.deployer = deployer;
        c.builders = vm.envAddress("BUILDER_REGISTRY");
        c.admin = vm.envAddress("ADMIN");
        c.operator = vm.envAddress("OPERATOR");
        c.chainLabel = _strReq("BADGE_CHAIN_LABEL", block.chainid == ARC_TESTNET ? "Arc Testnet" : "Local");
        c.imageBase = _strReq("BADGE_IMAGE_BASE", "https://registrai.cc/badge/arc-testnet/");
        c.externalBase = _strReq("BADGE_EXTERNAL_BASE", "https://builder.registrai.cc/builders/?builder=");
    }

    function deploy(Config memory c) public returns (VerifiedBuilderBadge badge) {
        _guardChain();
        require(c.builders.code.length > 0, "BUILDER_REGISTRY has no code");
        require(c.admin != address(0) && c.operator != address(0), "ADMIN/OPERATOR not set");
        require(c.admin != c.operator, "ADMIN and OPERATOR must differ: the operator may only set status");
        if (_isMainnet()) {
            require(c.admin.code.length > 0, "mainnet: ADMIN must be a contract (Safe/timelock), not an EOA");
            require(c.admin != c.deployer && c.operator != c.deployer, "mainnet: deployer must hold no badge role");
        }

        vm.startBroadcast(c.deployer);
        badge = new VerifiedBuilderBadge(
            BuilderRegistry(c.builders), c.admin, c.operator, c.chainLabel, c.imageBase, c.externalBase
        );
        vm.stopBroadcast();

        require(badge.hasRole(badge.ISSUER_ROLE(), c.admin), "admin lacks ISSUER");
        require(badge.hasRole(badge.DEFAULT_ADMIN_ROLE(), c.admin), "admin lacks DEFAULT_ADMIN");
        require(badge.hasRole(badge.STATUS_ROLE(), c.operator), "operator lacks STATUS");
        require(!badge.hasRole(badge.ISSUER_ROLE(), c.operator), "operator must not issue");
        if (c.deployer != c.admin) {
            require(!badge.hasRole(badge.DEFAULT_ADMIN_ROLE(), c.deployer), "deployer holds DEFAULT_ADMIN");
            require(!badge.hasRole(badge.ISSUER_ROLE(), c.deployer), "deployer holds ISSUER");
        }
    }
}
