// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// Can our agent actually settle whatever a market submits?
///
/// createMarket already refuses an unregistered agent, so the naive footgun is
/// closed. These tests probe the two cases it does NOT cover: an agent that is
/// registered but has gone quiet, and an agent that has never attested at all.
contract SettlementCoverageTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    ProgressPool pool;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;

    address builder = address(0xB111);
    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address taker = address(0x7A4E);
    bytes32 feedId;
    uint256 constant DW = 1 hours;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        builders.registerFor(builder, "github.com/example/builder");
        pool = new ProgressPool(ledger, builders, caretakers, address(this), 1 days, 1 hours);
        markets = new MarketsPerennial(ledger, registry, attestation, builders, address(this), address(pool));

        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("ships-release", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 10e6);
        vm.stopPrank();

        _fund(creator);
        _fund(taker);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _market(uint256 life) internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(
            1, feedId, agent, int256(1), MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + life, 10e6
        );
    }

    /// A registered agent is not a LIVE agent. createMarket checks the registry,
    /// which says nothing about whether the agent will ever attest again.
    function test_createMarket_acceptsAnAgentThatHasNeverAttested() public {
        assertEq(attestation.historyLength(feedId, agent), 0, "agent has never attested");
        bytes32 id = _market(2 hours);
        assertTrue(markets.getMarket(id).createdAt != 0, "market created against a silent agent");
    }

    /// GAP A — a stale attestation settles the market silently.
    /// The agent attests once, then goes quiet for 40 days. A market created and
    /// expiring long afterwards still resolves, against the 40-day-old value,
    /// with no revert and no signal that the data was stale.
    function test_staleAttestation_resolvesAnyway() public {
        vm.prank(agent);
        attestation.attest(feedId, int256(1), bytes32("release:v1.0.0"));
        // vm.getBlockTimestamp(), not block.timestamp: the optimizer folds
        // repeated block.timestamp reads across vm.warp into one, so a plain
        // local here silently aliases the FINAL time and the age reads zero.
        uint256 attestedAt = vm.getBlockTimestamp();

        vm.warp(block.timestamp + 40 days);
        bytes32 id = _market(2 hours);
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0);

        vm.warp(block.timestamp + 2 hours + 1);
        markets.resolve(id); // no revert

        MarketsPerennial.Market memory m = markets.getMarket(id);
        assertTrue(m.yesWon, "settled YES from a value attested 40 days earlier");
        assertGt(vm.getBlockTimestamp() - attestedAt, 40 days, "the deciding value really was that old");
    }

    /// GAP B — no attestation before expiry means the market can never settle,
    /// and the collateral has no way out: resolve reverts on the missing
    /// attestation, sell reverts because the market has expired, and redeem
    /// reverts because it never resolved. There is no void path.
    function test_noAttestation_locksCollateralPermanently() public {
        bytes32 id = _market(2 hours);
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0);

        vm.warp(block.timestamp + 2 hours + 1);

        vm.expectRevert(MarketsPerennial.AttestationNotFound.selector);
        markets.resolve(id);

        vm.prank(taker);
        vm.expectRevert(MarketsPerennial.MarketExpired.selector);
        markets.sell(id, MarketsPerennial.Outcome.Yes, 1, 0);

        vm.prank(taker);
        vm.expectRevert(MarketsPerennial.NotResolved.selector);
        markets.redeem(id);

        // Still stuck a year later — nothing in the contract can free it.
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(MarketsPerennial.AttestationNotFound.selector);
        markets.resolve(id);

        assertGt(ledger.balanceOf(address(markets)), 0, "collateral is held by a market that can never settle");
    }

    /// The honest case, for contrast: agent attests after expiry and before
    /// anyone resolves, and settlement uses that fresh value.
    function test_attestationAfterExpiry_isNotUsed() public {
        bytes32 id = _market(2 hours);
        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(agent);
        attestation.attest(feedId, int256(1), bytes32("release:late"));
        vm.warp(block.timestamp + DW + 1);

        // valueAt ignores anything stamped after the expiry, so a late attestation
        // does NOT rescue the market.
        vm.expectRevert(MarketsPerennial.AttestationNotFound.selector);
        markets.resolve(id);
    }
}
