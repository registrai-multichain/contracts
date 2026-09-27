// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BinaryMathBase} from "./BinaryMathBase.t.sol";
import {BinaryMarket} from "../../../src/nanopay/BinaryMarket.sol";
import {MarketsV4} from "../../../src/nanopay/MarketsV4.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {Attestation} from "../../../src/Attestation.sol";

contract BinaryMathHandler is Test {
    MarketsV4 public markets;
    NanoLedger public ledger;
    Attestation public attestation;
    bytes32 public feedId;
    address public agent;
    address public creator;
    address[4] public actors;
    bytes32[] public ids;
    mapping(bytes32 => uint256) public lastK;
    bool public kDecreased;
    uint256 public calls;
    uint256 public nResolved;
    uint256 public nVoided;
    uint256 public nRedeemed;
    uint256 public nLP;
    uint256 public nSwept;
    uint256 public nSells;

    constructor(
        MarketsV4 m,
        NanoLedger l,
        Attestation a,
        bytes32 f,
        address ag,
        address cr,
        address[4] memory act
    ) {
        markets = m;
        ledger = l;
        attestation = a;
        feedId = f;
        agent = ag;
        creator = cr;
        actors = act;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function _id(uint256 s) internal view returns (bytes32) {
        return ids[s % ids.length];
    }

    /// Prefer a market still open for trading, scanning from the seed.
    function _openId(uint256 s) internal view returns (bytes32) {
        uint256 n = ids.length;
        for (uint256 i; i < n; i++) {
            bytes32 id = ids[(s + i) % n];
            MarketsV4.Market memory m = markets.getMarket(id);
            if (m.phase == BinaryMarket.Phase.Trading && block.timestamp < m.expiry) return id;
        }
        return ids[s % n];
    }

    /// Prefer a settled market where `who` still has a claim.
    function _claimId(uint256 s, address who) internal view returns (bytes32) {
        uint256 n = ids.length;
        for (uint256 i; i < n; i++) {
            bytes32 id = ids[(s + i) % n];
            MarketsV4.Market memory m = markets.getMarket(id);
            if (m.phase == BinaryMarket.Phase.Trading) continue;
            bool c = m.phase == BinaryMarket.Phase.Resolved
                ? (m.yesWon ? markets.yesBalance(id, who) : markets.noBalance(id, who)) > 0
                : markets.netCost(id, who) > 0;
            if (c) return id;
        }
        return ids[s % n];
    }

    function _checkK(bytes32 id) internal {
        MarketsV4.Market memory m = markets.getMarket(id);
        uint256 k = m.yesReserve * m.noReserve;
        if (k < lastK[id]) kDecreased = true;
        lastK[id] = k;
    }

    function newMarket(uint256 liq, uint256 ttl) external {
        if (ids.length >= 25) return;
        liq = bound(liq, 5e6, 1e9);
        ttl = bound(ttl, 1, 3 hours);
        uint256 expiry = ((block.timestamp + ttl) / 5 minutes + 1) * 5 minutes;
        vm.prank(creator);
        try markets.createMarket(feedId, agent, int256(100), BinaryMarket.Comparator.GreaterOrEqual, expiry, liq)
        returns (bytes32 id) {
            ids.push(id);
            lastK[id] = liq * liq;
        } catch {}
    }

    function buy(uint256 a, uint256 m, bool yes, uint256 amt) external {
        if (ids.length == 0) return;
        bytes32 id = _openId(m);
        amt = bound(amt, 1, 1e10);
        vm.prank(actors[a % 4]);
        try markets.buy(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, amt, 0, type(uint256).max) {
            calls++;
        } catch {}
        _checkK(id);
    }

    function sell(uint256 a, uint256 m, bool yes, uint256 frac) external {
        if (ids.length == 0) return;
        bytes32 id = _openId(m);
        address who = actors[a % 4];
        uint256 bal = yes ? markets.yesBalance(id, who) : markets.noBalance(id, who);
        if (bal == 0) return;
        uint256 s = (bal * bound(frac, 1, 10_000)) / 10_000;
        if (s == 0) s = 1;
        vm.prank(who);
        try markets.sell(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, s, 0, type(uint256).max) {
            calls++;
            nSells++;
        } catch {}
        _checkK(id);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 20 minutes));
    }

    function attest(bool yes, uint256 salt) external {
        if (salt % 3 != 0) return; // leave room for voids
        vm.prank(agent);
        try attestation.attest(feedId, yes ? int256(1000) : int256(0), bytes32(salt)) {} catch {}
    }

    function resolve(uint256 m) external {
        if (ids.length == 0) return;
        for (uint256 i; i < ids.length; i++) {
            try markets.resolve(ids[(m + i) % ids.length]) {
                nResolved++;
            } catch {}
        }
    }

    function voidM(uint256 m) external {
        if (ids.length == 0) return;
        for (uint256 i; i < ids.length; i++) {
            try markets.voidMarket(ids[(m + i) % ids.length]) {
                nVoided++;
            } catch {}
        }
    }

    function redeem(uint256 a, uint256 m) external {
        if (ids.length == 0) return;
        address who = actors[a % 4];
        bytes32 id = _claimId(m, who);
        vm.prank(who);
        try markets.redeem(id) {
            nRedeemed++;
        } catch {}
    }

    function claimLP(uint256 m) external {
        if (ids.length == 0) return;
        bytes32 id = _id(m);
        for (uint256 i; i < ids.length; i++) {
            bytes32 c = ids[(m + i) % ids.length];
            if (markets.getMarket(c).phase != BinaryMarket.Phase.Trading && markets.lpShares(c, creator) > 0) {
                id = c;
                break;
            }
        }
        vm.prank(creator);
        try markets.claimLP(id) {
            nLP++;
        } catch {}
    }

    function sweep(uint256 m) external {
        if (ids.length == 0) return;
        for (uint256 i; i < ids.length; i++) {
            try markets.sweepDust(ids[(m + i) % ids.length]) {
                nSwept++;
            } catch {}
        }
    }
}

