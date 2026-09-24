// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {FundKit} from "./FundKit.sol";
import {MerkleKit} from "./MerkleKit.sol";

/// Full Perennial loop: the builder leg of a market's trading fees is credited
/// to the builder the market is about; after the epoch the builder's income is
/// claimed (progressive tax to the SeasonPool, 1% protocol fee, net to the
/// payout); the Safe publishes a season from the pool and builders claim it.
/// Ledger solvency holds throughout.
contract PerennialTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    BuilderFund fund;
    SeasonPool pool;
    BuilderRegistry builderReg;
    CaretakerRegistry caretakers;

    address oracle = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address taker = address(0x7A4E);
    address builderA = address(0xB111);
    address builderB = address(0xB222);
    uint256 constant A_ID = 1; // builderA's id
    uint256 constant B_ID = 2; // builderB's id
    address protocolTreasury = address(0x7EA5);
    bytes32 feedId;
    uint256 constant DW = 1 hours;
    uint256 constant EPOCH = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builderReg = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builderReg, address(this));
        builderReg.registerFor(builderA, "ipfs://a");
        builderReg.registerFor(builderB, "ipfs://b");
        (pool, fund) = FundKit.deploy(ledger, builderReg, caretakers, protocolTreasury, EPOCH);
        markets = new MarketsPerennial(ledger, registry, attestation, builderReg, address(this), fund, 1 hours, 1 days);
        FundKit.wire(fund, address(markets));
        markets.setApprovedAgent(oracle, true);
        markets.setApprovedResolver(resolver, true);

        usdc.mint(oracle, 1_000e6);
        vm.startPrank(oracle);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("BTC", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 10e6);
        vm.stopPrank();

        _fund(creator);
        _fund(taker);
    }

    function _fund(address a) internal {
        usdc.mint(a, 100_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(20_000_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
        assertGe(ledger.balanceOf(address(fund)), fund.outstanding(), "fund below income");
        assertGe(ledger.balanceOf(address(pool)), pool.unallocated() + pool.reserved(), "pool below accounted");
    }

    function _market(uint256 builderId) internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(
            builderId,
            feedId,
            oracle,
            int256(100_000),
            MarketsPerennial.Comparator.GreaterOrEqual,
            block.timestamp + 2 hours,
            10e6
        );
    }

    // ── BuilderRegistry ──

    function test_builderRegistry() public {
        assertEq(builderReg.builderIdOf(builderA), 1);
        assertFalse(builderReg.isUniqueBuilder(builderA));
        vm.prank(builderA);
        builderReg.linkIdentity(hex"01");
        assertTrue(builderReg.isUniqueBuilder(builderA));
        vm.prank(builderA);
        vm.expectRevert(BuilderRegistry.AlreadyRegistered.selector);
        builderReg.registerBuilder("ipfs://dup");
    }

    function test_inactiveBuilder_noNewMarkets_openMarketsKeepTrading_incomeFrozen() public {
        bytes32 id = _market(A_ID);
        builderReg.setActive(A_ID, false);
        vm.prank(creator);
        vm.expectRevert(MarketsPerennial.BuilderInactive.selector);
        markets.createMarket(
            A_ID, feedId, oracle, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + 1 days, 10e6
        );
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 1_000e6, 0); // still trades
        assertEq(fund.incomeOf(0, A_ID), 5e6, "income accrues, frozen");
        vm.warp(fund.epochEnd(0));
        vm.expectRevert(BuilderFund.BuilderInactive.selector);
        fund.claimFor(0, A_ID);
        fund.sweepFrozen(0, A_ID); // the Safe's lever
        assertEq(pool.unallocated(), 5e6);
        _solvent();
    }

    // ── the loop ──

    /// A builder whose markets attract $12M of volume in an epoch earns $60,000
    /// (50% of the 1% fee): taxed $11,900, fee $481, net $47,619. Another earns
    /// $800 untaxed. The tax funds a season both then claim from.
    function test_fullLoop_income_tax_season() public {
        bytes32 mA = _market(A_ID);
        bytes32 mB = _market(B_ID);
        for (uint256 i; i < 6; i++) {
            vm.prank(taker);
            markets.buy(mA, MarketsPerennial.Outcome.Yes, 1_000_000e6, 0); // fee 10,000: builder 5,000
            vm.prank(taker);
            markets.buy(mA, MarketsPerennial.Outcome.No, 1_000_000e6, 0);
        }
        vm.prank(taker);
        markets.buy(mB, MarketsPerennial.Outcome.Yes, 160_000e6, 0); // fee 1,600: builder 800
        assertEq(fund.incomeOf(0, A_ID), 60_000e6);
        assertEq(fund.incomeOf(0, B_ID), 800e6);
        assertEq(ledger.balanceOf(address(fund)), 60_800e6);

        vm.warp(fund.epochEnd(0));
        address cold = makeAddr("aCold");
        vm.prank(builderA);
        caretakers.setPayout(A_ID, cold);
        assertEq(fund.claimFor(0, A_ID), 47_619e6);
        assertEq(fund.claimFor(0, B_ID), 792e6);
        assertEq(ledger.balanceOf(cold), 47_619e6);
        assertEq(ledger.balanceOf(builderB), 792e6);
        assertEq(ledger.balanceOf(protocolTreasury), 481e6 + 8e6);
        assertEq(ledger.balanceOf(address(pool)), 11_900e6, "the tax is the season pool");
        assertEq(pool.unallocated(), 11_900e6);
        _solvent();

        // the Safe publishes season 1 over 10,000 of it (cap 2,000 per builder)
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = pool.leafOf(1, A_ID, 2_000e6);
        leaves[1] = pool.leafOf(1, B_ID, 1_500e6);
        pool.publishSeason(1, MerkleKit.root(leaves), 10_000e6, uint64(block.timestamp + 30 days));
        pool.claim(1, A_ID, 2_000e6, MerkleKit.proof(leaves, 0));
        pool.claim(1, B_ID, 1_500e6, MerkleKit.proof(leaves, 1));
        assertEq(ledger.balanceOf(cold), 49_619e6, "season reward to the payout too");
        assertEq(ledger.balanceOf(builderB), 2_292e6);
        vm.warp(block.timestamp + 30 days + 1);
        assertEq(pool.reclaim(1), 6_500e6);
        assertEq(pool.unallocated(), 1_900e6 + 6_500e6);
        _solvent();
    }

    /// Void escrows without a challenger join the same pool.
    function test_voidEscrow_joinsTheSeasonPool() public {
        bytes32 id = _market(A_ID);
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // escrow 4
        vm.warp(markets.getMarket(id).expiry + 1 hours + 1);
        markets.voidMarket(id);
        assertEq(pool.unallocated(), 4e6);
        assertEq(fund.incomeOf(0, A_ID), 10e6, "the builder keeps its per-trade leg");
        _solvent();
    }

    function test_claimFor_creditsBuilderNotCaller() public {
        bytes32 id = _market(A_ID);
        vm.prank(taker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 2_000e6, 0); // builder 10
        vm.warp(fund.epochEnd(0));
        address caretaker = address(0xCA4E);
        vm.prank(caretaker);
        uint256 net = fund.claimFor(0, A_ID);
        assertEq(net, 99e5);
        assertEq(ledger.balanceOf(builderA), 99e5, "paid instantly, no stream");
        assertEq(ledger.balanceOf(caretaker), 0, "caretaker got nothing");
        _solvent();
    }
}
