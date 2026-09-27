// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {Registry} from "../../../src/Registry.sol";
import {Attestation} from "../../../src/Attestation.sol";
import {Dispute} from "../../../src/Dispute.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../../src/nanopay/MarketsPerennial.sol";
import {BinaryMarket} from "../../../src/nanopay/BinaryMarket.sol";
import {BuilderRegistry} from "../../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../../src/perennial/SeasonPool.sol";
import {VerifiedBuilderBadge} from "../../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../../src/perennial/WonderEscrow.sol";
import {SourceKey} from "../../../src/perennial/SourceKey.sol";
import {FundKit} from "../../perennial/FundKit.sol";
import {MarketsKit} from "../../perennial/MarketsKit.sol";

contract SourceKeyHarness {
    function keyOf(string calldata s) external pure returns (bytes32) {
        return SourceKey.keyOf(s);
    }
}

/// Audit 2026-09-27: MarketsPerennial fee routing across the three builder-leg
/// destinations (escrow, fund, season pool), binding and void paths.
contract WonderMarketsAuditTest is Test {
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
    uint256 T0;

    bytes32[4] ids; // 0 wonder bound, 1 wonder unbound, 2 builder bound, 3 builder unbound

    function setUp() public {
        vm.warp(3600);
        T0 = block.timestamp;
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        Dispute dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 30 days);
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
        looseFeed = registry.createFeed("community", keccak256("m"), 10e6, 1 hours, resolver);
        registry.registerAgent(looseFeed, keccak256("m"), 10e6);
        vm.stopPrank();

        markets.setFeedSubject(wonderFeed, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.Wonder, 0, KEY));
        markets.setFeedSubject(
            builderFeed, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.Builder, builderId, bytes32(0))
        );
        markets.nominate(SRC, true);
        _fund(creator);
        _fund(taker);

        uint256 exp = T0 + 30 days - ((T0 + 30 days) % 1 hours);
        vm.startPrank(creator);
        ids[0] = markets.createWonderMarket(SRC, wonderFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, exp, 100e6);
        ids[1] = markets.createWonderMarket(SRC, looseFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, exp, 100e6);
        ids[2] = markets.createMarket(builderId, builderFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, exp, 100e6);
        ids[3] = markets.createMarket(builderId, looseFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, exp, 100e6);
        vm.stopPrank();
    }

    function _fund(address who) internal {
        usdc.mint(who, 10_000_000e6);
        vm.startPrank(who);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(10_000_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _incomeSum(uint256 id) internal view returns (uint256 s) {
        for (uint256 e; e <= fund.currentEpoch(); ++e) {
            s += fund.incomeOf(e, id);
        }
    }

    struct Exp {
        uint256 escrow;
        uint256 teamForward;
        uint256 builder;
        uint256 season;
        uint256 creator;
        uint256[4] agent;
    }

    /// Every trading fee splits exactly into creator + agent escrow + builder leg,
    /// and the builder leg lands where the market's frozen binding says: escrow
    /// (bound wonder, before release), the released team's income (bound wonder,
    /// after release), the builder's income (bound builder), the season pool
    /// (unbound). No unit is lost or created.
    function testFuzz_feeRoutingConserves(uint256[12] memory amt, uint8[12] memory which, bool[12] memory sell, bool releaseMid)
        public
    {
        Exp memory x;
        uint256 poolBefore = ledger.balanceOf(address(pool));
        uint256 creatorBefore = ledger.balanceOf(creator);
        uint256 teamId;
        uint256 released;
        bool isReleased;
        for (uint256 i; i < 12; ++i) {
            if (releaseMid && i == 6) {
                uint256 projectId;
                (teamId, projectId) = MarketsKit.onboard(builders, badge, team, SRC);
                escrow.grantRole(escrow.RELEASER_ROLE(), address(this));
                escrow.queueRelease(SRC, projectId);
                vm.warp(T0 + 7 days);
                released = escrow.escrowOf(KEY);
                escrow.executeRelease(KEY);
                x.escrow = 0;
                isReleased = true;
            }
            uint256 m = which[i] % 4;
            bytes32 id = ids[m];
            uint256 fee;
            uint256 yesBal = markets.yesBalance(id, taker);
            if (sell[i] && yesBal > 0) {
                uint256 shares = bound(amt[i], 1, yesBal);
                (uint256 out, uint256 f) = markets.quoteSell(id, BinaryMarket.Outcome.Yes, shares);
                if (out == 0) continue;
                fee = f;
                vm.prank(taker);
                markets.sell(id, BinaryMarket.Outcome.Yes, shares, 0, type(uint256).max);
            } else {
                uint256 a = bound(amt[i], 1, 50_000e6);
                (uint256 so,) = markets.quoteBuy(id, BinaryMarket.Outcome.Yes, a);
                if (so == 0) continue;
                fee = (a * 100) / 10_000;
                vm.prank(taker);
                markets.buy(id, BinaryMarket.Outcome.Yes, a, 0, type(uint256).max);
            }
            uint256 c = (fee * 3000) / 10_000;
            uint256 ag = (fee * 2000) / 10_000;
            uint256 b = fee - c - ag;
            x.creator += c;
            x.agent[m] += ag;
            if (m == 0) {
                if (isReleased) x.teamForward += b;
                else x.escrow += b;
            } else if (m == 2) {
                x.builder += b;
            } else {
                x.season += b;
            }
        }
        assertEq(escrow.totalEscrow(), x.escrow, "escrow");
        assertEq(escrow.escrowOf(KEY), x.escrow, "escrowOf");
        assertEq(_incomeSum(builderId), x.builder, "builder income");
        if (isReleased) assertEq(_incomeSum(teamId), released + x.teamForward, "team income");
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, x.season, "season pool");
        assertEq(ledger.balanceOf(creator) - creatorBefore, x.creator, "creator");
        for (uint256 j; j < 4; ++j) {
            assertEq(markets.agentEscrow(ids[j]), x.agent[j], "agent escrow");
        }
        // the market contract holds exactly C + agent escrow for every market
        uint256 held;
        for (uint256 j; j < 4; ++j) {
            held += markets.collateralOf(ids[j]) + markets.agentEscrow(ids[j]);
        }
        assertEq(ledger.balanceOf(address(markets)), held, "markets balance");
        assertGe(ledger.balanceOf(address(fund)), fund.outstanding(), "fund solvent");
        assertGe(ledger.balanceOf(address(escrow)), escrow.totalEscrow(), "escrow solvent (no vault)");
    }

    /// Re-binding a feed after markets opened never redirects their builder leg.
    function test_rebindDoesNotRedirectOpenMarkets() public {
        markets.setFeedSubject(
            wonderFeed, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.Builder, builderId, bytes32(0))
        );
        markets.setFeedSubject(looseFeed, MarketsPerennial.Subject(MarketsPerennial.SubjectKind.Wonder, 0, KEY));
        vm.startPrank(taker);
        markets.buy(ids[0], BinaryMarket.Outcome.Yes, 1_000e6, 0, type(uint256).max);
        markets.buy(ids[1], BinaryMarket.Outcome.Yes, 1_000e6, 0, type(uint256).max);
        vm.stopPrank();
        assertEq(escrow.escrowOf(KEY), 5e6, "only the originally bound wonder market escrows");
        assertEq(_incomeSum(builderId), 0);
    }

    /// Void: the agent escrow goes to the season pool (no challenger); the builder
    /// legs already escrowed stay with the team's escrow; traders get net cost.
    function test_voidWonderMarketKeepsEscrow() public {
        vm.prank(taker);
        markets.buy(ids[0], BinaryMarket.Outcome.Yes, 1_000e6, 0, type(uint256).max);
        assertEq(escrow.escrowOf(KEY), 5e6);
        uint256 poolBefore = ledger.balanceOf(address(pool));
        BinaryMarket.Phase ph;
        vm.warp(T0 + 40 days); // past expiry + settlement window + grace, no reading
        markets.voidMarket(ids[0]);
        ph = markets.getMarket(ids[0]).phase;
        assertEq(uint8(ph), uint8(BinaryMarket.Phase.Voided));
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 2e6, "agent escrow to the season pool");
        assertEq(escrow.escrowOf(KEY), 5e6, "builder leg stays escrowed");
        uint256 before = ledger.balanceOf(taker);
        vm.prank(taker);
        markets.redeem(ids[0]);
        assertEq(ledger.balanceOf(taker) - before, 990e6, "net cost back");
    }

    /// A wonder market on a source that is not nominated, or a non-canonical
    /// spelling of a nominated one, is refused.
    function testFuzz_wonderNeedsNominatedCanonical(string memory s) public {
        vm.assume(keccak256(bytes(s)) != KEY);
        vm.prank(creator);
        vm.expectRevert();
        markets.createWonderMarket(s, looseFeed, oracle, 1, BinaryMarket.Comparator.GreaterOrEqual, T0 + 30 days - ((T0 + 30 days) % 1 hours), 100e6);
    }

    /// SourceKey accepts only lowercase canonical forms: flipping any accepted
    /// character to uppercase is refused, so one project cannot be keyed twice by case.
    function testFuzz_sourceKeyCaseCanonical(uint8 pos) public {
        SourceKeyHarness h = new SourceKeyHarness();
        bytes memory b = bytes("github:some-owner/repo.name_x");
        h.keyOf(string(b));
        uint256 i = 7 + (uint256(pos) % (b.length - 7));
        if (b[i] >= "a" && b[i] <= "z") {
            b[i] = bytes1(uint8(b[i]) - 32);
            vm.expectRevert(SourceKey.NotCanonical.selector);
            h.keyOf(string(b));
        }
    }

    function test_sourceKeyRejectsSpellings() public {
        SourceKeyHarness h = new SourceKeyHarness();
        string[10] memory bad = [
            "github:acme/tool.git",
            "github:acme/tool/",
            "github:-acme/tool",
            "github:ac--me/tool",
            "domain:example.com.",
            "domain:1.2.3.4",
            "domain:www.Example.com",
            "https://github.com/acme/tool",
            "github:acme/.",
            "domain:localhost"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(SourceKey.NotCanonical.selector);
            h.keyOf(bad[i]);
        }
    }
}