/// Stateful conservation of the BinaryMarket engine (MarketsV4) across many
/// markets, traders, sells, settlement, void, claims and sweeps.
contract BinaryMathInvariantTest is BinaryMathBase {
    BinaryMathHandler handler;
    address[4] actors;

    function setUp() public {
        _deploy();
        actors = [creator, address(0xA11CE), address(0xB0B), address(0xCA501)];
        for (uint256 i = 1; i < 4; i++) {
            _fund(actors[i], 1e14);
        }
        handler = new BinaryMathHandler(markets, ledger, attestation, feedId, agent, creator, actors);
        handler.newMarket(5e6, 10 minutes);
        handler.newMarket(100e6, 1 hours);
        targetContract(address(handler));
    }

    function test_handlerSmoke() public {
        handler.buy(1, 0, true, 1e6);
        handler.buy(2, 1, false, 1e6);
        assertEq(handler.calls(), 2, "buys failed");
        handler.sell(1, 0, true, 5000);
        assertEq(handler.nSells(), 1, "sell failed");
    }

    uint256 tResolved;
    uint256 tVoided;
    uint256 tRedeemed;
    uint256 tLP;
    uint256 tSwept;
    uint256 tSells;

    function afterInvariant() public {
        tResolved += handler.nResolved();
        tVoided += handler.nVoided();
        tRedeemed += handler.nRedeemed();
        tLP += handler.nLP();
        tSwept += handler.nSwept();
        tSells += handler.nSells();
        console2.log("resolved/voided/redeemed", handler.nResolved(), handler.nVoided(), handler.nRedeemed());
        console2.log("lp/swept/sells", handler.nLP(), handler.nSwept(), handler.nSells());
        console2.log("successful trades", handler.calls(), handler.idsLength());
    }

    function _outstanding(bytes32 id) internal view returns (uint256 ys, uint256 ns, uint256 nc) {
        for (uint256 i; i < 4; i++) {
            ys += markets.yesBalance(id, actors[i]);
            ns += markets.noBalance(id, actors[i]);
            nc += markets.netCost(id, actors[i]);
        }
    }

    /// The contract's ledger balance equals exactly what it owes: C + escrow for
    /// every trading market, `unpaid` for every settled one.
    function invariant_balanceEqualsObligations() public view {
        uint256 owed;
        uint256 n = handler.idsLength();
        for (uint256 j; j < n; j++) {
            bytes32 id = handler.ids(j);
            MarketsV4.Market memory m = markets.getMarket(id);
            if (m.phase == BinaryMarket.Phase.Trading) owed += markets.collateralOf(id) + markets.agentEscrow(id);
            else owed += markets.unpaid(id);
        }
        assertEq(ledger.balanceOf(address(markets)), owed, "market ledger balance != obligations");
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger insolvent");
    }

    /// While trading: shares outside the pool + reserve == C on each side;
    /// sum of netCost == totalNetCost; k never decreased.
    function invariant_tradingConservation() public view {
        assertFalse(handler.kDecreased(), "k decreased");
        uint256 n = handler.idsLength();
        for (uint256 j; j < n; j++) {
            bytes32 id = handler.ids(j);
            MarketsV4.Market memory m = markets.getMarket(id);
            if (m.phase != BinaryMarket.Phase.Trading) continue;
            (uint256 ys, uint256 ns, uint256 nc) = _outstanding(id);
            uint256 c = markets.collateralOf(id);
            assertEq(ys + m.yesReserve, c, "YES supply != C");
            assertEq(ns + m.noReserve, c, "NO supply != C");
            assertEq(nc, markets.totalNetCost(id), "netCost sum");
        }
    }

    /// After settlement: unpaid covers every outstanding claim (exactly, when
    /// resolved) and claimsLeft counts exactly the claimants still owed.
    function invariant_settledCoverage() public view {
        uint256 n = handler.idsLength();
        for (uint256 j; j < n; j++) {
            bytes32 id = handler.ids(j);
            MarketsV4.Market memory m = markets.getMarket(id);
            if (m.phase == BinaryMarket.Phase.Trading) continue;
            uint256 owed;
            uint256 claimants;
            for (uint256 i; i < 4; i++) {
                owed += markets.redeemable(id, actors[i]);
                bool c = m.phase == BinaryMarket.Phase.Resolved
                    ? (m.yesWon ? markets.yesBalance(id, actors[i]) : markets.noBalance(id, actors[i])) > 0
                    : markets.netCost(id, actors[i]) > 0;
                if (c) claimants++;
            }
            owed += markets.claimableLP(id, creator);
            if (markets.lpShares(id, creator) > 0) claimants++;
            assertEq(markets.claimsLeft(id), claimants, "claimsLeft mismatch");
            assertGe(markets.unpaid(id), owed, "unpaid < outstanding claims");
            if (m.phase == BinaryMarket.Phase.Resolved) assertEq(markets.unpaid(id), owed, "resolved not exact");
            else assertLe(markets.unpaid(id) - owed, claimants + 4, "void dust too large");
        }
    }
}
