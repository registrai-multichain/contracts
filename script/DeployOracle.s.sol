// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";

/// @notice Step 1 of the mainnet order. Deploys a fresh oracle stack —
///         Registry(usdc, minBond) + Attestation + Dispute — and wires it.
///         No legacy Markets and no deployer treasury (unlike Deploy.s.sol).
///
/// Registry and Attestation give their deployer two one-shot powers: `wire`
/// and `setPoints`. Both are consumed here (setPoints with POINTS, which may be
/// the zero address to run without points), so the deployer keeps no power
/// over the oracle stack; Handoff.s.sol / VerifyRoles.s.sol assert it.
///
/// @dev env (MAINNET = required, no default; otherwise default in brackets):
///      USDC       [0x3600…0000]  must be 0x3600…0000 on mainnet
///      MIN_BOND   MAINNET [10e6] Registry's floor for any feed's minBond (6-dec)
///      POINTS     MAINNET [0x0]  points contract; 0x0 = no points, sealed forever
contract DeployOracle is DeployBase {
    struct Config {
        address deployer;
        address usdc;
        uint256 minBond;
        address points;
    }

    function run() external returns (Registry registry, Attestation attestation, Dispute dispute) {
        _guardChain();
        Config memory c = Config({
            deployer: msg.sender,
            usdc: vm.envOr("USDC", ARC_USDC),
            minBond: _uintReq("MIN_BOND", 10e6),
            points: _addrReq("POINTS", address(0))
        });
        (registry, attestation, dispute) = deploy(c);
        console2.log("Registry   :", address(registry));
        console2.log("Attestation:", address(attestation));
        console2.log("Dispute    :", address(dispute));
        console2.log("  usdc     :", c.usdc);
        console2.log("  minBond  :", c.minBond);
        console2.log("  points   :", c.points);
    }

    function deploy(Config memory c) public returns (Registry registry, Attestation attestation, Dispute dispute) {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        require(c.minBond > 0, "MIN_BOND must be > 0");
        if (_isMainnet()) require(c.usdc == ARC_USDC, "mainnet USDC must be 0x3600...0000");

        vm.startBroadcast(c.deployer);
        registry = new Registry(IERC20(c.usdc), c.minBond);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, IERC20(c.usdc));
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        registry.setPoints(c.points);
        attestation.setPoints(c.points);
        vm.stopBroadcast();

        require(registry.attestation() == address(attestation) && registry.dispute() == address(dispute), "wire");
        require(attestation.dispute() == address(dispute), "wire");
        require(registry.pointsSet() && attestation.pointsSet(), "points not sealed");
        require(registry.MIN_BOND() == c.minBond, "minBond");
    }
}
