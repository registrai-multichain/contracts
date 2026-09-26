// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {BinaryMarket} from "../../src/nanopay/BinaryMarket.sol";

/// Drives sessions at random: the owner (re)grants and revokes, its delegate
/// buys / sells / redeems for it, a stranger key tries the same, time moves, the
/// round settles. Ghost accounting tracks what the delegate spent since the last
/// grant.
contract SessionHandler is Test {
    MarketsV4 public markets;
    NanoLedger public ledger;
    Attestation public attestation;
    bytes32 public feedId;
    bytes32 public id;
    address public owner;
    address public delegate;
    address public stranger;
    address public oracle;
    uint256 public expiry;

    uint256 public grantedCap;      // cap of the current session
    uint256 public spentSinceGrant; // buyFor collateral since that grant
    uint256 public strangerSucceeded;
    uint256 public delegateSold;
    bool public settled;

    constructor(MarketsV4 m, NanoLedger l, Attestation a, bytes32 f, bytes32 mid, uint256 exp, address o, address d, address s, address orc) {
        (markets, ledger, attestation, feedId, id, expiry, owner, delegate, stranger, oracle) = (m, l, a, f, mid, exp, o, d, s, orc);
    }

    function grant(uint128 cap, uint32 dur) public {
        cap = uint128(bound(cap, 0, 200e6));
        uint64 exp = uint64(block.timestamp + bound(dur, 1, 7 days));
        vm.prank(owner);
        markets.setSession(delegate, cap, exp);
        (grantedCap, spentSinceGrant) = (cap, 0);
    }

    function revoke() public {
        vm.prank(owner);
        markets.revokeSession(delegate);
        (grantedCap, spentSinceGrant) = (0, 0);
    }

    function delegateBuy(uint256 amt, bool yes) public {
        amt = bound(amt, 1, 60e6);
        vm.prank(delegate);
        try markets.buyFor(owner, id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, amt, 0, block.timestamp) {
            spentSinceGrant += amt;
        } catch {}
    }

    function delegateSell(uint256 frac, bool yes) public {
        uint256 bal = yes ? markets.yesBalance(id, owner) : markets.noBalance(id, owner);
        if (bal == 0) return;
        uint256 amt = bound(frac, 1, bal);
        vm.prank(delegate);
        try markets.sellFor(owner, id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, amt, 0, block.timestamp) {
            delegateSold++;
        } catch {}
    }

    function strangerTries(uint256 amt, uint8 which) public {
        amt = bound(amt, 1, 10e6);
        vm.startPrank(stranger);
        if (which % 3 == 0) {
            try markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, amt, 0, block.timestamp) { strangerSucceeded++; } catch {}
        } else if (which % 3 == 1) {
            try markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, 1, 0, block.timestamp) { strangerSucceeded++; } catch {}
        } else {
            try markets.redeemFor(owner, id) { strangerSucceeded++; } catch {}
        }
        vm.stopPrank();
    }

    function warp(uint32 secs) public {
        vm.warp(block.timestamp + bound(secs, 1, 2 hours));
    }

    function settle() public {
        if (settled || block.timestamp < expiry) return;
        vm.prank(oracle);
        try attestation.attest(feedId, 7, bytes32("r")) {} catch { return; }
        vm.warp(block.timestamp + 10 minutes);
        try markets.resolve(id) { settled = true; } catch {}
    }

    function delegateRedeem() public {
        vm.prank(delegate);
        try markets.redeemFor(owner, id) {} catch {}
    }
}

