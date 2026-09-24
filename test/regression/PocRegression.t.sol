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
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {ProgressArbiter} from "../../src/perennial/ProgressArbiter.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// @notice Regression ports of the pre-mainnet review's proof-of-concept tests.
/// Each one reproduced an attack against the pre-fix code; here each asserts
/// that the attack now FAILS. Setup mirrors the reviewer's harness.
contract PocRegressionTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    ProgressPool pool;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    ProgressArbiter arb;

    address deployer = address(this);
    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address yesTaker = address(0x7A4E);
    address colluder = address(0xBAD);
    address challenger = address(0xC4A1);
    address caretaker = address(0xCA4E);
    address arbResolver = address(0x5E50);
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
        pool = new ProgressPool(ledger, builders, caretakers, deployer, 0, 60, address(0x7EA5));
        markets = new MarketsPerennial(ledger, registry, attestation, builders, deployer, address(pool), WINDOW, GRACE);
        markets.setApprovedAgent(agent, true);
        markets.setApprovedResolver(resolver, true);
        arb = new ProgressArbiter(ledger, pool, builders, caretakers, deployer, 300, 50e6, 10, 7 days);
        pool.grantRole(pool.PROGRESS_ROLE(), address(arb));
        arb.grantRole(arb.PROPOSER_ROLE(), caretaker);
        arb.grantRole(arb.RESOLVER_ROLE(), arbResolver);

        usdc.mint(agent, 10_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("ships-release", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 100e6);
        vm.stopPrank();

        _fund(creator);
        _fund(yesTaker);
        _fund(colluder);
        _fund(caretaker);
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
        ledger.approveSpender(address(arb), type(uint256).max);
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

    // ── M2: arbiter stakes are always recoverable ──

    /// PoC: builder deactivated after propose -> finalize reverts forever and the
    /// proposer's stake had no exit. Now closeInactive returns it.
    function test_regression_arbiterStakeRecoverableWhenBuilderDeactivated() public {
        caretakers.setCaretaker(1, caretaker);
        vm.startPrank(caretaker);
        arb.depositBond(50e6);
        uint256 e = arb.propose(1, 5);
        vm.stopPrank();
        builders.setActive(1, false);
        vm.warp(block.timestamp + 301);
        vm.expectRevert(ProgressPool.BuilderInactive.selector);
        arb.finalize(e); // still cannot credit an inactive builder
        arb.closeInactive(e); // anyone
        assertEq(arb.availableBond(caretaker), 50e6, "stake recovered");
        vm.prank(caretaker);
        arb.withdrawBond(50e6);
    }

    /// PoC: a challenged entry with a silent resolver locked both stakes forever.
    /// Now anyone expires it after RESOLVE_TIMEOUT and both stakes come back.
    function test_regression_arbiterChallengeWithoutResolverExpires() public {
        caretakers.setCaretaker(1, caretaker);
        vm.startPrank(caretaker);
        arb.depositBond(50e6);
        uint256 e = arb.propose(1, 5);
        vm.stopPrank();
        uint256 chBefore = ledger.balanceOf(challenger);
        vm.prank(challenger);
        arb.challenge(e);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(ProgressArbiter.BadState.selector);
        arb.finalize(e);
        arb.expireChallenge(e);
        assertEq(arb.availableBond(caretaker), 50e6, "proposer stake recovered");
        assertEq(ledger.balanceOf(challenger), chBefore, "challenger stake recovered");
        assertEq(pool.progressWeight(0, 1), 0, "no weight");
    }
}
