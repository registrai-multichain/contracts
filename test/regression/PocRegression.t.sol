// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {SettlementPolicy} from "../../src/nanopay/SettlementPolicy.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {FundKit} from "../perennial/FundKit.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// @notice Regression ports of the pre-mainnet review's proof-of-concept tests.
/// Each one reproduced an attack against the pre-fix code; here each asserts
/// that the attack now FAILS. Setup mirrors the reviewer's harness. (The M2
/// arbiter-stake regressions left with the ProgressArbiter in the
/// builder-income redesign.)
contract PocRegressionTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    BuilderFund fund;
    SeasonPool pool;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;

    address deployer = address(this);
    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address yesTaker = address(0x7A4E);
    address colluder = address(0xBAD);
    address challenger = address(0xC4A1);
    bytes32 feedId;

    uint256 constant DW = 1 hours;
    uint256 constant WINDOW = 24 hours;
    uint256 constant GRACE = 7 days;
    uint256 constant LIFE = 10 hours;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, deployer);
        builders = new BuilderRegistry(deployer);
        caretakers = new CaretakerRegistry(builders, deployer);
        builders.registerFor(address(0xB111), "b1");
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        markets = new MarketsPerennial(ledger, registry, attestation, builders, deployer, fund, WINDOW, GRACE);
        FundKit.wire(fund, address(markets));
        markets.setApprovedAgent(agent, true);
        markets.setApprovedResolver(resolver, true);

        usdc.mint(agent, 10_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("ships-release", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 100e6);
        vm.stopPrank();

        _fund(creator);
        _fund(yesTaker);
        _fund(colluder);
        _fund(challenger);
        usdc.mint(challenger, 10_000e6);
        vm.prank(challenger);
        usdc.approve(address(dispute), type(uint256).max);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _market(uint256 expiry) internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(1, feedId, agent, int256(1), MarketsPerennial.Comparator.GreaterOrEqual, expiry, 100e6);
    }

    // ── M1: one challenge no longer freezes the agent across the feed ──

    /// PoC: a challenge locked the agent's whole free bond, so it could not attest
    /// for the next market, which then voided although the agent was ready.
    function test_regression_oneChallengeDoesNotFreezeAgentAcrossFeed() public {
        uint256 t0 = block.timestamp;
        _market(t0 + LIFE);
        bytes32 b = _market(t0 + LIFE + 2 hours);
        vm.warp(t0 + LIFE);
        vm.prank(agent);
        bytes32 att = attestation.attest(feedId, 1, keccak256("x"));
        vm.prank(challenger);
        dispute.challenge(att, keccak256("ev"));
        // only the per-challenge stake (feed minBond) is locked
        assertEq(registry.getAgent(feedId, agent).lockedBond, 10e6);
        assertEq(registry.availableBond(feedId, agent), 90e6);

        vm.warp(t0 + LIFE + 2 hours);
        vm.prank(agent);
        attestation.attest(feedId, 1, keccak256("y")); // no longer InsufficientAvailableBond

        vm.warp(t0 + LIFE + 2 hours + DW);
        (SettlementPolicy.Settlement s, int256 v) = markets.settlementState(b);
        assertEq(uint256(s), uint256(SettlementPolicy.Settlement.Resolvable));
        assertEq(v, 1);
        markets.resolve(b);
        assertTrue(markets.getMarket(b).yesWon);
    }

    // ── B1: no market on a self-resolved feed ──

    /// PoC: the attacker created a feed naming itself resolver, registered as its
    /// agent, opened a market, attested a lie and ruled the honest challenge
    /// Valid. Now the market cannot be opened at all.
    function test_regression_selfResolvedFeedMarketRefused() public {
        address attacker = address(0xA77);
        usdc.mint(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(registry), type(uint256).max);
        bytes32 f = registry.createFeed("looks-legit", keccak256("m"), 10e6, 1 hours, attacker);
        registry.registerAgent(f, keccak256("m"), 10e6);
        vm.stopPrank();
        _fund(attacker);

        vm.prank(attacker);
        vm.expectRevert(MarketsPerennial.AgentNotApproved.selector);
        markets.createMarket(1, f, attacker, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + LIFE, 100e6);

        // Even if the governor had vetted the attacker as an agent, its own
        // resolver still is not: the self-resolved feed is refused.
        markets.setApprovedAgent(attacker, true);
        vm.prank(attacker);
        vm.expectRevert(MarketsPerennial.ResolverNotApproved.selector);
        markets.createMarket(1, f, attacker, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + LIFE, 100e6);
        assertFalse(markets.isApprovedFeed(f, attacker));
    }
}
