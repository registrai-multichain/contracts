// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";

/// Audit handler: every public NanoLedger function, with ghost accounting for exact
/// conservation. Records violations instead of reverting so the invariants say what broke.
contract LedgerHandler is Test {
    MockUSDC public usdc;
    NanoLedger public ledger;
    address public governor;
    address[4] public actors;
    bytes32[3] public poolIds = [bytes32("p0"), bytes32("p1"), bytes32("p2")];
    bool[3] public poolMade;

    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostAccrued; // moved from the source's balance into pools
    uint256 public ghostPoolCredited; // credited out of pools (claims + setShares settlements)
    uint256 public ghostDonations;
    uint256 public ghostSkimmed;
    uint256 public t = 1_800_000_000;
    string public violation;

    constructor(MockUSDC u, NanoLedger l, address gov) {
        usdc = u; ledger = l; governor = gov;
        actors = [address(0xA1), address(0xB2), address(0xC3), address(this)]; // this = the pool source
    }

    function _flag(string memory what) internal {
        if (bytes(violation).length == 0) violation = what;
    }

    function _a(uint256 i) internal view returns (address) {
        return actors[i % 4];
    }

    function actorCount() external pure returns (uint256) { return 4; }

    // ---- ERC20 boundary ----
    function deposit(uint256 who, uint256 to, uint256 amount) external {
        address a = _a(who);
        amount = bound(amount, 1, 1_000_000e6);
        usdc.mint(a, amount);
        vm.startPrank(a);
        usdc.approve(address(ledger), amount);
        ledger.depositTo(_a(to), amount);
        vm.stopPrank();
        ghostDeposits += amount;
    }

    function withdraw(uint256 who, uint256 amount) external {
        address a = _a(who);
        uint256 bal = ledger.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 u0 = usdc.balanceOf(a);
        vm.prank(a);
        ledger.withdraw(amount);
        if (usdc.balanceOf(a) - u0 != amount) _flag("withdraw paid the wrong USDC");
        if (ledger.balanceOf(a) != bal - amount) _flag("withdraw debited wrong");
        ghostWithdrawals += amount;
    }

    function overWithdraw(uint256 who, uint256 extra) external {
        address a = _a(who);
        uint256 bal = ledger.balanceOf(a);
        vm.prank(a);
        try ledger.withdraw(bal + bound(extra, 1, 1e12)) { _flag("withdrew more than the balance"); } catch {}
    }

    // ---- internal payments ----
    function transfer(uint256 who, uint256 to, uint256 amount) external {
        address a = _a(who);
        address b = _a(to);
        uint256 bal = ledger.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 total0 = ledger.balanceOf(a) + (a == b ? 0 : ledger.balanceOf(b));
        vm.prank(a);
        ledger.internalTransfer(b, amount);
        uint256 total1 = ledger.balanceOf(a) + (a == b ? 0 : ledger.balanceOf(b));
        if (total0 != total1) _flag("transfer created or destroyed value");
    }

    function batchPay(uint256 who, uint256 x, uint256 y) external {
        address a = _a(who);
        uint256 bal = ledger.balanceOf(a);
        if (bal < 2) return;
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        to[0] = _a(x); to[1] = _a(y);
        amt[0] = bound(x, 1, bal / 2); amt[1] = bound(y, 1, bal / 2);
        uint256 sum0 = _sumBalances();
        vm.prank(a);
        ledger.batchPay(to, amt);
        if (_sumBalances() != sum0) _flag("batchPay created or destroyed value");
    }

    function approve(uint256 owner, uint256 spender, uint256 amount) external {
        vm.prank(_a(owner));
        ledger.approveSpender(_a(spender), bound(amount, 0, 2_000_000e6));
    }

    function transferFrom(uint256 spender, uint256 from, uint256 to, uint256 amount) external {
        address s = _a(spender);
        address f = _a(from);
        uint256 allow = ledger.allowance(f, s);
        uint256 bal = ledger.balanceOf(f);
        amount = bound(amount, 1, 2_000_000e6);
        vm.prank(s);
        try ledger.transferFromInternal(f, _a(to), amount) {
            if (allow != type(uint256).max && amount > allow) _flag("spent more than the allowance");
            if (amount > bal) _flag("moved more than the owner's balance");
            if (allow != type(uint256).max && ledger.allowance(f, s) != allow - amount) _flag("allowance not reduced");
        } catch {}
    }

    // ---- streams ----
    uint256[] public openIds;

    function openStream(uint256 who, uint256 to, uint256 rate, uint256 cap) external {
        address a = _a(who);
        uint256 bal = ledger.balanceOf(a);
        if (bal == 0) return;
        cap = bound(cap, 1, bal);
        rate = bound(rate, 1, type(uint128).max); // huge rates must not brick settle/cancel
        vm.prank(a);
        openIds.push(ledger.openStream(_a(to), rate, cap));
    }

    function settle(uint256 i) external {
        if (openIds.length == 0) return;
        uint256 id = openIds[i % openIds.length];
        (,,, uint256 cap, uint256 settled0,, bool closed0) = ledger.streams(id);
        uint256 got = ledger.settleStream(id);
        (,,,, uint256 settled1,, bool closed1) = ledger.streams(id);
        if (closed0 && got != 0) _flag("a closed stream paid again");
        if (settled1 > cap) _flag("stream settled beyond its cap");
        if (!closed0 && settled1 != settled0 + got) _flag("stream settle bookkeeping");
        if (closed0 && !closed1) _flag("stream reopened");
    }

    function cancel(uint256 i) external {
        if (openIds.length == 0) return;
        uint256 id = openIds[i % openIds.length];
        (address from,,,,,, bool closed) = ledger.streams(id);
        if (closed) return;
        vm.prank(from);
        ledger.cancelStream(id);
        (,,,,,, bool closed1) = ledger.streams(id);
        if (!closed1) _flag("cancel left the stream open");
    }

    function cancelByStranger(uint256 i, uint256 who) external {
        if (openIds.length == 0) return;
        uint256 id = openIds[i % openIds.length];
        (address from,,,,,, bool closed) = ledger.streams(id);
        address s = _a(who);
        if (closed || s == from) return;
        vm.prank(s);
        try ledger.cancelStream(id) { _flag("a stranger cancelled a stream"); } catch {}
    }

    function warp(uint256 secs) external {
        t = block.timestamp + bound(secs, 0, 30 days);
        vm.warp(t);
    }

    // ---- pools (this handler is the registered source) ----
    function createPool(uint256 p) external {
        p %= 3;
        if (poolMade[p]) return;
        ledger.createPool(poolIds[p]);
        poolMade[p] = true;
    }

    function setShares(uint256 p, uint256 payee, uint256 shares) external {
        p %= 3;
        if (!poolMade[p]) return;
        address who = _a(payee);
        uint256 b0 = ledger.balanceOf(who);
        ledger.setShares(poolIds[p], who, bound(shares, 0, 1e24));
        ghostPoolCredited += ledger.balanceOf(who) - b0; // settling pending credit
    }

    function accrue(uint256 p, uint256 amount) external {
        p %= 3;
        if (!poolMade[p]) return;
        (, uint256 ts,) = ledger.pools(poolIds[p]);
        uint256 bal = ledger.balanceOf(address(this));
        if (ts == 0 || bal == 0) return;
        amount = bound(amount, 1, bal);
        ledger.accrue(poolIds[p], amount);
        ghostAccrued += amount;
        if (ledger.balanceOf(address(this)) != bal - amount) _flag("accrue did not debit the source");
    }

    function claim(uint256 who, uint256 p) external {
        p %= 3;
        if (!poolMade[p]) return;
        address a = _a(who);
        uint256 expect = ledger.claimablePool(poolIds[p], a);
        uint256 b0 = ledger.balanceOf(a);
        vm.prank(a);
        uint256 got = ledger.claim(poolIds[p]);
        if (got != expect || ledger.balanceOf(a) - b0 != got) _flag("claim paid other than claimable");
        ghostPoolCredited += got;
        vm.prank(a);
        if (ledger.claim(poolIds[p]) != 0) _flag("double claim paid");
    }

    function strangerPoolOps(uint256 p, uint256 who) external {
        p %= 3;
        if (!poolMade[p]) return;
        address s = _a(who);
        if (s == address(this)) return;
        vm.startPrank(s);
        try ledger.accrue(poolIds[p], 1) { _flag("a stranger accrued"); } catch {}
        try ledger.setShares(poolIds[p], s, 1e24) { _flag("a stranger set shares"); } catch {}
        try ledger.createPool(bytes32("x")) { _flag("a stranger created a pool"); } catch {}
        vm.stopPrank();
    }

    // ---- donations and the governor ----
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000e6);
        usdc.mint(address(ledger), amount);
        ghostDonations += amount;
    }

    function skim() external {
        uint256 owed = ledger.totalOwed();
        uint256 held = usdc.balanceOf(address(ledger));
        vm.prank(governor);
        try ledger.skimSurplus(address(0x5111)) returns (uint256 s) {
            ghostSkimmed += s;
            if (usdc.balanceOf(address(ledger)) != owed) _flag("skim took other than exactly the surplus");
            if (s != held - owed) _flag("skim amount wrong");
        } catch {
            if (held > owed) _flag("skim refused a real surplus");
        }
    }

    function strangerGovernance(uint256 who) external {
        address s = _a(who);
        if (s == address(this)) return; // (the source is not a governor either, but it's our pool driver)
        vm.startPrank(s);
        try ledger.skimSurplus(s) { _flag("a stranger skimmed"); } catch {}
        try ledger.setSource(s, true) { _flag("a stranger registered a source"); } catch {}
        vm.stopPrank();
    }

    // ---- views for the invariants ----
    function _sumBalances() internal view returns (uint256 s) {
        for (uint256 i; i < 4; i++) s += ledger.balanceOf(actors[i]);
    }

    function sumBalances() external view returns (uint256) { return _sumBalances(); }

    function sumStreamReserved() external view returns (uint256 s) {
        uint256 n = ledger.streamCount();
        for (uint256 id; id < n; id++) {
            (,,, uint256 cap, uint256 settled,, bool closed) = ledger.streams(id);
            if (!closed) s += cap - settled;
        }
    }

    function openCount() external view returns (uint256) { return openIds.length; }
    function poolMadeAt(uint256 p) external view returns (bool) { return poolMade[p]; }
    function poolIdAt(uint256 p) external view returns (bytes32) { return poolIds[p]; }
}

