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
///         settled on the ledger). Fees are fixed in code (1% at resolution,
///         30 creator / 20 agent / 50 TREASURY); agents are permissionless, so
///         the only oracle input is the approved dispute resolver. MarketsV4
///         needs no ledger role. The deployer holds MarketsV4's admin/governor
///         until Handoff.s.sol.
///
/// @dev env (MAINNET = required on 5042, no default; else default in brackets):
///      REGISTRY, ATTESTATION   always required
///      NANO_LEDGER             MAINNET [deploy a new one] — on mainnet V4 and
///                              Perennial must share one ledger
///      USDC                    [0x3600…0000] only used when deploying a ledger
///      TREASURY                MAINNET [deployer] the Registrai treasury (50%
///                              leg); immutable; never the deployer on mainnet
///      SETTLEMENT_WINDOW       MAINNET [24h]
///      RESOLUTION_GRACE        MAINNET [7d]
///      DISPUTE_RESOLVER        MAINNET [deployer] resolver feeds must name;
///                              never the deployer on mainnet
contract DeployNanoStack is DeployBase {
    struct Config {
        address deployer;
        address usdc;
        address registry;
        address attestation;
        address ledger; // address(0) = deploy a new one (testnet/local only)
        address treasury;
        uint256 settlementWindow;
        uint256 resolutionGrace;
        address disputeResolver;
    }

    function run() external returns (NanoLedger ledger, MarketsV4 markets) {
        Config memory c = load(msg.sender);
        (ledger, markets) = deploy(c);
        console2.log("NanoLedger:", address(ledger));
        console2.log("MarketsV4: ", address(markets));
        console2.log("  treasury:", c.treasury);
        console2.log("  settlementWindow:", c.settlementWindow);
        console2.log("  resolutionGrace:", c.resolutionGrace);
        console2.log("  disputeResolver:", c.disputeResolver);
    }

    function load(address deployer) public view returns (Config memory c) {
        _guardChain();
        c.deployer = deployer;
        c.usdc = vm.envOr("USDC", ARC_USDC);
        c.registry = vm.envAddress("REGISTRY");
        c.attestation = vm.envAddress("ATTESTATION");
        c.ledger = _addrReq("NANO_LEDGER", address(0));
        c.treasury = _addrReq("TREASURY", deployer);
        c.settlementWindow = _uintReq("SETTLEMENT_WINDOW", 24 hours);
        c.resolutionGrace = _uintReq("RESOLUTION_GRACE", 7 days);
        c.disputeResolver = _addrReq("DISPUTE_RESOLVER", deployer);
    }

    function deploy(Config memory c) public returns (NanoLedger ledger, MarketsV4 markets) {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        require(c.registry != address(0) && c.attestation != address(0), "registry/attestation not set");
        require(c.treasury != address(0) && c.disputeResolver != address(0), "treasury/resolver not set");
        if (_isMainnet()) {
            require(c.ledger != address(0), "mainnet: NANO_LEDGER must be the shared ledger");
            require(c.treasury != c.deployer, "mainnet: TREASURY must not be the deployer");
            require(c.disputeResolver != c.deployer, "mainnet: DISPUTE_RESOLVER must not be the deployer");
        }

        vm.startBroadcast(c.deployer);
        ledger = c.ledger != address(0) ? NanoLedger(c.ledger) : new NanoLedger(IERC20(c.usdc), c.deployer);
        markets = new MarketsV4(
            ledger,
            Registry(c.registry),
            Attestation(c.attestation),
            c.deployer,
            c.treasury,
            c.settlementWindow,
            c.resolutionGrace
        );
        markets.setApprovedResolver(c.disputeResolver, true);
        vm.stopBroadcast();
    }
}
