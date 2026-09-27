// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {LaunchSchedule} from "./lib/LaunchSchedule.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../src/nanopay/MarketsPerennial.sol";
import {BuilderFund} from "../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../src/perennial/SeasonPool.sol";
import {BuilderRegistry} from "../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../src/perennial/WonderEscrow.sol";

/// @notice Phase 2, step 3 of the mainnet order. Deploys the Perennial markets
///         over the phase-1 registries: SeasonPool (the shared pool) +
///         BuilderFund (builder income, taxed progressively per epoch; the tax
///         feeds the SeasonPool) + MarketsPerennial (whose 50% builder leg of the
///         1% trading fee is credited in the fund to the builder the market is
///         about) + WonderEscrow (the builder leg of bound wonder markets, held
///         per nominated source for its team, per epoch earned; no yield vault).
///         Wires MarketsPerennial
///         and the escrow as the fund's MARKETS_ROLE holders, MarketsPerennial as
///         the escrow's only MARKETS_ROLE and the fund as the pool's only
///         FUNDER_ROLE; the operator gets FEED (bind feeds) and RELEASER,
///         the onboarder NOMINATOR. Fees and the launch tax schedule
///         are fixed in code (no fee inputs). The deployer holds every admin role
///         until Handoff.s.sol.
///
/// @dev env (MAINNET = required on 5042, no default; else default in brackets):
///      REGISTRY, ATTESTATION, NANO_LEDGER      always required
///      EPOCH_LENGTH        MAINNET [1h]   BuilderFund epoch, seconds, > 0
///                                         (mainnet: 30 days); immutable
///      SETTLEMENT_WINDOW   MAINNET [24h]  immutable, 1h..7d
///      RESOLUTION_GRACE    MAINNET [7d]   immutable, 1d..30d
///      PROTOCOL_TREASURY   MAINNET [deployer] receives the fund's 1% of every
///                                         builder payout; immutable; never the
///                                         deployer on mainnet
///      APPROVED_AGENT      MAINNET [deployer] agent allowed to settle markets
///      DISPUTE_RESOLVER    MAINNET [deployer] resolver feeds must name
///      BUILDER_REGISTRY, CARETAKER_REGISTRY   the phase-1 registries
///                          (DeployBuilders.s.sol); required on mainnet; elsewhere
///                          optional, both or neither (neither = deploy new ones).
///      VERIFIED_BADGE      the phase-1 VerifiedBuilderBadge; required on mainnet
///                          (with the registries); elsewhere zero = deploy a new one
///      WONDER_EXPIRY       [180 days] unclaimed wonder escrow is swept (90% season
///                          pool, 10% treasury) this long after its first credit; immutable
///      OPERATOR            MAINNET [deployer] binds feeds and queues escrow
///                          releases; never the deployer on mainnet
///      ONBOARDER           MAINNET [deployer] nominates wonder-market sources
///                          (with the Safe); never the deployer on mainnet
///      The launch tax schedule is lib/LaunchSchedule.sol (the spec's defaults); the
///      Safe changes it later with BuilderFund.setSchedule (2 epochs' notice).
contract DeployPerennial is DeployBase {
    struct Config {
        address deployer;
        address registry;
        address attestation;
        address ledger;
        uint256 epochLength;
        uint256 settlementWindow;
        uint256 resolutionGrace;
        address protocolTreasury;
        address approvedAgent;
        address disputeResolver;
        /// Existing phase-1 registries; zero = deploy new ones (not on mainnet).
        address builders;
        address caretakers;
        /// Existing phase-1 badge; zero = deploy a new one (not on mainnet).
        address badge;
        uint256 wonderExpiry;
        address operator;
        address onboarder;
    }

    struct Deployed {
        BuilderRegistry builders;
        CaretakerRegistry caretakers;
        SeasonPool seasonPool;
        BuilderFund fund;
        MarketsPerennial markets;
        VerifiedBuilderBadge badge;
        WonderEscrow escrow;
    }

    /// @notice The launch tax schedule (LaunchSchedule): 0% to $1,000; 10% to
    /// $10,000; 20% to $50,000; 30% above, per builder per epoch.
    function launchSchedule() public pure returns (BuilderFund.Bracket[] memory) {
        return LaunchSchedule.brackets();
    }

    function run() external returns (Deployed memory d) {
        Config memory c = load(msg.sender);
        d = deploy(c);
        console2.log("BuilderRegistry:  ", address(d.builders));
        console2.log("CaretakerRegistry:", address(d.caretakers));
        console2.log("SeasonPool:       ", address(d.seasonPool));
        console2.log("BuilderFund:      ", address(d.fund));
        console2.log("MarketsPerennial: ", address(d.markets));
        console2.log("VerifiedBuilderBadge:", address(d.badge));
        console2.log("WonderEscrow:     ", address(d.escrow));
        console2.log("  wonderExpiry:", c.wonderExpiry);
        console2.log("  operator:", c.operator);
        console2.log("  onboarder:", c.onboarder);
        console2.log("  protocolTreasury:", c.protocolTreasury);
        console2.log("  epochLength:", c.epochLength);
        console2.log("  fund START:", d.fund.START());
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
        c.epochLength = _uintReq("EPOCH_LENGTH", 1 hours);
        c.settlementWindow = _uintReq("SETTLEMENT_WINDOW", 24 hours);
        c.resolutionGrace = _uintReq("RESOLUTION_GRACE", 7 days);
        c.protocolTreasury = _addrReq("PROTOCOL_TREASURY", deployer);
        c.approvedAgent = _addrReq("APPROVED_AGENT", deployer);
        c.disputeResolver = _addrReq("DISPUTE_RESOLVER", deployer);
        c.builders = vm.envOr("BUILDER_REGISTRY", address(0));
        c.caretakers = vm.envOr("CARETAKER_REGISTRY", address(0));
        c.badge = vm.envOr("VERIFIED_BADGE", address(0));
        c.wonderExpiry = vm.envOr("WONDER_EXPIRY", uint256(180 days));
        c.operator = _addrReq("OPERATOR", deployer);
        c.onboarder = _addrReq("ONBOARDER", deployer);
    }

    function deploy(Config memory c) public returns (Deployed memory d) {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        require(c.registry != address(0) && c.attestation != address(0) && c.ledger != address(0), "stack not set");
        require(c.approvedAgent != address(0) && c.disputeResolver != address(0), "agent/resolver not set");
        require(c.protocolTreasury != address(0), "protocol treasury not set");
        require(c.epochLength > 0, "EPOCH_LENGTH must be > 0");
        require(c.operator != address(0) && c.onboarder != address(0), "operator/onboarder not set");
        require(c.wonderExpiry > 0, "WONDER_EXPIRY must be > 0");
        if (_isMainnet()) {
            require(c.disputeResolver != c.deployer, "mainnet: DISPUTE_RESOLVER must not be the deployer");
            require(c.approvedAgent != c.deployer, "mainnet: APPROVED_AGENT must not be the deployer");
            require(c.disputeResolver != c.approvedAgent, "mainnet: agent must not resolve its own disputes");
            require(c.protocolTreasury != c.deployer, "mainnet: PROTOCOL_TREASURY must not be the deployer");
            // The resolver adjudicates every challenged reading: a Safe, never a hot key.
            require(_isContract(c.disputeResolver), "mainnet: DISPUTE_RESOLVER must be a contract (a Safe)");
            // The tax brackets are per builder per epoch: a short epoch multiplies every
            // tax-free allowance (runbook: 30 days).
            require(c.epochLength >= 7 days, "mainnet: EPOCH_LENGTH must be at least 7 days (runbook: 30 days)");
            // Phase 1 put the builder side on chain first; forgetting the reuse
            // env here would silently fork builders, caretakers and badges.
            require(
                c.builders != address(0) && c.caretakers != address(0),
                "mainnet: BUILDER_REGISTRY and CARETAKER_REGISTRY (phase 1) are required"
            );
            require(
                c.operator != c.deployer && c.onboarder != c.deployer,
                "mainnet: OPERATOR and ONBOARDER must not be the deployer"
            );
        }

        bool reuse = c.builders != address(0) || c.caretakers != address(0);
        if (reuse) {
            require(c.builders != address(0) && c.caretakers != address(0), "BUILDER_REGISTRY and CARETAKER_REGISTRY: both or neither");
            require(c.builders.code.length > 0 && c.caretakers.code.length > 0, "phase-1 registry has no code");
            // BuilderRegistry has no immutables: its runtime code is exactly ours.
            require(c.builders.codehash == keccak256(type(BuilderRegistry).runtimeCode), "BUILDER_REGISTRY is not this BuilderRegistry");
            require(
                address(CaretakerRegistry(c.caretakers).BUILDERS()) == c.builders,
                "CARETAKER_REGISTRY belongs to a different BuilderRegistry"
            );
        }

        // after the registry checks, so a missing registry is named first
        if (_isMainnet()) require(c.badge != address(0), "mainnet: VERIFIED_BADGE (phase 1) is required");
        if (c.badge != address(0)) {
            require(c.builders != address(0), "VERIFIED_BADGE needs BUILDER_REGISTRY");
            require(
                address(VerifiedBuilderBadge(c.badge).BUILDERS()) == c.builders,
                "VERIFIED_BADGE belongs to a different BuilderRegistry"
            );
        }

        vm.startBroadcast(c.deployer);
        if (reuse) {
            d.builders = BuilderRegistry(c.builders);
            d.caretakers = CaretakerRegistry(c.caretakers);
        } else {
            d.builders = new BuilderRegistry(c.deployer);
            d.caretakers = new CaretakerRegistry(d.builders, c.deployer);
        }
        NanoLedger ledger = NanoLedger(c.ledger);
        d.seasonPool = new SeasonPool(ledger, d.builders, d.caretakers, c.deployer);
        d.fund = new BuilderFund(
            ledger, d.builders, d.caretakers, d.seasonPool, c.protocolTreasury, c.deployer, c.epochLength, LaunchSchedule.brackets()
        );
        d.badge = c.badge != address(0)
            ? VerifiedBuilderBadge(c.badge)
            : new VerifiedBuilderBadge(d.builders, c.deployer, c.operator, "Arc Testnet", "", "");
        d.escrow = new WonderEscrow(ledger, d.fund, d.badge, c.deployer, c.wonderExpiry);
        d.markets = new MarketsPerennial(
            ledger,
            Registry(c.registry),
            Attestation(c.attestation),
            d.builders,
            c.deployer,
            d.fund,
            c.settlementWindow,
            c.resolutionGrace,
            d.badge,
            d.escrow
        );
        d.fund.grantRole(d.fund.MARKETS_ROLE(), address(d.markets));
        d.fund.grantRole(d.fund.MARKETS_ROLE(), address(d.escrow));
        d.fund.grantRole(d.fund.LATE_ROLE(), address(d.escrow)); // releases credit the epochs escrow was earned in
        d.escrow.grantRole(d.escrow.MARKETS_ROLE(), address(d.markets));
        d.escrow.grantRole(d.escrow.RELEASER_ROLE(), c.operator);
        d.markets.grantRole(d.markets.FEED_ROLE(), c.operator);
        d.markets.grantRole(d.markets.NOMINATOR_ROLE(), c.onboarder);
        d.seasonPool.grantRole(d.seasonPool.FUNDER_ROLE(), address(d.fund));
        d.markets.setApprovedAgent(c.approvedAgent, true);
        d.markets.setApprovedResolver(c.disputeResolver, true);
        vm.stopBroadcast();

        require(d.fund.hasRole(d.fund.MARKETS_ROLE(), address(d.markets)), "markets not wired to the fund");
        require(d.seasonPool.hasRole(d.seasonPool.FUNDER_ROLE(), address(d.fund)), "fund not wired to the season pool");
        require(d.fund.hasRole(d.fund.MARKETS_ROLE(), address(d.escrow)), "escrow not wired to the fund");
        require(d.fund.hasRole(d.fund.LATE_ROLE(), address(d.escrow)), "escrow cannot credit late income");
        require(d.escrow.hasRole(d.escrow.MARKETS_ROLE(), address(d.markets)), "markets not wired to the escrow");
    }
}