contract NanoLedgerAuditTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    LedgerHandler h;
    address governor = makeAddr("governor");

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(IERC20(address(usdc)), governor);
        h = new LedgerHandler(usdc, ledger, governor);
        vm.prank(governor);
        ledger.setSource(address(h), true);
        vm.warp(1_800_000_000);
        targetContract(address(h));
    }

    function invariant_noViolationRecordedByTheHandler() public view {
        assertEq(h.violation(), "");
    }

    function invariant_solvency() public view {
        assertGe(usdc.balanceOf(address(ledger)), ledger.totalOwed());
    }

    /// totalOwed moves only on deposit and withdraw.
    function invariant_totalOwedIsDepositsMinusWithdrawals() public view {
        assertEq(ledger.totalOwed(), h.ghostDeposits() - h.ghostWithdrawals());
    }

    /// Exact conservation: every owed unit is a free balance, an open-stream reserve, or
    /// accrued-but-not-yet-credited pool money (claimable + dust).
    function invariant_exactConservation() public view {
        assertEq(ledger.totalOwed(), h.sumBalances() + h.sumStreamReserved() + (h.ghostAccrued() - h.ghostPoolCredited()));
    }

    /// The ledger holds exactly what it owes, plus donations not yet skimmed.
    function invariant_heldIsOwedPlusUnskimmedDonations() public view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed() + h.ghostDonations() - h.ghostSkimmed());
    }

    /// Liveness: at any moment everyone can get everything out. Cancel every open stream,
    /// claim every pool for everyone, withdraw every balance: all succeed, all are paid, and
    /// what remains owed is only pool rounding dust.
    function invariant_everyoneCanExitInFull() public {
        uint256 snap = vm.snapshotState();
        uint256 n = ledger.streamCount();
        for (uint256 id; id < n; id++) {
            (address from,,,,,, bool closed) = ledger.streams(id);
            if (!closed) {
                vm.prank(from);
                ledger.cancelStream(id);
            }
        }
        for (uint256 p; p < 3; p++) {
            if (!h.poolMadeAt(p)) continue;
            for (uint256 i; i < 4; i++) {
                vm.prank(h.actors(i));
                ledger.claim(h.poolIdAt(p));
            }
        }
        uint256 dustBefore = ledger.totalOwed() - h.sumBalances();
        for (uint256 i; i < 4; i++) {
            address a = h.actors(i);
            uint256 bal = ledger.balanceOf(a);
            if (bal == 0) continue;
            uint256 u0 = usdc.balanceOf(a);
            vm.prank(a);
            ledger.withdraw(bal);
            assertEq(usdc.balanceOf(a) - u0, bal, "exit paid in full");
        }
        assertEq(h.sumBalances(), 0);
        assertEq(ledger.totalOwed(), dustBefore, "only pool dust stays owed");
        // Dust is bounded: at most one unit per share-holder per accrual, never more than accrued.
        assertLe(dustBefore, h.ghostAccrued());
        vm.revertToState(snap);
    }
}
