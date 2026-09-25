// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {BinaryMarket} from "../../src/nanopay/BinaryMarket.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../src/perennial/WonderEscrow.sol";
import {SourceKey} from "../../src/perennial/SourceKey.sol";
import {FundKit} from "../perennial/FundKit.sol";
import {MarketsKit} from "../perennial/MarketsKit.sol";
import {MockVault} from "../perennial/MockVault.sol";

contract WonderMarketsTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    BuilderFund fund;
    SeasonPool pool;
    VerifiedBuilderBadge badge;
    WonderEscrow escrow;
    MarketsPerennial markets;

    address oracle = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address taker = address(0x7A4E);
    address team = address(0x7EA3);
    string constant SRC = "github:acme/tool";
    bytes32 KEY = keccak256(bytes(SRC));
    bytes32 wonderFeed;
    bytes32 builderFeed;
    bytes32 looseFeed;
    uint256 builderId;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        Dispute dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 hours);
        badge = MarketsKit.deployBadge(builders);
        (markets, escrow) = MarketsKit.deployMarkets(ledger, registry, attestation, builders, fund, badge, 180 days);
        markets.setApprovedAgent(oracle, true);
        markets.setApprovedResolver(resolver, true);
        (builderId,) = MarketsKit.onboard(builders, badge, address(0xB111), "github:builder/one");

        usdc.mint(oracle, 1_000e6);
        vm.startPrank(oracle);
        usdc.approve(address(registry), type(uint256).max);
        wonderFeed = registry.createFeed("milestone github:acme/tool", keccak256("m"), 10e6, 1 hours, resolver);
        registry.registerAgent(wonderFeed, keccak256("m"), 10e6);
        builderFeed = registry.createFeed("milestone github:builder/one", keccak256("m"), 10e6, 1 hours, resolver);
        registry.registerAgent(builderFeed, keccak256("m"), 10e6);
        looseFeed = registry.createFeed("community: acme pool liquidity", keccak256("m"), 10e6, 1 hours, resolver);
        registry.registerAgent(looseFeed, keccak256("m"), 10e6);
        vm.stopPrank();

        markets.setFeedSubject(wonderFeed, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.Wonder, 0, KEY));
        markets.setFeedSubject(
            builderFeed, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.Builder, builderId, bytes32(0))
        );
        markets.nominate(SRC, true);

        _fund(creator);
        _fund(taker);
    }

    function _fund(address who) internal {
        usdc.mint(who, 100_000e6);
        vm.startPrank(who);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _wonder(bytes32 feed) internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createWonderMarket(
            SRC, feed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + 30 days, 100e6
        );
    }

    function _builder(bytes32 feed) internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(
            builderId, feed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + 30 days, 100e6
        );
    }

    function _buy(bytes32 id, uint256 amount) internal {
        vm.prank(taker);
        markets.buy(id, BinaryMarket.Outcome.Yes, amount, 0, type(uint256).max);
    }

    function test_boundWonderMarketEscrowsBuilderLeg() public {
        bytes32 id = _wonder(wonderFeed);
        (MarketsPerennial.Subject memory s, bool bound) = markets.subjectOf(id);
        assertEq(uint8(s.kind), uint8(MarketsPerennial.SubjectKind.Wonder));
        assertEq(s.sourceKey, KEY);
        assertTrue(bound);
        _buy(id, 1_000e6);
        assertEq(escrow.escrowOf(KEY), 5e6); // 1% fee = 10e6, builder leg 50%
    }

    function test_unboundMarketsPayTheSeasonPool() public {
        uint256 poolBefore = ledger.balanceOf(address(pool));
        bytes32 w = _wonder(looseFeed);
        bytes32 b = _builder(looseFeed);
        (, bool wb) = markets.subjectOf(w);
        (, bool bb) = markets.subjectOf(b);
        assertFalse(wb);
        assertFalse(bb);
        _buy(w, 1_000e6);
        _buy(b, 1_000e6);
        assertEq(escrow.escrowOf(KEY), 0);
        assertEq(fund.incomeOf(fund.currentEpoch(), builderId), 0);
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 10e6);
    }

    function test_feedBoundToAnotherSubjectIsUnbound() public {
        bytes32 id = _builder(wonderFeed); // a builder market on the acme feed
        (, bool bound) = markets.subjectOf(id);
        assertFalse(bound);
    }

    function test_boundBuilderMarketCreditsTheBuilder() public {
        bytes32 id = _builder(builderFeed);
        _buy(id, 1_000e6);
        assertEq(fund.incomeOf(fund.currentEpoch(), builderId), 5e6);
    }

    function test_bindingIsFrozenAtCreation() public {
        bytes32 id = _builder(builderFeed);
        markets.setFeedSubject(builderFeed, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.None, 0, bytes32(0)));
        (, bool bound) = markets.subjectOf(id);
        assertTrue(bound);
        _buy(id, 1_000e6);
        assertEq(fund.incomeOf(fund.currentEpoch(), builderId), 5e6);
    }

    function test_builderMarketNeedsLiveBadge() public {
        uint256 bare = builders.registerFor(address(0xBA2E), "");
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.BadgeNotLive.selector);
        markets.createMarket(bare, looseFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + 30 days, 100e6);
        badge.setLapsed(builderId, true);
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.BadgeNotLive.selector);
        markets.createMarket(
            builderId, builderFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + 30 days, 100e6
        );
    }

    function test_wonderMarketNeedsNomination() public {
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.NotNominated.selector);
        markets.createWonderMarket(
            "github:other/thing", looseFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + 30 days, 100e6
        );
    }

    function test_nominateRejectsNonCanonical() public {
        vm.expectRevert(SourceKey.NotCanonical.selector);
        markets.nominate("https://github.com/acme/tool", true);
    }

    function test_unnominateStopsNewMarketsOnly() public {
        bytes32 id = _wonder(wonderFeed);
        markets.nominate(SRC, false);
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.NotNominated.selector);
        markets.createWonderMarket(
            SRC, wonderFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + 30 days, 100e6
        );
        _buy(id, 1_000e6); // existing market still trades and escrows
        assertEq(escrow.escrowOf(KEY), 5e6);
    }

    function test_rolesGateNominateAndBinding() public {
        vm.startPrank(creator);
        vm.expectRevert();
        markets.nominate("github:x/y", true);
        vm.expectRevert();
        markets.setFeedSubject(looseFeed, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.Wonder, 0, KEY));
        vm.stopPrank();
    }

    function test_tradeSucceedsWhileVaultReverts() public {
        MockVault v = new MockVault(usdc);
        escrow.setVault(IERC4626(address(v)));
        escrow.setCap(1_000e6);
        escrow.grantRole(escrow.YIELD_ROLE(), address(this));
        bytes32 id = _wonder(wonderFeed);
        _buy(id, 1_000e6);
        escrow.deploy(4e6);
        v.setBroken(true);
        _buy(id, 1_000e6); // must not revert
        assertEq(escrow.escrowOf(KEY), 10e6);
    }

    function test_releasedSourceRoutesToBuilder() public {
        bytes32 id = _wonder(wonderFeed);
        _buy(id, 1_000e6);
        (uint256 teamId, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        escrow.grantRole(escrow.RELEASER_ROLE(), address(this));
        escrow.queueRelease(SRC, projectId);
        vm.warp(block.timestamp + 7 days);
        escrow.executeRelease(KEY);
        _buy(id, 1_000e6);
        assertEq(fund.incomeOf(fund.currentEpoch(), teamId), 5e6 + 5e6);
    }
}