contract MarketsV4SessionsInvariantTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    MarketsV4 markets;
    Attestation attestation;
    SessionHandler h;
    address owner = address(0x0DD);
    address delegate = address(0xDE1E);
    address stranger = address(0x5EE);
    address oracle = address(0x0AC1E);
    uint256 ownerStart;

    function setUp() public {
        vm.warp(1_790_000_100);
        usdc = new MockUSDC();
        Registry registry = new Registry(usdc, 1e6);
        attestation = new Attestation(registry);
        Dispute dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        markets = new MarketsV4(ledger, registry, attestation, address(this), address(0x7AEA), 1 hours, 1 days);
        markets.setApprovedResolver(address(0xBEEF), true);
        markets.setApprovedAgent(oracle, true);
        usdc.mint(oracle, 100e6);
        vm.startPrank(oracle);
        usdc.approve(address(registry), type(uint256).max);
        bytes32 feedId = registry.createFeed("registrai-data:btc-usd-5m-change-0", keccak256("m"), 1e6, 10 minutes, address(0xBEEF));
        registry.registerAgent(feedId, keccak256("m"), 1e6);
        vm.stopPrank();
        for (uint256 i; i < 3; i++) {
            address a = [owner, oracle, stranger][i];
            usdc.mint(a, 10_000e6);
            vm.startPrank(a);
            usdc.approve(address(ledger), type(uint256).max);
            ledger.deposit(1_000e6);
            ledger.approveSpender(address(markets), type(uint256).max);
            vm.stopPrank();
        }
        uint256 expiry = block.timestamp + 300;
        vm.prank(oracle);
        bytes32 id = markets.createMarket(feedId, oracle, 0, BinaryMarket.Comparator.GreaterThan, expiry, 5e6);
        h = new SessionHandler(markets, ledger, attestation, feedId, id, expiry, owner, delegate, stranger, oracle);
        ownerStart = ledger.balanceOf(owner);
        targetContract(address(h));
    }

    /// The delegate never holds anything: no ledger balance, no shares.
    function invariant_theDelegateHoldsNothing() public view {
        assertEq(ledger.balanceOf(delegate), 0);
        assertEq(markets.yesBalance(h.id(), delegate), 0);
        assertEq(markets.noBalance(h.id(), delegate), 0);
    }

    /// Buys since the last grant never exceed that grant's cap, and the contract's
    /// remaining allowance is exactly the rest.
    function invariant_theCapBinds() public view {
        assertLe(h.spentSinceGrant(), h.grantedCap());
        (uint128 left,) = markets.sessions(owner, delegate);
        if (h.grantedCap() > 0) assertEq(left, h.grantedCap() - h.spentSinceGrant());
    }

    /// A key without a session from the owner never moves the owner's funds.
    /// Every share the delegate can sell for the owner sits in a market it bought into.
    function invariant_sellsOnlyWhereTheDelegateBought() public view {
        if (!markets.sessionMarket(owner, delegate, h.id())) assertEq(h.delegateSold(), 0);
    }

    function invariant_aStrangerNeverActs() public view {
        assertEq(h.strangerSucceeded(), 0);
    }

    /// The ledger stays fully backed.
    function invariant_ledgerSolvent() public view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed());
    }
}

/// Fuzz: any sequence of buys under one grant spends at most the cap, and a
/// delegated buy always equals the same buy by the owner.
contract MarketsV4SessionsFuzzTest is MarketsV4SessionsInvariantTest {
    function testFuzz_buysNeverExceedTheCap(uint128 cap, uint256[6] memory amts) public {
        cap = uint128(bound(cap, 1e4, 100e6));
        vm.prank(owner);
        markets.setSession(delegate, cap, uint64(block.timestamp + 1 days));
        uint256 spent;
        uint256 before = ledger.balanceOf(owner);
        bytes32 mid = h.id(); // read before any prank: a call in the arguments would consume it
        for (uint256 i; i < amts.length; i++) {
            uint256 a = i == 0 ? bound(amts[i], 1e4, cap) : bound(amts[i], 1, 50e6); // the first always fits
            vm.prank(delegate);
            try markets.buyFor(owner, mid, BinaryMarket.Outcome.Yes, a, 0, block.timestamp) {
                spent += a;
            } catch {}
        }
        assertLe(spent, cap);
        assertGt(spent, 0, "at least the first buy fits (a vacuous run would prove nothing)");
        assertEq(before - ledger.balanceOf(owner), spent, "the owner paid exactly what the delegate spent");
        assertEq(ledger.balanceOf(delegate), 0);
    }

    function testFuzz_delegatedBuyEqualsOwnBuy(uint256 amt, bool yes) public {
        amt = bound(amt, 1e4, 80e6);
        BinaryMarket.Outcome o = yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No;
        bytes32 mid = h.id();
        vm.prank(owner);
        markets.setSession(delegate, type(uint128).max, uint64(block.timestamp + 1 days));
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        uint256 direct = markets.buy(mid, o, amt, 0, block.timestamp);
        vm.revertToState(snap);
        vm.prank(delegate);
        assertEq(markets.buyFor(owner, mid, o, amt, 0, block.timestamp), direct);
    }
}
