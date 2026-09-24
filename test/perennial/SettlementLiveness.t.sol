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
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// Every market an agent is asked to settle must reach a terminal state, must
/// never settle on a value that was public while trading was open, and must not
/// pay the agent for a settlement it did not deliver (on void its 20% leg goes
/// to a successful challenger, else to the commons).
contract SettlementLivenessTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsPerennial markets;
    ProgressPool pool;
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
        pool = new ProgressPool(ledger, builders, caretakers, address(this), 1 days, 1 hours, address(0x7EA5));
        markets = new MarketsPerennial(
            ledger, registry, attestation, builders, address(this), address(pool), WINDOW, GRACE
        );
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
            1, feedId, agent, int256(1), MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + LIFE, 100e6
        );
    }

    function _attest(int256 v) internal returns (bytes32 id) {
        vm.prank(agent);
        id = attestation.attest(feedId, v, keccak256(abi.encode(v, block.timestamp)));
    }

    function _trade(bytes32 id) internal {
        vm.prank(yesTaker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 300e6, 0);
        vm.prank(noTaker);
        markets.buy(id, MarketsPerennial.Outcome.No, 200e6, 0);
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
        assertEq(uint8(markets.getMarket(id).phase), uint8(MarketsPerennial.Phase.Resolved));
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
        markets.buy(id, MarketsPerennial.Outcome.Yes, 50e6, 0);

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
        markets.buy(id, MarketsPerennial.Outcome.Yes, 50e6, 0);

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
        vm.expectRevert(MarketsPerennial.AlreadyResolved.selector);
        markets.resolve(a);
        vm.expectRevert(MarketsPerennial.AlreadyResolved.selector);
        markets.voidMarket(a);
    }

    // ───────────────────────────── permanent lock ─────────────────────────────

    /// The lock that existed before: no attestation, collateral stuck forever.
    /// Now anyone can void once the window has closed empty.
    function test_silentAgent_marketVoids_andEveryoneIsPaid() public {
        bytes32 id = _market();
        _trade(id); // C = 100 + 300 + 200 = 600, fee 6

        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);

        uint256 y0 = ledger.balanceOf(yesTaker);
        vm.prank(yesTaker);
        uint256 yPaid = markets.redeem(id);
        assertEq(yPaid, 297e6, "net cost 300, minus 1%");
        assertEq(ledger.balanceOf(yesTaker) - y0, yPaid);

        vm.prank(noTaker);
        uint256 nPaid = markets.redeem(id);
        assertEq(nPaid, 198e6, "net cost 200, minus 1%");

        vm.prank(creator);
        uint256 lp = markets.claimLP(id);
        assertEq(lp, 99e6, "LP seed 100, minus 1%");
        _solvent();
        assertLe(ledger.balanceOf(address(markets)), 2, "at most rounding dust left behind");
    }

    function test_voidRedeemPaysBothSidesAtOnce_andOnlyOnce() public {
        bytes32 id = _market();
        vm.startPrank(yesTaker);
        markets.buy(id, MarketsPerennial.Outcome.Yes, 100e6, 0);
        markets.buy(id, MarketsPerennial.Outcome.No, 100e6, 0);
        vm.stopPrank();

        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        vm.prank(yesTaker);
        assertEq(markets.redeem(id), 198e6, "one refund of the whole net cost (200), minus 1%");
        assertEq(markets.netCost(id, yesTaker), 0);
        vm.prank(yesTaker);
        vm.expectRevert(MarketsPerennial.InsufficientShares.selector);
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
        assertEq(uint8(markets.getMarket(id).phase), uint8(MarketsPerennial.Phase.Voided));
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
        // C = 600, fee 6: the agent's 1.2 goes to the challenger, commons keeps its 3
        assertEq(ledger.balanceOf(challenger) - chBefore, 12e5, "challenger earns the agent's 20%");
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 3e6, "commons only its own 50%");
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
        assertEq(ledger.balanceOf(address(markets)), markets.collateralOf(id), "nothing held back either");
    }

    function test_agentIsPaidOnResolve() public {
        bytes32 id = _market();
        _trade(id); // C = 600, fee 6
        uint256 before = ledger.balanceOf(agent);
        vm.warp(_expiry(id) + 1);
        _attest(1);
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertEq(ledger.balanceOf(agent) - before, 12e5, "20% of the 1% fee");
    }

    function test_agentGetsNothingOnVoid_legGoesToCommons() public {
        bytes32 id = _market();
        _trade(id); // C = 600, fee 6
        uint256 agentBefore = ledger.balanceOf(agent);
        uint256 poolBefore = ledger.balanceOf(address(pool));
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        assertEq(ledger.balanceOf(agent), agentBefore, "the agent keeps nothing for a market it failed");
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, 42e5, "commons: its 50% plus the unclaimed 20%");
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
        markets.createMarket(1, slow, agent, 1, MarketsPerennial.Comparator.GreaterOrEqual, block.timestamp + LIFE, 100e6);
    }

    function test_constructorRejectsOutOfBoundsParams() public {
        vm.expectRevert(SettlementPolicy.BadSettlementParams.selector);
        new MarketsPerennial(ledger, registry, attestation, builders, address(this), address(pool), 1 minutes, GRACE);
        vm.expectRevert(SettlementPolicy.BadSettlementParams.selector);
        new MarketsPerennial(ledger, registry, attestation, builders, address(this), address(pool), WINDOW, 365 days);
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
        markets.buy(id, MarketsPerennial.Outcome.Yes, x, 0);
        vm.prank(noTaker);
        markets.buy(id, MarketsPerennial.Outcome.No, y, 0);
        vm.prank(sniper);
        markets.buy(id, MarketsPerennial.Outcome.Yes, z, 0);
        if (sellSome) {
            uint256 half = markets.yesBalance(id, yesTaker) / 2;
            if (half > 0) {
                vm.prank(yesTaker);
                markets.sell(id, MarketsPerennial.Outcome.Yes, half, 0);
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
