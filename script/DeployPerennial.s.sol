// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../src/nanopay/MarketsPerennial.sol";
import {ProgressPool} from "../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";

/// @notice Step 3 of the mainnet order. Deploys Perennial: BuilderRegistry +
///         CaretakerRegistry + ProgressPool (the commons) + MarketsPerennial
///         (whose treasury leg routes to the pool), over the NanoLedger and the
///         oracle stack. The deployer holds every admin role until Handoff.s.sol.
///
/// @dev env (MAINNET = required on 5042, no default; else default in brackets):
///      REGISTRY, ATTESTATION, NANO_LEDGER      always required
///      EPOCH_LENGTH        MAINNET [0]    seconds; must be > 0 on mainnet — with
///                                         0, finalize + closeEpoch in one tx
///                                         grabs the whole pot
///      STREAM_WINDOW       MAINNET [30d]  claim vesting window, seconds
///      SETTLEMENT_WINDOW   MAINNET [24h]  immutable, 1h..7d
///      RESOLUTION_GRACE    MAINNET [7d]   immutable, 1d..30d
///      PERENNIAL_FEE_CREATOR_BPS / PERENNIAL_FEE_TREASURY_BPS / PERENNIAL_FEE_AGENT_BPS
///                          MAINNET [20/35/15] must sum to 70
///      PERENNIAL_FORFEIT_SINK MAINNET ["commons"] "commons" (= the new pool) or
///                                         an address; never the deployer on mainnet
///      APPROVED_AGENT      MAINNET [deployer] agent allowed to settle markets
///      DISPUTE_RESOLVER    MAINNET [deployer] resolver feeds must name
contract DeployPerennial is DeployBase {
    struct Config {
        address deployer;
        address registry;
        address attestation;
        address ledger;
        uint256 epochLength;
        uint256 streamWindow;
        uint256 settlementWindow;
        uint256 resolutionGrace;
        uint256 feeCreatorBps;
        uint256 feeTreasuryBps;
        uint256 feeAgentBps;
        address forfeitSink; // address(0) = the commons (the pool deployed here)
        address approvedAgent;
        address disputeResolver;
    }

    function run()
        external
        returns (BuilderRegistry builderReg, CaretakerRegistry caretakers, ProgressPool pool, MarketsPerennial markets)
    {
        Config memory c = load(msg.sender);
        (builderReg, caretakers, pool, markets) = deploy(c);
        console2.log("BuilderRegistry:  ", address(builderReg));
        console2.log("CaretakerRegistry:", address(caretakers));
        console2.log("ProgressPool:     ", address(pool));
        console2.log("MarketsPerennial: ", address(markets));
        console2.log("  commons -> pool:", markets.commons());
        console2.log("  forfeitSink:", markets.forfeitSink());
        console2.log("  epochLength:", c.epochLength);
        console2.log("  streamWindow:", c.streamWindow);
        console2.log("  settlementWindow:", c.settlementWindow);
        console2.log("  resolutionGrace:", c.resolutionGrace);
        console2.log("  approvedAgent:", c.approvedAgent);
        console2.log("  disputeResolver:", c.disputeResolver);
    }

    function load(address deployer) public view returns (Config memory c) {
        _guardChain();
        c.deployer = deployer;
        c.registry = vm.envAddress("REGISTRY");
        c.attestation = vm.envAddress("ATTESTATION");
        c.ledger = vm.envAddress("NANO_LEDGER");
        c.epochLength = _uintReq("EPOCH_LENGTH", 0);
        c.streamWindow = _uintReq("STREAM_WINDOW", 30 days);
        c.settlementWindow = _uintReq("SETTLEMENT_WINDOW", 24 hours);
        c.resolutionGrace = _uintReq("RESOLUTION_GRACE", 7 days);
        c.feeCreatorBps = _uintReq("PERENNIAL_FEE_CREATOR_BPS", 20);
        c.feeTreasuryBps = _uintReq("PERENNIAL_FEE_TREASURY_BPS", 35);
        c.feeAgentBps = _uintReq("PERENNIAL_FEE_AGENT_BPS", 15);
        string memory sink = _strReq("PERENNIAL_FORFEIT_SINK", "commons");
        c.forfeitSink = keccak256(bytes(sink)) == keccak256("commons") ? address(0) : vm.parseAddress(sink);
        c.approvedAgent = _addrReq("APPROVED_AGENT", deployer);
        c.disputeResolver = _addrReq("DISPUTE_RESOLVER", deployer);
    }

    function deploy(Config memory c)
        public
        returns (BuilderRegistry builderReg, CaretakerRegistry caretakers, ProgressPool pool, MarketsPerennial markets)
    {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        require(c.registry != address(0) && c.attestation != address(0) && c.ledger != address(0), "stack not set");
        require(c.approvedAgent != address(0) && c.disputeResolver != address(0), "agent/resolver not set");
        if (_isMainnet()) {
            require(c.epochLength > 0, "mainnet: EPOCH_LENGTH must be > 0");
            require(c.disputeResolver != c.deployer, "mainnet: DISPUTE_RESOLVER must not be the deployer");
            require(c.approvedAgent != c.deployer, "mainnet: APPROVED_AGENT must not be the deployer");
            require(c.disputeResolver != c.approvedAgent, "mainnet: agent must not resolve its own disputes");
            require(c.forfeitSink != c.deployer, "mainnet: forfeit sink must not be the deployer");
        }

        vm.startBroadcast(c.deployer);
        builderReg = new BuilderRegistry(c.deployer);
        caretakers = new CaretakerRegistry(builderReg, c.deployer);
        pool = new ProgressPool(NanoLedger(c.ledger), builderReg, caretakers, c.deployer, c.epochLength, c.streamWindow);
        markets = new MarketsPerennial(
            NanoLedger(c.ledger),
            Registry(c.registry),
            Attestation(c.attestation),
            builderReg,
            c.deployer,
            address(pool),
            c.settlementWindow,
            c.resolutionGrace
        );
        markets.setFeeSplit(c.feeCreatorBps, c.feeTreasuryBps, c.feeAgentBps);
        if (c.forfeitSink != address(0)) markets.setForfeitSink(c.forfeitSink);
        markets.setApprovedAgent(c.approvedAgent, true);
        markets.setApprovedResolver(c.disputeResolver, true);
        vm.stopBroadcast();
    }
}
