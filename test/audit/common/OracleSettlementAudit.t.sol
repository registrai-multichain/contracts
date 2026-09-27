// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {Registry} from "../../../src/Registry.sol";
import {Attestation} from "../../../src/Attestation.sol";
import {Dispute} from "../../../src/Dispute.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../../../src/nanopay/MarketsV4.sol";
import {BinaryMarket} from "../../../src/nanopay/BinaryMarket.sol";
import {SettlementPolicy} from "../../../src/nanopay/SettlementPolicy.sol";

/// Audit: oracle + settlement layer (Registry / Attestation / Dispute /
/// SettlementPolicy as consumed by BinaryMarket.resolve / voidMarket), with the
/// mainnet parameters: MIN_BOND 2 USDC, agent bond 2 x minBond, rounds feeds with a
/// 10-minute dispute window, event feeds with 12 h, settlement window 1 h, grace 7 d.
contract OracleSettlementAuditTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsV4 v4;

    address agent = address(0x0AC1E); // the rounds keeper (feed creator == agent)
    address safe = address(0x5AFE); // Admin Safe: dispute resolver
    address treasury = address(0x7EA);
    address watcher = address(0xC4A11); // honest challenger
    address griefer = address(0x6121EF);
    address alice = address(0xA11CE); // trader on YES
    address bob = address(0xB0B); // trader on NO

    uint256 constant MINB = 2e6;
    uint256 constant BOND = 2 * MINB;
    uint256 constant DW_ROUND = 600;
    uint256 constant DW_EVENT = 43200;
    uint256 constant WINDOW = 1 hours;
    uint256 constant GRACE = 7 days;

    bytes32 roundFeed;
    uint256 T0;
    bytes32 eventFeed;

    function setUp() public {
        vm.warp(1_800_000_000 - (1_800_000_000 % 300)); // on the 5-minute grid
        T0 = 1_800_000_000 - (1_800_000_000 % 300);
        usdc = new MockUSDC();
        registry = new Registry(usdc, MINB);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        registry.setPoints(address(0));
        attestation.setPoints(address(0));
        ledger = new NanoLedger(usdc, address(this));
        v4 = new MarketsV4(ledger, registry, attestation, address(this), treasury, WINDOW, GRACE);
        v4.setApprovedResolver(safe, true);
        v4.setApprovedAgent(agent, true);

        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        usdc.approve(address(dispute), type(uint256).max);
        roundFeed = registry.createFeed("btc-usd-5m-change-0", keccak256("m"), MINB, DW_ROUND, safe);
        registry.registerAgent(roundFeed, keccak256("m"), BOND);
        eventFeed = registry.createFeed("arc-token-tradable", keccak256("e"), MINB, DW_EVENT, safe);
        registry.registerAgent(eventFeed, keccak256("e"), BOND);
        vm.stopPrank();

        _fundLedger(agent, 1_000e6);
        _fundLedger(alice, 1_000e6);
        _fundLedger(bob, 1_000e6);
        address[3] memory cs = [watcher, griefer, address(0xDEAD1)];
        for (uint256 i; i < cs.length; i++) {
            usdc.mint(cs[i], 1_000e6);
            vm.prank(cs[i]);
            usdc.approve(address(dispute), type(uint256).max);
        }
    }

    function _fundLedger(address a, uint256 amt) internal {
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(amt);
        ledger.approveSpender(address(v4), type(uint256).max);
        vm.stopPrank();
    }

    /// A round market: YES iff change > 0 (strike 0, GreaterThan), like rounds.py.
    function _round(bytes32 feed, uint256 expiry) internal returns (bytes32 id) {
        vm.prank(agent);
        id = v4.createMarket(feed, agent, 0, BinaryMarket.Comparator.GreaterThan, expiry, 5e6);
    }

    function _attest(bytes32 feed, int256 v) internal returns (bytes32) {
        vm.prank(agent);
        return attestation.attest(feed, v, keccak256(abi.encode(feed, v, block.timestamp)));
    }

    function _state(bytes32 id) internal view returns (SettlementPolicy.Settlement s, int256 v) {
        (s, v) = v4.settlementState(id);
    }

    // ═══════════════════════ H-1: an agent can make its reading unchallengeable ═══════════════════════

    /// FIXED (was H-1). The agent posts a WRONG settling reading, then two throwaway
    /// readings, and exhausts its own bond by challenging them - it cannot do that
    /// itself any more (AgentCannotChallenge), so it uses a second address. Its free
    /// bond is 0, yet the honest watcher's challenge of the wrong reading is
    /// ACCEPTED: the reading is Pending, the market cannot settle on it, and the
    /// Safe's Invalid ruling deactivates the agent (nothing was locked to slash).
    function test_H1_fixed_exhaustedBondNeverShieldsAWrongReading() public {
        uint256 expiry = T0 + 300;
        bytes32 id = _round(roundFeed, expiry);
        vm.prank(alice);
        v4.buy(id, BinaryMarket.Outcome.No, 100e6, 0, type(uint256).max); // the true outcome: NO
        vm.prank(agent);
        v4.buy(id, BinaryMarket.Outcome.Yes, 100e6, 0, type(uint256).max);

        vm.warp(expiry + 300);
        bytes32 bad = _attest(roundFeed, 50); // WRONG
        bytes32 d1 = _attest(roundFeed, 1);
        vm.warp(expiry + 301);
        bytes32 d2 = _attest(roundFeed, 2);
        vm.prank(agent);
        vm.expectRevert(Dispute.AgentCannotChallenge.selector);
        dispute.challenge(d1, bytes32(0));
        vm.startPrank(griefer); // the agent's sock
        bytes32 dd1 = dispute.challenge(d1, bytes32(0));
        bytes32 dd2 = dispute.challenge(d2, bytes32(0));
        vm.stopPrank();
        assertEq(registry.availableBond(roundFeed, agent), 0, "bond exhausted");

        assertEq(dispute.challengeStake(bad), MINB);
        vm.prank(watcher);
        bytes32 db = dispute.challenge(bad, keccak256("coinbase says -50"));
        assertEq(uint8(attestation.getAttestation(bad).status), uint8(Attestation.DisputeStatus.Pending));

        vm.warp(expiry + 300 + DW_ROUND);
        (SettlementPolicy.Settlement s,) = _state(id);
        assertTrue(s != SettlementPolicy.Settlement.Resolvable, "a Pending reading never settles");

        vm.prank(safe);
        dispute.resolve(db, Dispute.DisputeOutcome.AttestationInvalid);
        assertFalse(registry.isActiveAgent(roundFeed, agent), "an Invalid ruling deactivates the agent");
        (s,) = _state(id);
        assertTrue(s != SettlementPolicy.Settlement.Resolvable, "the market never settles on the wrong reading");
        // The throwaways sit in the same window: the Safe rules every challenged
        // reading on its VALUE (1 and 2 are wrong too: the change was -50). Ruling
        // them "Valid" would settle the market on a throwaway.
        vm.startPrank(safe);
        dispute.resolve(dd1, Dispute.DisputeOutcome.AttestationInvalid);
        dispute.resolve(dd2, Dispute.DisputeOutcome.AttestationInvalid);
        vm.stopPrank();
        vm.warp(expiry + WINDOW + 1);
        (s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Voidable), "no valid reading: the market voids (refunds)");
    }

    /// FIXED (variant): throwaways stamped before expiry, bond exhausted by a sock;
    /// the wrong settling reading is still challengeable and never settles.
    function test_H1_variant_fixed_throwawaysBeforeExpiry() public {
        uint256 expiry = T0 + 900;
        bytes32 id = _round(roundFeed, expiry);
        vm.warp(expiry - 120);
        bytes32 d1 = _attest(roundFeed, 7);
        vm.warp(expiry - 60);
        bytes32 d2 = _attest(roundFeed, 8);
        vm.warp(expiry + 300);
        bytes32 bad = _attest(roundFeed, -999);
        vm.startPrank(griefer);
        dispute.challenge(d1, bytes32(0));
        dispute.challenge(d2, bytes32(0));
        vm.stopPrank();
        vm.prank(watcher);
        dispute.challenge(bad, bytes32(0));
        vm.warp(expiry + 300 + DW_ROUND);
        (SettlementPolicy.Settlement s,) = _state(id);
        assertTrue(s != SettlementPolicy.Settlement.Resolvable);
    }

    // ═══════════════ L: the agent front-runs the dispute on its own wrong reading ═══════════════

    /// FIXED (defence in depth): the agent cannot challenge its own reading, so an
    /// honest watcher is never pre-empted by the agent's own key.
    function test_L_fixed_agentCannotChallengeItsOwnReading() public {
        uint256 expiry = T0 + 300;
        _round(roundFeed, expiry);
        vm.warp(expiry + 300);
        bytes32 bad = _attest(roundFeed, 50);
        vm.prank(agent);
        vm.expectRevert(Dispute.AgentCannotChallenge.selector);
        dispute.challenge(bad, bytes32(0));
        vm.prank(watcher);
        bytes32 d = dispute.challenge(bad, keccak256("real evidence"));
        uint256 before = usdc.balanceOf(watcher);
        vm.prank(safe);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
        assertEq(usdc.balanceOf(watcher), before + 2 * MINB, "stake back + the agent's slashed minBond");
        assertEq(registry.getAgent(roundFeed, agent).bond, BOND - MINB);
    }

    // ═══════════════ M: event market - a griefer forces a void with the outcome known ═══════════════

    /// Event feeds: the agent publishes every 6 h with a 12 h dispute window, so two
    /// readings are always open to challenge. Two 2-USDC challenges right before
    /// expiry lock the whole 4-USDC bond; the settling attest at expiry reverts, and
    /// unless the Safe rules within the 1-hour settlement window the market is
    /// Voidable for good (a later Valid ruling does not bring it back).
    function _eventMarket(uint256 expiry) internal returns (bytes32 id) {
        vm.prank(agent);
        id = v4.createMarket(eventFeed, agent, 1, BinaryMarket.Comparator.GreaterOrEqual, expiry, 5e6);
        vm.prank(alice);
        v4.buy(id, BinaryMarket.Outcome.Yes, 200e6, 0, type(uint256).max);
        vm.prank(bob); // bob bet NO; by expiry the event has happened (YES)
        v4.buy(id, BinaryMarket.Outcome.No, 50e6, 0, type(uint256).max);
        vm.startPrank(bob);
        usdc.mint(bob, 10e6);
        usdc.approve(address(dispute), type(uint256).max);
        vm.stopPrank();
    }

    /// FIXED (was M-1), keeper side: the rounds agent stops periodic event
    /// publications one dispute window (+1 h) before the deadline, so at expiry no
    /// earlier reading is still challengeable and nothing can lock the bond.
    function test_M_fixed_quietPeriod_nothingToChallengeAtExpiry() public {
        uint256 expiry = T0 + 30 days;
        bytes32 id = _eventMarket(expiry);
        bytes32 p1 = _attest(eventFeed, 1);
        vm.warp(expiry - DW_EVENT - 1 hours - 60); // the last publication before the quiet period
        bytes32 p2 = _attest(eventFeed, 1);
        vm.warp(expiry - 60);
        vm.startPrank(bob);
        vm.expectRevert(Dispute.WindowClosed.selector);
        dispute.challenge(p1, bytes32(0));
        vm.expectRevert(Dispute.WindowClosed.selector);
        dispute.challenge(p2, bytes32(0));
        vm.stopPrank();
        vm.warp(expiry + 5);
        bytes32 settling = _attest(eventFeed, 1);
        // bob may still dispute the settling reading itself: it waits for the Safe
        vm.prank(bob);
        bytes32 d = dispute.challenge(settling, bytes32(0));
        vm.prank(safe);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationValid);
        vm.warp(expiry + 5 + DW_EVENT);
        v4.resolve(id);
        assertTrue(v4.getMarket(id).yesWon, "settles on the truth; bob's stake went to the agent");
    }

    /// FIXED (was M-1), contract + keeper: if challenges do lock the bond (e.g. an
    /// older keeper that published late), trading stops (AgentBondLocked: nobody
    /// farms the would-be void) and the keeper's FREE-bond top-up restores the
    /// settling reading.
    function test_M_fixed_lockedBond_haltsTrading_topUpRestoresSettlement() public {
        uint256 expiry = T0 + 30 days;
        bytes32 id = _eventMarket(expiry);
        vm.warp(expiry - 12 hours + 60);
        bytes32 p1 = _attest(eventFeed, 1);
        vm.warp(expiry - 6 hours + 60);
        bytes32 p2 = _attest(eventFeed, 1);
        vm.warp(expiry - 60);
        vm.startPrank(bob);
        dispute.challenge(p1, bytes32(0));
        dispute.challenge(p2, bytes32(0));
        vm.stopPrank();
        assertEq(registry.availableBond(eventFeed, agent), 0);
        vm.prank(alice);
        vm.expectRevert(BinaryMarket.AgentBondLocked.selector);
        v4.buy(id, BinaryMarket.Outcome.Yes, 1e6, 0, type(uint256).max);
        // the keeper sees Challenged and tops the FREE bond back up to 2x minBond
        vm.prank(agent);
        registry.topUpBond(eventFeed, 2 * MINB);
        vm.warp(expiry + 5);
        _attest(eventFeed, 1);
        vm.warp(expiry + 5 + DW_EVENT);
        (SettlementPolicy.Settlement s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Resolvable), "no forced void");
        v4.resolve(id);
        assertTrue(v4.getMarket(id).yesWon);
    }

    /// Top-up restores attestability: the keeper could defeat the freeze by
    /// topping up to 2x minBond FREE bond (it tops up to 2x minBond TOTAL today).
    function test_Info_topUpUnfreezes() public {
        vm.warp(T0 + 60);
        bytes32 p1 = _attest(eventFeed, 1);
        vm.warp(T0 + 120);
        bytes32 p2 = _attest(eventFeed, 1);
        vm.startPrank(griefer);
        dispute.challenge(p1, bytes32(0));
        dispute.challenge(p2, bytes32(0));
        vm.stopPrank();
        vm.prank(agent);
        registry.topUpBond(eventFeed, MINB);
        vm.warp(T0 + 180);
        _attest(eventFeed, 1); // works again
    }

    // ═══════════════════════════ boundaries ═══════════════════════════

    function test_boundaries_window() public {
        uint256 expiry = T0 + 300;
        bytes32 id = _round(roundFeed, expiry);
        // a reading one second before expiry is ignored
        vm.warp(expiry - 1);
        _attest(roundFeed, 111);
        (SettlementPolicy.Settlement s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Open));
        // at expiry: trading closed, Waiting
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(BinaryMarket.MarketExpired.selector);
        v4.buy(id, BinaryMarket.Outcome.Yes, 1e6, 0, type(uint256).max);
        (s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Waiting));
        // at close: still Waiting, not voidable
        vm.warp(expiry + WINDOW);
        (s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Waiting));
        vm.expectRevert(SettlementPolicy.NotVoidable.selector);
        v4.voidMarket(id);
        // a reading exactly at close counts
        _attest(roundFeed, 5);
        // at close + 1: found but not final -> Waiting (not Voidable)
        vm.warp(expiry + WINDOW + 1);
        (s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Waiting));
        // finalizes exactly at attest + DW
        vm.warp(expiry + WINDOW + DW_ROUND - 1);
        (s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Waiting));
        vm.warp(expiry + WINDOW + DW_ROUND);
        (s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Resolvable));
        v4.resolve(id);
        assertTrue(v4.getMarket(id).yesWon);
    }

    function test_boundaries_readingExactlyAtExpiryAndCloseOnePastIgnored() public {
        uint256 expiry = T0 + 300;
        bytes32 id = _round(roundFeed, expiry);
        vm.warp(expiry);
        _attest(roundFeed, -3); // at expiry: counts
        vm.warp(expiry + DW_ROUND);
        v4.resolve(id);
        assertFalse(v4.getMarket(id).yesWon);

        uint256 e2 = expiry + 3600;
        bytes32 id2 = _round(roundFeed, e2);
        vm.warp(e2 + WINDOW + 1);
        _attest(roundFeed, 9); // one second past close: ignored
        (SettlementPolicy.Settlement s,) = _state(id2);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Voidable));
    }

    function test_boundaries_challengeVsFinality() public {
        uint256 expiry = T0 + 300;
        bytes32 id = _round(roundFeed, expiry);
        vm.warp(expiry + 1);
        bytes32 a = _attest(roundFeed, 1);
        vm.warp(expiry + 1 + DW_ROUND - 1);
        assertFalse(attestation.isFinalized(a));
        vm.expectRevert(SettlementPolicy.SettlementPending.selector);
        v4.resolve(id);
        vm.warp(expiry + 1 + DW_ROUND);
        vm.prank(watcher);
        vm.expectRevert(Dispute.WindowClosed.selector);
        dispute.challenge(a, bytes32(0));
        v4.resolve(id);
    }

    function test_boundaries_graceAndLateRuling() public {
        uint256 expiry = T0 + 300;
        bytes32 id = _round(roundFeed, expiry);
        vm.warp(expiry + 300);
        bytes32 a = _attest(roundFeed, 1);
        vm.warp(expiry + 301);
        bytes32 b = _attest(roundFeed, -1); // later clean reading, ignored while a is pending
        b;
        vm.prank(griefer);
        bytes32 d = dispute.challenge(a, bytes32(0));
        vm.warp(expiry + WINDOW + GRACE);
        (SettlementPolicy.Settlement s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Waiting));
        vm.warp(expiry + WINDOW + GRACE + 1);
        (s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Voidable));
        // a Valid ruling after the grace, before anyone voided: resolvable again
        vm.prank(safe);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationValid);
        (s,) = _state(id);
        assertEq(uint8(s), uint8(SettlementPolicy.Settlement.Resolvable));
        v4.resolve(id);
        assertTrue(v4.getMarket(id).yesWon, "the first reading, not the later clean one");
    }

    function test_invalidFirstThenSecondSettles() public {
        uint256 expiry = T0 + 300;
        bytes32 id = _round(roundFeed, expiry);
        vm.warp(expiry + 300);
        bytes32 a = _attest(roundFeed, 1);
        vm.warp(expiry + 301);
        _attest(roundFeed, -1);
        vm.prank(watcher);
        bytes32 d = dispute.challenge(a, bytes32(0));
        vm.prank(safe);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
        assertFalse(registry.isActiveAgent(roundFeed, agent));
        vm.warp(expiry + 301 + DW_ROUND);
        v4.resolve(id);
        assertFalse(v4.getMarket(id).yesWon);
        // the agent is dead on this feed: it cannot correct anything else
        vm.prank(agent);
        vm.expectRevert(Attestation.AgentInactive.selector);
        attestation.attest(roundFeed, 1, bytes32(0));
    }

    function test_agentCannotResolveOwnDisputes_andSafeCannotBeAgent() public {
        vm.startPrank(agent);
        bytes32 f = registry.createFeed("self", keccak256("x"), MINB, DW_ROUND, agent);
        registry.registerAgent(f, keccak256("x"), BOND);
        vm.expectRevert(); // resolver not approved (and SelfResolvedFeed if it were)
        v4.createMarket(f, agent, 0, BinaryMarket.Comparator.GreaterThan, T0 + 300, 5e6);
        vm.stopPrank();
    }

    function test_strangerCannotAttestForAgent() public {
        vm.prank(griefer);
        vm.expectRevert(Attestation.AgentInactive.selector);
        attestation.attest(roundFeed, 1, bytes32(0));
        // nor register on the agent's feed
        usdc.mint(griefer, 10e6);
        vm.startPrank(griefer);
        usdc.approve(address(registry), type(uint256).max);
        vm.expectRevert(Registry.NotFeedCreator.selector);
        registry.registerAgent(roundFeed, keccak256("m"), BOND);
        vm.stopPrank();
    }

    // ═══════════════════════════ fuzz: settlement selection ═══════════════════════════

    struct Att {
        uint256 t;
        int256 v;
        bool challenged;
        uint256 ct; // challenge time
        uint8 ruling; // 0 none, 1 valid, 2 invalid
        uint256 rt; // ruling time
        bytes32 id;
        bytes32 did;
        bool exists;
        uint8 status; // model: 0 none 1 pending 2 valid 3 invalid
    }

    uint256 constant N = 6;
    Att[N] internal atts;
    uint256 fuzzExpiry;
    bool modelActive;

    /// For any set of readings (before, in and after the window), challenges and
    /// rulings (incl. none, and late ones), at every step the policy equals the
    /// reference: the FIRST reading stamped in [expiry, expiry+W] that is not ruled
    /// Invalid decides; Resolvable iff that reading is finalized (Valid, or undisputed
    /// past its dispute window); Voidable iff past the window with none, or past
    /// window+grace with one not final; resolve settles on exactly that value.
    function testFuzz_settlementSelection(uint256 seed) public {
        // big bond so challenges never run out (selection logic only)
        vm.prank(agent);
        registry.topUpBond(roundFeed, 100 * MINB);
        fuzzExpiry = T0 + 300;
        bytes32 id = _round(roundFeed, fuzzExpiry);
        modelActive = true;

        // events: (time, kind, index) kind 0 attest, 1 challenge, 2 rule
        uint256[3 * N] memory et;
        uint256[3 * N] memory ek;
        uint256[3 * N] memory ei;
        uint256 ne;
        uint256 tcur = fuzzExpiry - 290;
        for (uint256 i; i < N; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            tcur += 1 + (r % 1500); // spread readings over [expiry-~5m, ~expiry+2h]
            atts[i].t = tcur;
            atts[i].v = int256(r >> 128) % 7 - 3;
            atts[i].challenged = (r >> 8) % 3 != 0;
            atts[i].ct = tcur + ((r >> 16) % DW_ROUND); // strictly inside its window
            atts[i].ruling = uint8((r >> 32) % 3);
            // rulings: soon, or after window+grace (late)
            atts[i].rt = atts[i].ct + ((r >> 40) % 2 == 0 ? (r >> 48) % 3 hours : WINDOW + GRACE + (r >> 48) % 1 days);
            et[ne] = atts[i].t; ek[ne] = 0; ei[ne] = i; ne++;
            if (atts[i].challenged) {
                et[ne] = atts[i].ct; ek[ne] = 1; ei[ne] = i; ne++;
                if (atts[i].ruling != 0) { et[ne] = atts[i].rt; ek[ne] = 2; ei[ne] = i; ne++; }
            }
        }
        // stable insertion sort by (time, kind)
        for (uint256 a = 1; a < ne; a++) {
            uint256 x = et[a]; uint256 y = ek[a]; uint256 z = ei[a];
            uint256 b = a;
            while (b > 0 && (et[b - 1] > x || (et[b - 1] == x && ek[b - 1] > y))) {
                et[b] = et[b - 1]; ek[b] = ek[b - 1]; ei[b] = ei[b - 1]; b--;
            }
            et[b] = x; ek[b] = y; ei[b] = z;
        }
        bool settled;
        uint256 clock = T0;
        for (uint256 e; e < ne; e++) {
            if (et[e] > clock) { vm.warp(et[e]); clock = et[e]; }
            _apply(ek[e], ei[e]);
            if (!settled) settled = _check(id);
        }
        uint256 last = clock;
        uint256[4] memory probes = [last + 1, fuzzExpiry + WINDOW + DW_ROUND, fuzzExpiry + WINDOW + GRACE, fuzzExpiry + WINDOW + GRACE + 1];
        for (uint256 p; p < 4 && !settled; p++) {
            if (probes[p] > clock) { vm.warp(probes[p]); clock = probes[p]; }
            settled = _check(id);
        }
    }

    function _apply(uint256 kind, uint256 i) internal {
        Att storage a = atts[i];
        if (kind == 0) {
            if (!modelActive) return; // slashed agents cannot attest
            vm.prank(agent);
            a.id = attestation.attest(roundFeed, a.v, keccak256(abi.encode(i, block.timestamp)));
            a.exists = true;
        } else if (kind == 1) {
            if (!a.exists) return;
            vm.prank(watcher);
            a.did = dispute.challenge(a.id, bytes32(i));
            a.status = 1;
        } else {
            if (!a.exists || a.status != 1) return;
            vm.prank(safe);
            dispute.resolve(a.did, a.ruling == 1 ? Dispute.DisputeOutcome.AttestationValid : Dispute.DisputeOutcome.AttestationInvalid);
            a.status = a.ruling == 1 ? 2 : 3;
            if (a.ruling == 2) modelActive = false;
        }
    }

    /// Compare the contract to the model; when Resolvable/Voidable, sometimes act.
    function _check(bytes32 id) internal returns (bool settled) {
        uint256 close = fuzzExpiry + WINDOW;
        SettlementPolicy.Settlement want;
        int256 wantV;
        bool found;
        bool fin;
        int256 fv;
        if (block.timestamp < fuzzExpiry) {
            want = SettlementPolicy.Settlement.Open;
        } else {
            for (uint256 i; i < N; i++) {
                Att storage a = atts[i];
                if (!a.exists || a.t < fuzzExpiry || a.t > close) continue;
                if (a.status == 3) continue;
                found = true;
                fv = a.v;
                fin = a.status == 2 || (a.status == 0 && block.timestamp >= a.t + DW_ROUND);
                break;
            }
            if (found && fin) { want = SettlementPolicy.Settlement.Resolvable; wantV = fv; }
            else if (block.timestamp <= close) want = SettlementPolicy.Settlement.Waiting;
            else if (!found) want = SettlementPolicy.Settlement.Voidable;
            else if (block.timestamp > close + GRACE) want = SettlementPolicy.Settlement.Voidable;
            else want = SettlementPolicy.Settlement.Waiting;
        }
        (SettlementPolicy.Settlement s, int256 v) = _state(id);
        assertEq(uint8(s), uint8(want), "state");
        if (s == SettlementPolicy.Settlement.Resolvable) {
            assertEq(v, wantV, "value");
            v4.resolve(id);
            assertEq(v4.getMarket(id).yesWon, wantV > 0);
            return true;
        }
        if (s == SettlementPolicy.Settlement.Voidable) {
            // void only sometimes, so later Valid rulings also get exercised
            if (uint256(keccak256(abi.encode(block.timestamp))) % 2 == 0) {
                v4.voidMarket(id);
                return true;
            }
        } else {
            vm.expectRevert(SettlementPolicy.NotVoidable.selector);
            v4.voidMarket(id);
        }
        return false;
    }
}
