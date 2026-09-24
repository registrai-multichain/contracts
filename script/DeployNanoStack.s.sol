// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../src/nanopay/MarketsV4.sol";

/// @notice Step 5 of the mainnet order. Deploys MarketsV4 (common markets
///         settled on the ledger) and registers it as a NanoLedger source. The
///         deployer holds MarketsV4's admin/governor and the ledger's governor
///         until Handoff.s.sol.
///
/// @dev env (MAINNET = required on 5042, no default; else default in brackets):
///      REGISTRY, ATTESTATION   always required
///      FORFEIT_SINK            always required (no default anywhere): receives
///                              the agent fee of every market the agent fails
///                              to settle; the commons (ProgressPool). Must not
///                              be the treasury or the deployer.
///      NANO_LEDGER             MAINNET [deploy a new one] — on mainnet V4 and
///                              Perennial must share one ledger
///      USDC                    [0x3600…0000] only used when deploying a ledger
///      TREASURY                MAINNET [deployer]; never the deployer on mainnet
///      SETTLEMENT_WINDOW       MAINNET [24h]
///      RESOLUTION_GRACE        MAINNET [7d]
///      V4_FEE_CREATOR_BPS / V4_FEE_AGENT_BPS / V4_FEE_TREASURY_BPS
///                              MAINNET [40/20/10] must sum to 70
///      APPROVED_AGENT          MAINNET [deployer]
///      DISPUTE_RESOLVER        MAINNET [deployer]
contract DeployNanoStack is DeployBase {
    struct Config {
        address deployer;
        address usdc;
        address registry;
        address attestation;
        address ledger; // address(0) = deploy a new one (testnet/local only)
        address treasury;
        address forfeitSink;
        uint256 settlementWindow;
        uint256 resolutionGrace;
        uint256 feeCreatorBps;
        uint256 feeAgentBps;
        uint256 feeTreasuryBps;
        address approvedAgent;
        address disputeResolver;
    }

    function run() external returns (NanoLedger ledger, MarketsV4 markets) {
        Config memory c = load(msg.sender);
        (ledger, markets) = deploy(c);
        console2.log("NanoLedger:", address(ledger));
        console2.log("MarketsV4: ", address(markets));
        console2.log("  treasury:", c.treasury);
        console2.log("  forfeitSink:", c.forfeitSink);
        console2.log("  settlementWindow:", c.settlementWindow);
        console2.log("  resolutionGrace:", c.resolutionGrace);
        console2.log("  fee creator/agent/treasury bps:", c.feeCreatorBps, c.feeAgentBps, c.feeTreasuryBps);
        console2.log("  approvedAgent:", c.approvedAgent);
        console2.log("  disputeResolver:", c.disputeResolver);
    }

    function load(address deployer) public view returns (Config memory c) {
        _guardChain();
        c.deployer = deployer;
        c.usdc = vm.envOr("USDC", ARC_USDC);
        c.registry = vm.envAddress("REGISTRY");
        c.attestation = vm.envAddress("ATTESTATION");
        c.forfeitSink = vm.envAddress("FORFEIT_SINK");
        c.ledger = _addrReq("NANO_LEDGER", address(0));
        c.treasury = _addrReq("TREASURY", deployer);
        c.settlementWindow = _uintReq("SETTLEMENT_WINDOW", 24 hours);
        c.resolutionGrace = _uintReq("RESOLUTION_GRACE", 7 days);
        c.feeCreatorBps = _uintReq("V4_FEE_CREATOR_BPS", 40);
        c.feeAgentBps = _uintReq("V4_FEE_AGENT_BPS", 20);
        c.feeTreasuryBps = _uintReq("V4_FEE_TREASURY_BPS", 10);
        c.approvedAgent = _addrReq("APPROVED_AGENT", deployer);
        c.disputeResolver = _addrReq("DISPUTE_RESOLVER", deployer);
    }

    function deploy(Config memory c) public returns (NanoLedger ledger, MarketsV4 markets) {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        require(c.registry != address(0) && c.attestation != address(0), "registry/attestation not set");
        require(c.approvedAgent != address(0) && c.disputeResolver != address(0), "agent/resolver not set");
        require(
            c.forfeitSink != c.treasury && c.forfeitSink != c.deployer, "forfeit sink must not be protocol revenue"
        );
        if (_isMainnet()) {
            require(c.ledger != address(0), "mainnet: NANO_LEDGER must be the shared ledger");
            require(c.treasury != c.deployer, "mainnet: TREASURY must not be the deployer");
            require(c.disputeResolver != c.deployer, "mainnet: DISPUTE_RESOLVER must not be the deployer");
            require(c.approvedAgent != c.deployer, "mainnet: APPROVED_AGENT must not be the deployer");
            require(c.disputeResolver != c.approvedAgent, "mainnet: agent must not resolve its own disputes");
        }

        vm.startBroadcast(c.deployer);
        ledger = c.ledger != address(0) ? NanoLedger(c.ledger) : new NanoLedger(IERC20(c.usdc), c.deployer);
        markets = new MarketsV4(
            ledger,
            Registry(c.registry),
            Attestation(c.attestation),
            c.deployer,
            c.treasury,
            c.forfeitSink,
            c.settlementWindow,
            c.resolutionGrace,
            c.feeCreatorBps,
            c.feeAgentBps,
            c.feeTreasuryBps
        );
        ledger.setSource(address(markets), true);
        markets.setApprovedAgent(c.approvedAgent, true);
        markets.setApprovedResolver(c.disputeResolver, true);
        vm.stopBroadcast();

        require(ledger.isSource(address(markets)), "v4 not a ledger source");
    }
}
