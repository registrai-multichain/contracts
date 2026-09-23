// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {OracleStake} from "../src/oraclestake/OracleStake.sol";

/// @notice Deploys OracleStake (tiered pooled stake + per-oracle floor) wired to
///         the already-deployed Registry/Attestation. ZERO changes to deployed
///         contracts: OracleStake becomes the feed creator + bonded agent of
///         record, and markets consume it via agent = address(OracleStake).
///
/// @dev env: RPC, PRIVATE_KEY (deployer/protocol), REGISTRY, ATTESTATION;
///      optional USDC (defaults to Registry.USDC), NEUTRAL_RESOLVER (the protocol
///      dispute resolver, NEVER a staker; defaults to deployer on testnet),
///      FEE_SINK (defaults to deployer), KEEPER, TIMELOCK_DELAY (default 2 days),
///      FLOOR_CONST (default 20e6), SLASH_PENALTY_BPS (default 5000),
///      MAX_DEPLOYS_PER_EPOCH + EPOCH_LENGTH (default off).
///      HANDOFF=true hands GOVERNOR/ADMIN to a TimelockController and the
///      deployer renounces EOA powers; HANDOFF=false (testnet) keeps them.
contract DeployOracleStake is Script {
    function run() external returns (OracleStake os, TimelockController timelock) {
        address registryAddr = vm.envAddress("REGISTRY");
        address attestationAddr = vm.envAddress("ATTESTATION");
        require(registryAddr != address(0) && attestationAddr != address(0), "registry/attestation not set");

        Registry registry = Registry(registryAddr);
        address usdc = vm.envOr("USDC", address(registry.USDC()));
        address neutralResolver = vm.envOr("NEUTRAL_RESOLVER", msg.sender);
        address feeSink = vm.envOr("FEE_SINK", msg.sender);
        address keeper = vm.envOr("KEEPER", msg.sender);
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(2 days));
        uint256 floorConst = vm.envOr("FLOOR_CONST", uint256(20e6));
        uint256 slashBps = vm.envOr("SLASH_PENALTY_BPS", uint256(5_000));
        uint256 maxDeploys = vm.envOr("MAX_DEPLOYS_PER_EPOCH", uint256(0));
        uint256 epochLen = vm.envOr("EPOCH_LENGTH", uint256(1 days));
        bool handoff = vm.envOr("HANDOFF", true);

        vm.startBroadcast();

        // 1. Deploy — deployer is initial admin/governor/keeper.
        os = new OracleStake(
            IERC20(usdc),
            registry,
            Attestation(attestationAddr),
            msg.sender,
            neutralResolver,
            feeSink
        );

        // 2. Tier table. Recommended defaults with headroom over maxOracles*floor
        //    (so one slash never instantly demotes a deployer to a hard breach).
        //    Tune later via governor.setTiers.
        OracleStake.Tier[] memory tiers = new OracleStake.Tier[](3);
        tiers[0] = OracleStake.Tier({minStake: 125e6, maxOracles: 5});    // Starter
        tiers[1] = OracleStake.Tier({minStake: 1_000e6, maxOracles: 20}); // Builder
        tiers[2] = OracleStake.Tier({minStake: 5_000e6, maxOracles: 100});// Pro
        os.setTiers(tiers);

        // 3. Optional parameter overrides while deployer still holds GOVERNOR.
        if (floorConst != 20e6) os.setFloorConst(floorConst);
        if (slashBps != 5_000) os.setSlashPenaltyBps(slashBps);
        if (maxDeploys > 0) os.setDeployRateLimit(maxDeploys, epochLen);
        if (keeper != msg.sender) os.grantRole(os.KEEPER_ROLE(), keeper);

        if (handoff) {
            address[] memory props = new address[](1);
            props[0] = msg.sender;
            address[] memory execs = new address[](1);
            execs[0] = msg.sender;
            timelock = new TimelockController(delay, props, execs, address(0));

            os.grantRole(os.GOVERNOR_ROLE(), address(timelock));
            os.grantRole(os.DEFAULT_ADMIN_ROLE(), address(timelock));
            os.renounceRole(os.GOVERNOR_ROLE(), msg.sender);
            os.renounceRole(os.DEFAULT_ADMIN_ROLE(), msg.sender);
        }

        vm.stopBroadcast();

        console2.log("OracleStake:", address(os));
        console2.log("  registry:", registryAddr);
        console2.log("  attestation:", attestationAddr);
        console2.log("  neutralResolver:", neutralResolver);
        console2.log("  feeSink:", feeSink);
        console2.log("  floorConst:", os.floorConst());
        console2.log("  slashPenaltyBps:", os.slashPenaltyBps());
        console2.log("TimelockController (GOVERNOR):", address(timelock));
        if (neutralResolver == msg.sender) {
            console2.log("WARNING: neutralResolver == deployer. Set NEUTRAL_RESOLVER to a real protocol resolver before mainnet.");
        }
    }
}
