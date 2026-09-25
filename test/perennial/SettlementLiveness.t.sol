// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {BinaryMarket} from "../../src/nanopay/BinaryMarket.sol";
import {SettlementPolicy} from "../../src/nanopay/SettlementPolicy.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {FundKit} from "./FundKit.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../src/perennial/WonderEscrow.sol";
import {MarketsKit} from "./MarketsKit.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// Every market an agent is asked to settle must reach a terminal state, must
/// never settle on a value that was public while trading was open, and must not
/// pay the agent for a settlement it did not deliver (its 20% of the trading
/// fees is escrowed; on void it goes to a successful challenger, else to the
/// season pool).
contract SettlementLivenessTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    BuilderFund fund;
    SeasonPool pool;
    BuilderRegistry builders;

    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address yesTaker = address(0x7A4E);
    address noTaker = address(0x7A4F);
    address sniper = address(0x5419E);
    address challenger = address(0xC4A1);
    bytes32 feedId;

    uint256 constant DW = 1 hours; // feed dispute window
    uint256 constant WINDOW = 1 hours; // SETTLEMENT_WINDOW
    uint256 constant GRACE = 1 days; // RESOLUTION_GRACE
    uint256 constant LIFE = 10 hours;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, address(this));
        builders.registerFor(address(0xB111), "github.com/example/builder");
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        markets = MarketsKit.perennial(
            ledger, registry, attestation, builders, address(this), fund, WINDOW, GRACE
        );
        FundKit.wire(fund, address(markets));
        markets.setApprovedAgent(agent, true);
        markets.setApprovedResolver(resolver, true);

        usdc.mint(agent, 10_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("ships-release", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 1_000e6);
        vm.stopPrank();

        _fund(creator);
        _fund(yesTaker);
        _fund(noTaker);
        _fund(sniper);
        usdc.mint(challenger, 10_000e6);
        MarketsKit.certify(markets, 1);
        MarketsKit.bindBuilder(markets, feedId, 1);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _market() internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(
            1, feedId, agent, int256(1), BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + LIFE, 100e6
        );
    }

    function _attest(int256 v) internal returns (bytes32 id) {
        vm.prank(agent);
        id = attestation.attest(feedId, v, keccak256(abi.encode(v, block.timestamp)));
    }

    function _trade(bytes32 id) internal {
        vm.prank(yesTaker);
        markets.buy(id, BinaryMarket.Outcome.Yes, 300e6, 0, type(uint256).max);
        vm.prank(noTaker);
        markets.buy(id, BinaryMarket.Outcome.No, 200e6, 0, type(uint256).max);
    }

    function _expiry(bytes32 id) internal view returns (uint256) {
        return markets.getMarket(id).expiry;
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger solvent");
    }

    // ───────────────────────────── happy path ─────────────────────────────

    function test_resolvesOnTheFirstAttestationAfterExpiry() public {
        bytes32 id = _market();
        _trade(id);
        vm.warp(_expiry(id) + 10 minutes);
        _attest(1);
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertTrue(markets.getMarket(id).yesWon);
        _solvent();
    }

    function test_mayResolveBeforeTheWindowClosesOnceFinalized() public {
        bytes32 id = _market();
        vm.warp(_expiry(id));
        _attest(1);
        vm.warp(block.timestamp + DW); // well inside a 1h window? DW == WINDOW here: at the edge
        markets.resolve(id);
        assertEq(uint8(markets.getMarket(id).phase), uint8(BinaryMarket.Phase.Resolved));
    }

    // ───────────────────────────── last look ─────────────────────────────

    /// The attack that worked before: the agent attests shortly before expiry,
    /// the outcome is public, the market is still open. Now a pre-expiry
    /// attestation does not settle anything, so it carries no free option.
    function test_preExpiryAttestationCannotSettle() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) - 1 hours);
        _attest(1); // "shipped" — while trading is still open

        vm.prank(sniper);
        markets.buy(id, BinaryMarket.Outcome.Yes, 50e6, 0, type(uint256).max);

        vm.warp(_expiry(id) + WINDOW + DW + 1);
        (SettlementPolicy.Settlement s,) = markets.settlementState(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Voidable), "pre-expiry value is not a settlement");
        vm.expectRevert(SettlementPolicy.SettlementPending.selector);
        markets.resolve(id);
    }

    function test_settlesOnThePostExpiryValueNotTheLeakedOne() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) - 1 hours);
        _attest(1); // pre-expiry: "shipped"
        vm.prank(sniper);
        markets.buy(id, BinaryMarket.Outcome.Yes, 50e6, 0, type(uint256).max);

        vm.warp(_expiry(id) + 5 minutes);
        _attest(0); // the real post-expiry reading: not shipped
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertFalse(markets.getMarket(id).yesWon, "decided by the reading taken after trading closed");
    }

    // ───────────────────────────── staleness ─────────────────────────────

    function test_aStaleAttestationNoLongerSettles() public {
        _attest(1);
        vm.warp(block.timestamp + 40 days);
        bytes32 id = _market();
        _trade(id);
        vm.warp(_expiry(id) + WINDOW + 1);
        vm.expectRevert(SettlementPolicy.SettlementPending.selector);
        markets.resolve(id);
        (SettlementPolicy.Settlement s,) = markets.settlementState(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Voidable));
    }

    function test_anAttestationAfterTheWindowIsIgnored() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) + WINDOW + 1);
        _attest(1);
        vm.warp(block.timestamp + DW);
        vm.expectRevert(SettlementPolicy.SettlementPending.selector);
        markets.resolve(id);
    }

    // ───────────────────────────── states ─────────────────────────────

    function test_cannotResolveWhileTheAgentMayStillAttest() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) + 1);
        vm.expectRevert(SettlementPolicy.SettlementPending.selector);
        markets.resolve(id);
    }

    function test_cannotVoidWhileTheWindowIsOpen() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) + WINDOW); // last second of the window
        vm.expectRevert(SettlementPolicy.NotVoidable.selector);
        markets.voidMarket(id);
    }

    function test_cannotVoidAResolvableMarket() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) + 1);
        _attest(1);
        vm.warp(_expiry(id) + WINDOW + GRACE + 1 days); // long past every deadline
        vm.expectRevert(SettlementPolicy.NotVoidable.selector);
        markets.voidMarket(id); // it can settle, so it must
        markets.resolve(id);
    }

    function test_cannotVoidBeforeExpiry() public {
        bytes32 id = _market();
        vm.expectRevert(SettlementPolicy.NotVoidable.selector);
        markets.voidMarket(id);
    }

    function test_terminalStatesAreFinal() public {
        bytes32 a = _market();
        vm.warp(_expiry(a) + WINDOW + 1);
        markets.voidMarket(a);
        vm.expectRevert(BinaryMarket.AlreadyResolved.selector);
        markets.resolve(a);
        vm.expectRevert(BinaryMarket.AlreadyResolved.selector);
        markets.voidMarket(a);
    }

    // ───────────────────────────── permanent lock ─────────────────────────────

    /// The lock that existed before: no attestation, collateral stuck forever.
    /// Now anyone can void once the window has closed empty.
    function test_silentAgent_marketVoids_andEveryoneIsPaid() public {
        bytes32 id = _market();
        _trade(id); // 300 and 200 in, 1% trading fee each: net costs 297 and 198

        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);

        uint256 y0 = ledger.balanceOf(yesTaker);
        vm.prank(yesTaker);
        uint256 yPaid = markets.redeem(id);
        assertEq(yPaid, 297e6, "net cost: 300 in, minus the 3 fee");
        assertEq(ledger.balanceOf(yesTaker) - y0, yPaid);

        vm.prank(noTaker);
        uint256 nPaid = markets.redeem(id);
        assertEq(nPaid, 198e6, "net cost: 200 in, minus the 2 fee");

        vm.prank(creator);
        uint256 lp = markets.claimLP(id);
        assertEq(lp, 100e6, "LP seed back whole");
        _solvent();
        assertEq(ledger.balanceOf(address(markets)), 0, "nothing left behind");
    }

    function test_voidRedeemPaysBothSidesAtOnce_andOnlyOnce() public {
        bytes32 id = _market();
        vm.startPrank(yesTaker);
        markets.buy(id, BinaryMarket.Outcome.Yes, 100e6, 0, type(uint256).max);
        markets.buy(id, BinaryMarket.Outcome.No, 100e6, 0, type(uint256).max);
        vm.stopPrank();

        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        vm.prank(yesTaker);
        assertEq(markets.redeem(id), 198e6, "one refund of the whole net cost (200 in, minus 2 in fees)");
        assertEq(markets.netCost(id, yesTaker), 0);
        vm.prank(yesTaker);
        vm.expectRevert(BinaryMarket.InsufficientShares.selector);
        markets.redeem(id);
    }

    // ───────────────────────────── stuck dispute ─────────────────────────────

    function _challenge(bytes32 attId) internal returns (bytes32 d) {
        Registry.Agent memory a = registry.getAgent(feedId, agent);
        vm.startPrank(challenger);
        usdc.approve(address(dispute), a.bond - a.lockedBond);
        d = dispute.challenge(attId, keccak256("contested"));
        vm.stopPrank();
    }

    /// Dispute has no timeout. Without a hard deadline, a challenge its resolver
    /// never settles would hold the market open forever.
    function test_unresolvedDispute_waitsForTheResolver_thenVoids() public {
        bytes32 id = _market();
        _trade(id);
        vm.warp(_expiry(id) + 1);
        _challenge(_attest(1));

        vm.warp(_expiry(id) + WINDOW + 1);
        vm.expectRevert(SettlementPolicy.NotVoidable.selector);
        markets.voidMarket(id); // the resolver still has time

        vm.warp(_expiry(id) + WINDOW + GRACE + 1);
        markets.voidMarket(id);
        assertEq(uint8(markets.getMarket(id).phase), uint8(BinaryMarket.Phase.Voided));
        _solvent();
    }

    function test_disputeUpheldInTime_resolves() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) + 1);
        bytes32 d = _challenge(_attest(1));
        vm.warp(_expiry(id) + WINDOW + 1 hours);
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationValid);
        markets.resolve(id);
        assertTrue(markets.getMarket(id).yesWon);
    }

    function test_disputeInvalidated_andNothingElseInWindow_voids() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) + 1);
        bytes32 d = _challenge(_attest(1));
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
    }

    /// A wrong answer is not correctable: an invalid ruling slashes the bond to
    /// the challenger and, once it falls below the minimum, deactivates the agent
    /// for good. The market voids and the agent's fee leg goes to the challenger.
    function test_invalidatedAnswer_slashesTheAgent_voids_andPaysTheChallenger() public {
        bytes32 id = _market();
        _trade(id);
        vm.warp(_expiry(id) + 1);
        bytes32 d = _challenge(_attest(1));
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
        assertFalse(registry.getAgent(feedId, agent).active, "slashed agent is deactivated");

        vm.prank(agent);
        vm.expectRevert(); // AgentInactive — no second chance
        attestation.attest(feedId, 0, bytes32("correction"));

        uint256 chBefore = ledger.balanceOf(challenger);
        uint256 poolBefore = ledger.balanceOf(address(pool));
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        // fees 3 + 2: the agent's escrowed 1 goes to the challenger, the season pool gets nothing
        assertEq(ledger.balanceOf(challenger) - chBefore, 1e6, "challenger earns the agent's escrow");
        assertEq(ledger.balanceOf(address(pool)), poolBefore, "season pool gets nothing");
        _solvent();
    }

    /// If the agent had already posted a second reading before the first was
    /// ruled invalid, settlement falls through to it rather than voiding.
    function test_invalidatedFirstAnswer_fallsThroughToAnEarlierPostedSecond() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) + 1);
        bytes32 first = _attest(1);
        vm.warp(block.timestamp + 1 minutes);
        _attest(0); // posted before any challenge
        bytes32 d = _challenge(first);
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertFalse(markets.getMarket(id).yesWon, "decided by the surviving reading");
    }

    // ───────────────────────────── agent fee ─────────────────────────────

    function test_agentFee_notPaidAtTradeTime() public {
        uint256 before = ledger.balanceOf(agent);
        bytes32 id = _market();
        _trade(id);
        assertEq(ledger.balanceOf(agent), before, "nothing paid before settling");
        assertEq(markets.agentEscrow(id), 1e6, "20% of the 5 in fees, held");
        assertEq(ledger.balanceOf(address(markets)), markets.collateralOf(id) + markets.agentEscrow(id));
    }

    function test_agentIsPaidOnResolve() public {
        bytes32 id = _market();
        _trade(id); // fees 3 + 2
        uint256 before = ledger.balanceOf(agent);
        vm.warp(_expiry(id) + 1);
        _attest(1);
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertEq(ledger.balanceOf(agent) - before, 1e6, "the escrow: 20% of the trading fees");
        assertEq(markets.agentEscrow(id), 0);
    }

    function test_agentGetsNothingOnVoid_legGoesToSeasonPool() public {
        bytes32 id = _market();
        _trade(id); // fees 3 + 2, escrow 1
        uint256 agentBefore = ledger.balanceOf(agent);
        uint256 poolBefore = ledger.balanceOf(address(pool));
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        assertEq(ledger.balanceOf(agent), agentBefore, "the agent keeps nothing for a market it failed");
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 1e6, "season pool receives the unclaimed escrow");
    }

    function test_forfeitSinkIsGone() public {
        (bool ok,) = address(markets).call(abi.encodeWithSignature("setForfeitSink(address)", sniper));
        assertFalse(ok);
        (ok,) = address(markets).call(abi.encodeWithSignature("forfeitSink()"));
        assertFalse(ok);
    }

    // ───────────────────────────── creation guards ─────────────────────────────

    function test_refusesAFeedWhoseDisputesOutlastTheGrace() public {
        vm.startPrank(agent);
        bytes32 slow = registry.createFeed("slow", keccak256("m"), 10e6, GRACE, resolver);
        registry.registerAgent(slow, keccak256("m"), 10e6);
        vm.stopPrank();
        vm.prank(creator);
        vm.expectRevert(SettlementPolicy.FeedUnsettleable.selector);
        markets.createMarket(1, slow, agent, 1, BinaryMarket.Comparator.GreaterOrEqual, block.timestamp + LIFE, 100e6);
    }

    function test_constructorRejectsOutOfBoundsParams() public {
        VerifiedBuilderBadge badge_ = markets.BADGE();
        WonderEscrow escrow_ = markets.ESCROW();
        vm.expectRevert(SettlementPolicy.BadSettlementParams.selector);
        new MarketsPerennial(ledger, registry, attestation, builders, address(this), fund, 1 minutes, GRACE, badge_, escrow_);
        vm.expectRevert(SettlementPolicy.BadSettlementParams.selector);
        new MarketsPerennial(ledger, registry, attestation, builders, address(this), fund, WINDOW, 365 days, badge_, escrow_);
    }

    // ───────────────────────────── solvency under fuzz ─────────────────────────────

    /// Random trading, then void: everything paid out must come from collateral
    /// the market actually holds, and the ledger must stay solvent.
    function testFuzz_voidIsSolvent(uint96 a, uint96 b, uint96 c, bool sellSome) public {
        bytes32 id = _market();
        uint256 x = bound(uint256(a), 1e6, 5_000e6);
        uint256 y = bound(uint256(b), 1e6, 5_000e6);
        uint256 z = bound(uint256(c), 1e6, 5_000e6);
        vm.prank(yesTaker);
        markets.buy(id, BinaryMarket.Outcome.Yes, x, 0, type(uint256).max);
        vm.prank(noTaker);
        markets.buy(id, BinaryMarket.Outcome.No, y, 0, type(uint256).max);
        vm.prank(sniper);
        markets.buy(id, BinaryMarket.Outcome.Yes, z, 0, type(uint256).max);
        if (sellSome) {
            uint256 half = markets.yesBalance(id, yesTaker) / 2;
            if (half > 0) {
                vm.prank(yesTaker);
                markets.sell(id, BinaryMarket.Outcome.Yes, half, 0, type(uint256).max);
            }
        }

        uint256 held = ledger.balanceOf(address(markets));
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);

        uint256 paid;
        address[3] memory who = [yesTaker, noTaker, sniper];
        for (uint256 i; i < 3; i++) {
            if (markets.redeemable(id, who[i]) > 0) {
                vm.prank(who[i]);
                paid += markets.redeem(id);
            }
        }
        vm.prank(creator);
        paid += markets.claimLP(id);
        assertLe(paid, held, "never pays out more than it holds");
        _solvent();
    }
}
