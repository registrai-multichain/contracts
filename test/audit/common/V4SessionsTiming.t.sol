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

/// Independent audit (V4 scope): sessions, creation gating, resolution timing.
/// Mainnet-like params: MIN_BOND 2 USDC, SETTLEMENT_WINDOW 1 h, grace 7 d, feed
/// dispute window 10 min, 13-feed rotation per asset, 5 USDC seeds.
contract V4SessionsTimingTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsV4 markets;

    address agent = makeAddr("agent");
    address resolverSafe = makeAddr("resolverSafe");
    address treasury = makeAddr("treasury");
    address owner = makeAddr("owner");
    address delegate = makeAddr("delegate");
    address attacker = makeAddr("attacker");
    address winner = makeAddr("winner");
    address loser = makeAddr("loser");

    bytes32 feed; // one of the 13 rotation feeds of an asset
    uint256 constant DW = 10 minutes;
    uint256 constant WINDOW = 1 hours;
    uint256 constant GRACE = 7 days;
    uint256 constant SEED = 5e6;

    function setUp() public {
        vm.warp(1_790_000_100 - (1_790_000_100 % 300) + 300);
        usdc = new MockUSDC();
        registry = new Registry(usdc, 2e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        markets = new MarketsV4(ledger, registry, attestation, address(this), treasury, WINDOW, GRACE);
        markets.setApprovedResolver(resolverSafe, true);
        markets.setApprovedAgent(agent, true);

        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feed = registry.createFeed("btc-5m-change-0", keccak256("m"), 2e6, DW, resolverSafe);
        registry.registerAgent(feed, keccak256("m"), 4e6); // bond_multiple 2
        vm.stopPrank();
        _fund(agent);
        _fund(owner);
        _fund(attacker);
        _fund(winner);
        _fund(loser);
    }

    function _fund(address a) internal {
        usdc.mint(a, 10_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        usdc.approve(address(dispute), type(uint256).max);
        ledger.deposit(1_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _open(uint256 expiry) internal returns (bytes32 id) {
        vm.prank(agent);
        id = markets.createMarket(feed, agent, 0, BinaryMarket.Comparator.GreaterThan, expiry, SEED);
    }

    function _next(uint256 k) internal view returns (uint256) {
        return (block.timestamp / 300 + k) * 300;
    }

    // ───────────── verification of the known fixes ─────────────

    /// C-1: a stranger cannot open a market that names our agent (any expiry).
    function test_fixC1_strangerCannotNameOurAgent() public {
        uint256 e = _next(1);
        vm.prank(attacker);
        vm.expectRevert(MarketsV4.NotTheAgent.selector);
        markets.createMarket(feed, agent, 0, BinaryMarket.Comparator.GreaterThan, e, SEED);
        // nor name itself as agent (not approved)
        vm.prank(attacker);
        vm.expectRevert(BinaryMarket.AgentNotRegistered.selector); // attacker is no agent on this feed
        markets.createMarket(feed, attacker, 0, BinaryMarket.Comparator.GreaterThan, e, SEED);
    }

    /// H-1 / L-1: a dust session buy cannot dump the owner's hand position, and a
    /// revoked-then-renewed delegate has no sell rights left.
    function test_fixH1_dustBuyCannotDump_andRevokeEndsSellRights() public {
        bytes32 id = _open(_next(1));
        vm.prank(owner);
        uint256 mine = markets.buy(id, BinaryMarket.Outcome.Yes, 100e6, 0, block.timestamp);
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(owner);
        markets.setSession(delegate, 10e6, exp);
        vm.prank(delegate);
        uint256 dust = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 1e6, 0, block.timestamp);
        uint256 dumpAll = mine + dust;
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionSharesExceeded.selector);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, dumpAll, 0, block.timestamp);
        vm.prank(owner);
        markets.revokeSession(delegate);
        vm.prank(owner);
        markets.setSession(delegate, 10e6, exp);
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionSharesExceeded.selector);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, dust, 0, block.timestamp);
    }

    // ───────────── findings ─────────────

    /// FINDING (Low): sessionShares is never reconciled with the owner's own
    /// sells. Delegate buys N for the owner; the owner sells those N by hand and
    /// later buys a fresh position by hand; the delegate can still sell N of the
    /// owner's HAND-BOUGHT shares (at any price: minCollateralOut = 0), contrary to
    /// "shares the owner added by hand are out of its reach".
    function test_finding_delegateSellsSharesTheOwnerRebuiltByHand() public {
        bytes32 id = _open(_next(2));
        vm.prank(owner);
        markets.setSession(delegate, 10e6, uint64(block.timestamp + 1 days));
        vm.prank(delegate);
        uint256 n = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 10e6, 0, block.timestamp);

        // owner exits the session position by hand ...
        vm.prank(owner);
        markets.sell(id, BinaryMarket.Outcome.Yes, n, 0, block.timestamp);
        assertEq(markets.yesBalance(id, owner), 0);
        // ... and later buys a larger position by hand
        vm.prank(owner);
        uint256 hand = markets.buy(id, BinaryMarket.Outcome.Yes, 200e6, 0, block.timestamp);
        assertEq(markets.sessionShares(owner, delegate, id, BinaryMarket.Outcome.Yes), n, "stale sell right");

        // leaked delegate key + attacker sandwich: push YES down, dump the owner's
        // hand-bought shares for almost nothing, unwind.
        vm.prank(attacker);
        uint256 noShares = markets.buy(id, BinaryMarket.Outcome.No, 900e6, 0, block.timestamp);
        vm.prank(delegate);
        uint256 got = markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, n, 0, block.timestamp);
        vm.prank(attacker);
        markets.sell(id, BinaryMarket.Outcome.No, noShares, 0, block.timestamp);

        assertEq(markets.yesBalance(id, owner), hand - n, "hand-bought shares were sold by the delegate");
        emit log_named_uint("hand-bought YES shares sold by delegate", n);
        emit log_named_uint("owner received for them", got);
    }

    /// FINDING (Low, resolution timing): a reading carries no as-of time, so any
    /// attestation on a feed stamped inside a market's window settles it. The
    /// rotation (13 feeds x 5 min = 65 min vs a 60 min window) leaves 5 minutes of
    /// slack: a reading for round A that lands > 65 min after A's expiry (keeper
    /// backlog / stuck tx; the keeper's `now > expiry + window` guard uses the
    /// chain time read at the START of a tick) settles round B = A + 65 min, which
    /// reuses the feed, on A's change.
    function test_finding_lateReadingOfRoundA_settlesRoundB() public {
        uint256 eA = _next(1);
        bytes32 a = _open(eA);
        // 13 rounds later the same feed is reused (the keeper opens B 5 min before)
        vm.warp(eA + 60 minutes);
        uint256 eB = eA + 65 minutes;
        bytes32 b = _open(eB);
        vm.prank(winner);
        markets.buy(b, BinaryMarket.Outcome.No, 50e6, 0, block.timestamp); // B's real change will be Down

        // A's reading (A went UP, +1234) is sent at eA+59m59s by the keeper but only
        // lands at eB + 30 s: outside A's window, first in B's.
        vm.warp(eB + 30);
        vm.prank(agent);
        attestation.attest(feed, 1234, keccak256("reading for round A (as-of eA)"));

        vm.warp(eB + 5 minutes + 5); // B's own reading (Down, -50) goes in on time
        vm.prank(agent);
        attestation.attest(feed, -50, keccak256("reading for round B (as-of eB)"));

        vm.warp(block.timestamp + DW);
        markets.resolve(b);
        assertTrue(markets.getMarket(b).yesWon, "B settled Up on A's change; its real change was Down");
        (SettlementPolicy.Settlement sA,) = markets.settlementState(a);
        assertEq(uint256(sA), uint256(SettlementPolicy.Settlement.Voidable), "A voids");
    }

    /// FINDING (Low/Info, F2 variant): a LOSING trader can challenge the settling
    /// reading for MIN_BOND (2 USDC). If the resolver Safe does not rule within
    /// window + grace (1 h + 7 d) the market voids and the loser gets its net cost
    /// back (the winner only its stake). Cost if the Safe does rule Valid: 2 USDC.
    function test_finding_loserChallenge_voidsIfResolverSilent() public {
        uint256 e = _next(1);
        bytes32 id = _open(e);
        vm.prank(winner);
        markets.buy(id, BinaryMarket.Outcome.Yes, 100e6, 0, block.timestamp);
        vm.prank(loser);
        markets.buy(id, BinaryMarket.Outcome.No, 100e6, 0, block.timestamp);
        uint256 loserCost = markets.netCost(id, loser);

        vm.warp(e + 5 minutes + 3);
        vm.prank(agent);
        bytes32 att = attestation.attest(feed, 777, keccak256("Up")); // YES wins
        vm.prank(loser);
        dispute.challenge(att, keccak256("frivolous"));
        // Safe never rules
        vm.warp(e + WINDOW + GRACE + 1);
        markets.voidMarket(id);
        uint256 beforeBal = ledger.balanceOf(loser);
        vm.prank(loser);
        markets.redeem(id);
        assertEq(ledger.balanceOf(loser) - beforeBal, loserCost, "loser refunded in full");
    }

    /// Info: an APPROVED creator may still name the rounds agent on a rounds feed
    /// with any on-grid expiry; such a market settles on whatever rounds reading
    /// lands first in its window (the keeper ignores it). No approved creator
    /// exists at launch.
    function test_info_approvedCreatorMarketSettlesOnARoundsReading() public {
        address ours = makeAddr("approvedCreator");
        markets.setApprovedCreator(ours, true);
        _fund(ours);
        uint256 eRound = _next(1);
        _open(eRound);
        vm.prank(ours);
        bytes32 m = markets.createMarket(feed, agent, 100_000, BinaryMarket.Comparator.GreaterThan, eRound, SEED);
        vm.warp(eRound + 5 minutes + 3);
        vm.prank(agent);
        attestation.attest(feed, 200_000, keccak256("round change"));
        vm.warp(block.timestamp + DW);
        markets.resolve(m);
        assertTrue(markets.getMarket(m).yesWon);
    }

    /// FINDING (Medium): the event market can be forced to VOID for 2 x MIN_BOND.
    /// Mainnet config: event feed disputeWindow 12 h, publishEvery 6 h, bond =
    /// bond_multiple 2 x minBond. So at any moment two of the agent's event readings
    /// are still challengeable; challenging both locks the whole bond and the agent
    /// can no longer attest (free bond < minBond). The keeper's bond_upkeep tops up
    /// only when `bond < target` (not `bond - locked`), so the feed stays frozen
    /// until the resolver Safe rules. Timed just before the event's expiry (Dec 31,
    /// 23:00 UTC) the agent cannot attest inside [expiry, expiry + 1 h]: the market
    /// voids and the losing side gets its net cost back.
    function test_finding_eventMarket_twoChallengesForceVoid() public {
        vm.startPrank(agent);
        bytes32 ev = registry.createFeed("arc-token-tradable", keccak256("m"), 2e6, 12 hours, resolverSafe);
        registry.registerAgent(ev, keccak256("m"), 4e6);
        vm.stopPrank();
        uint256 e = _next(1) + 1 days;
        vm.prank(agent);
        bytes32 id = markets.createMarket(ev, agent, 1, BinaryMarket.Comparator.GreaterOrEqual, e, SEED);
        vm.prank(winner);
        markets.buy(id, BinaryMarket.Outcome.Yes, 100e6, 0, block.timestamp);
        vm.prank(loser);
        markets.buy(id, BinaryMarket.Outcome.No, 100e6, 0, block.timestamp);
        uint256 loserCost = markets.netCost(id, loser);

        // the agent's 6-hourly publications (the event HAPPENED: value 1)
        vm.warp(e - 7 hours);
        vm.prank(agent);
        bytes32 r1 = attestation.attest(ev, 1, keccak256("pub1"));
        vm.warp(e - 1 hours);
        vm.prank(agent);
        bytes32 r2 = attestation.attest(ev, 1, keccak256("pub2"));

        // griefer (a NO holder) challenges both open readings: 4 USDC
        vm.warp(e - 10 minutes);
        vm.startPrank(loser);
        dispute.challenge(r1, keccak256("x"));
        dispute.challenge(r2, keccak256("y"));
        vm.stopPrank();

        // the settlement reading cannot be made inside the window
        vm.warp(e + 1 minutes);
        vm.prank(agent);
        vm.expectRevert(Attestation.InsufficientAvailableBond.selector);
        attestation.attest(ev, 1, keccak256("settle"));

        vm.warp(e + WINDOW + 1);
        markets.voidMarket(id);
        uint256 b0 = ledger.balanceOf(loser);
        vm.prank(loser);
        markets.redeem(id);
        assertEq(ledger.balanceOf(loser) - b0, loserCost, "NO side refunded although YES happened");
    }
}
