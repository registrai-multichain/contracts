// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";

/// Drives randomized deposit/withdraw/transfer/stream/accrue/claim sequences and
/// asserts solvency + no-over-credit hold across all of them.
contract Handler is Test {
    NanoLedger public ledger;
    MockUSDC public usdc;
    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];
    bytes32 public constant PID = keccak256("fuzz-pool");
    uint256[] public streamIds;
    bool public poolReady;

    constructor(NanoLedger l, MockUSDC u) {
        ledger = l; usdc = u;
        for (uint256 i; i < 3; i++) {
            usdc.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            usdc.approve(address(l), type(uint256).max);
        }
        usdc.mint(address(this), 1e30);
        usdc.approve(address(l), type(uint256).max);
    }

    // called by the test after it registers this handler as a source
    function initPool() external {
        ledger.createPool(PID);
        ledger.setShares(PID, actors[0], 40);
        ledger.setShares(PID, actors[1], 20);
        ledger.setShares(PID, actors[2], 10);
        poolReady = true;
    }

    function _actor(uint256 s) internal view returns (address) { return actors[s % 3]; }
    function streamLen() external view returns (uint256) { return streamIds.length; }

    function deposit(uint256 a, uint256 amt) external {
        address x = _actor(a);
        amt = bound(amt, 1, 1e24);
        vm.prank(x);
        ledger.deposit(amt);
    }

    function withdraw(uint256 a, uint256 amt) external {
        address x = _actor(a);
        uint256 b = ledger.balanceOf(x);
        if (b == 0) return;
        amt = bound(amt, 1, b);
        vm.prank(x);
        ledger.withdraw(amt);
    }

    function transfer(uint256 a, uint256 b, uint256 amt) external {
        address x = _actor(a);
        uint256 bal = ledger.balanceOf(x);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(x);
        ledger.internalTransfer(_actor(b), amt);
    }

    function openStream(uint256 a, uint256 b, uint256 rate, uint256 cap) external {
        address x = _actor(a);
        uint256 bal = ledger.balanceOf(x);
        if (bal == 0) return;
        cap = bound(cap, 1, bal);
        rate = bound(rate, 1, type(uint256).max); // exercise extreme rates (overflow guard)
        vm.prank(x);
        streamIds.push(ledger.openStream(_actor(b), rate, cap));
    }

    function settle(uint256 i) external {
        if (streamIds.length == 0) return;
        ledger.settleStream(streamIds[i % streamIds.length]);
    }

    function cancel(uint256 i) external {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[i % streamIds.length];
        (address from,,,,,,) = ledger.streams(id);
        vm.prank(from);
        try ledger.cancelStream(id) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 1e6));
    }

    function accrue(uint256 amt) external {
        if (!poolReady) return;
        amt = bound(amt, 1, 1e18);
        uint256 b = ledger.balanceOf(address(this));
        if (b < amt) ledger.deposit(amt - b); // source tops itself up
        ledger.accrue(PID, amt);
    }

    function claimPool(uint256 a) external {
        vm.prank(_actor(a));
        try ledger.claim(PID) {} catch {}
    }
}

contract NanoLedgerInvariantTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    Handler handler;

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        handler = new Handler(ledger, usdc);
        ledger.setSource(address(handler), true);
        handler.initPool();
        targetContract(address(handler));
    }

    /// The USDC physically held equals what the ledger says it owes. (The handler
    /// never donates, so this is exact.)
    function invariant_solvency() public view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "USDC != totalOwed");
    }

    /// Every reconstructable internal claim (free balances + open-stream reserves
    /// + lazily-claimable pool shares) never exceeds totalOwed. Stranded accrual
    /// dust makes this <=, never >.
    function invariant_noOverCredit() public view {
        uint256 sum;
        sum += ledger.balanceOf(address(handler));
        for (uint256 i; i < 3; i++) {
            address a = handler.actors(i);
            sum += ledger.balanceOf(a);
            sum += ledger.claimablePool(handler.PID(), a);
        }
        uint256 n = handler.streamLen();
        for (uint256 i; i < n; i++) {
            (, , , uint256 cap, uint256 settled, , bool closed) = ledger.streams(handler.streamIds(i));
            if (!closed) sum += cap - settled; // reserve still held by the ledger
        }
        assertLe(sum, ledger.totalOwed(), "internal claims exceed owed");
    }
}
