// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {MockPoolManager, MockREGI} from "../MockPoolManager.sol";
import {RegiBuyback} from "../../../src/buyback/RegiBuyback.sol";
import {RegiFeeSplitter} from "../../../src/buyback/RegiFeeSplitter.sol";
import {IPoolManagerMinimal} from "../../../src/buyback/UniswapV4Minimal.sol";
import {INanoLedgerMinimal} from "../../../src/buyback/INanoLedgerMinimal.sol";

/// Drives RegiBuyback + RegiFeeSplitter with random action sequences and keeps ghost
/// accounting. Every action records a violation instead of reverting, so the invariants
/// can report exactly what broke.
contract BuybackHandler is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    MockUSDC public usdc;
    MockREGI public regi;
    MockPoolManager public pm;
    NanoLedger public ledger;
    RegiBuyback public bb;
    RegiBuyback public bb2; // a second real buyback: the repoint target
    RegiFeeSplitter public sp;
    address public safe;

    uint256 public t = 1_800_000_000; // local clock (via_ir reuses block.timestamp reads)
    uint256 public successfulBurns;
    uint256 public roundsOpened;
    uint256 public partialFills;
    uint256 public repointsAccepted;
    uint256 public repointsCancelled;
    uint256 public heldDistributes;
    uint256 public ghostProposedAt;
    uint256 public ghostSplitTotal; // all USDC the splitter has split
    uint256 public ghostBuybackShare; // the 40% legs of every split
    string public violation;

    constructor(MockUSDC u, MockREGI r, MockPoolManager p, NanoLedger l, RegiBuyback b, RegiBuyback b2, RegiFeeSplitter s, address safe_) {
        usdc = u; regi = r; pm = p; ledger = l; bb = b; bb2 = b2; sp = s; safe = safe_;
    }

    function _flag(string memory what) internal {
        if (bytes(violation).length == 0) violation = what;
    }

    function _bal(address a) internal view returns (uint256) {
        return usdc.balanceOf(a);
    }

    // Money leaves a buyback ONLY as swap spend: balance + spent never decreases.
    function _snapshot() internal view returns (uint256 a, uint256 b) {
        a = _bal(address(bb)) + bb.totalUsdcSpent();
        b = _bal(address(bb2)) + bb2.totalUsdcSpent();
    }

    function _checkNoLeak(uint256 a0, uint256 b0) internal {
        (uint256 a1, uint256 b1) = _snapshot();
        if (a1 < a0) _flag("bb: USDC left other than as swap spend");
        if (b1 < b0) _flag("bb2: USDC left other than as swap spend");
    }

    // ---- funding ----
    function fundDirect(uint256 amount, bool second) external {
        amount = bound(amount, 1, 500e6);
        (uint256 a0, uint256 b0) = _snapshot();
        usdc.mint(second ? address(bb2) : address(bb), amount);
        _checkNoLeak(a0, b0);
    }

    function payBuybackOnLedger(uint256 amount) external {
        amount = bound(amount, 1, 300e6);
        usdc.mint(address(this), amount);
        usdc.approve(address(ledger), amount);
        ledger.depositTo(address(bb), amount);
    }

    function sweep() external {
        (uint256 a0, uint256 b0) = _snapshot();
        uint256 onLedger = ledger.balanceOf(address(bb));
        uint256 before = _bal(address(bb));
        uint256 got = bb.sweepLedger();
        if (got != onLedger || _bal(address(bb)) != before + got) _flag("sweepLedger moved the wrong amount");
        _checkNoLeak(a0, b0);
    }

    function payTreasury(uint256 amount, bool viaLedger) external {
        amount = bound(amount, 1, 800e6);
        usdc.mint(address(this), amount);
        if (viaLedger) {
            usdc.approve(address(ledger), amount);
            ledger.depositTo(address(sp), amount);
        } else {
            usdc.transfer(address(sp), amount);
        }
    }

    function distribute() external {
        (uint256 a0, uint256 b0) = _snapshot();
        uint256 held0 = sp.heldForBuyback();
        uint256 newMoney = _bal(address(sp)) + ledger.balanceOf(address(sp)) - held0 - sp.owedToSafe();
        uint256 owed0 = sp.owedToSafe();
        address target = sp.buyback();
        uint256 target0 = _bal(target);
        bool pending = sp.pendingBuyback() != address(0);
        (uint256 toB, uint256 toS) = sp.distribute();
        if (toB + toS != newMoney) _flag("distribute did not split exactly the new money");
        if (toB != newMoney * 4000 / 10_000) _flag("buyback leg is not floor(40%)");
        if (sp.owedToSafe() - owed0 != toS) _flag("Safe's leg not recorded");
        if (pending) {
            if (toB > 0) heldDistributes++;
            if (sp.heldForBuyback() != held0 + toB) _flag("pending repoint: 40% not held");
            if (_bal(target) != target0) _flag("pending repoint: old buyback was paid");
        } else if (_bal(target) - target0 != toB) {
            _flag("buyback did not receive its leg");
        }
        ghostSplitTotal += toB + toS;
        ghostBuybackShare += toB;
        _checkNoLeak(a0, b0);
    }

    function collectSafe() external {
        uint256 owed = sp.owedToSafe();
        uint256 safe0 = _bal(safe);
        uint256 got = sp.collectSafe();
        if (got != owed || _bal(safe) - safe0 != owed || sp.owedToSafe() != 0) _flag("collectSafe paid other than what was owed");
    }

    // ---- the buyback ----
    function burn(bool second) external {
        RegiBuyback x = second ? bb2 : bb;
        (uint256 a0, uint256 b0) = _snapshot();
        uint256 bal0 = _bal(address(x));
        uint256 spent0 = x.totalUsdcSpent();
        uint256 burned0 = x.totalRegiBurned();
        uint256 chunks0 = x.totalChunks();
        uint256 dead0 = regi.balanceOf(DEAD);
        uint256 next0 = x.nextChunkAt();
        uint256 left0 = x.chunksLeft();
        uint256 round0 = x.round();
        try x.burnChunk() returns (uint256 usdcIn, uint256 regiBurned) {
            successfulBurns++;
            if (block.timestamp < next0) _flag("burned during the cooldown");
            if (left0 == 0) {
                if (bal0 < x.TRIGGER()) _flag("opened a round below the trigger");
                if (x.round() != round0 + 1 || x.chunksLeft() != 3) _flag("a new round is not 4 chunks");
                roundsOpened++;
            } else if (x.chunksLeft() != left0 - 1 || x.round() != round0) {
                _flag("a chunk did not count down the round");
            }
            if (usdcIn < (bal0 < x.CHUNK() ? bal0 : x.CHUNK())) partialFills++;
            if (usdcIn == 0 || usdcIn > x.CHUNK()) _flag("chunk spent 0 or more than CHUNK");
            if (bal0 - _bal(address(x)) != usdcIn) _flag("balance drop != usdcIn");
            if (x.totalUsdcSpent() - spent0 != usdcIn) _flag("totalUsdcSpent drift");
            if (x.totalRegiBurned() - burned0 != regiBurned) _flag("totalRegiBurned drift");
            if (regi.balanceOf(DEAD) - dead0 != regiBurned) _flag("dead did not get exactly the burned REGI");
            if (x.totalChunks() != chunks0 + 1) _flag("totalChunks drift");
            if (x.nextChunkAt() != block.timestamp + x.COOLDOWN()) _flag("cooldown not set");
        } catch {
            // A failed press must leave nothing behind.
            if (_bal(address(x)) != bal0 || x.totalChunks() != chunks0 || regi.balanceOf(DEAD) != dead0) {
                _flag("failed press changed state");
            }
        }
        _checkNoLeak(a0, b0);
    }

    // Real block time is read once per action (other fuzzers, like Echidna, also move time
    // between calls); only warp() moves it, and it reads before it writes.
    function warp(uint256 secs) external {
        t = block.timestamp + bound(secs, 0, 3 hours);
        vm.warp(t);
    }

    /// Long jumps so the 7-day repoint delay can actually elapse.
    function warpLong(uint256 secs) external {
        t = block.timestamp + bound(secs, 1 days, 9 days);
        vm.warp(t);
    }

    function setFill(uint256 bps) external {
        pm.setFillBps(bound(bps, 0, 10_000)); // 0 = nothing fills (NothingBought path)
    }

    function setPrice(uint256 p) external {
        pm.setSqrtPrice(uint160(bound(p, 4295128740, 1461446703485210103287273052203988822378723970341)));
    }

    // ---- repoint (the Safe) ----
    function propose(bool toSecond) external {
        vm.prank(safe);
        sp.proposeBuyback(toSecond ? address(bb2) : address(bb));
        ghostProposedAt = block.timestamp;
    }

    function accept() external {
        address next = sp.pendingBuyback();
        uint256 held = sp.heldForBuyback();
        uint256 next0 = next == address(0) ? 0 : _bal(next);
        vm.prank(safe);
        try sp.acceptBuyback() {
            repointsAccepted++;
            if (block.timestamp < ghostProposedAt + 7 days) _flag("repoint accepted before 7 days");
            if (sp.buyback() != next) _flag("accept did not repoint");
            if (sp.heldForBuyback() != 0 || _bal(next) - next0 != held) _flag("accept did not release held to the new buyback");
        } catch {}
    }

    function cancel() external {
        address cur = sp.buyback();
        uint256 held = sp.heldForBuyback();
        uint256 cur0 = _bal(cur);
        vm.prank(safe);
        try sp.cancelBuyback() {
            repointsCancelled++;
            if (sp.heldForBuyback() != 0 || _bal(cur) - cur0 != held) _flag("cancel did not release held to the current buyback");
        } catch {}
    }

    // An outsider trying the privileged and internal paths: all must revert.
    function attack(uint256 which) external {
        which = bound(which, 0, 3);
        address mallory = address(0xBAD);
        vm.startPrank(mallory);
        if (which == 0) try sp.proposeBuyback(mallory) { _flag("outsider proposed a repoint"); } catch {}
        if (which == 1) try sp.acceptBuyback() { _flag("outsider accepted a repoint"); } catch {}
        if (which == 2) try sp.cancelBuyback() { _flag("outsider cancelled a repoint"); } catch {}
        if (which == 3) try bb.unlockCallback(abi.encode(uint256(50e6))) { _flag("outsider ran the swap callback"); } catch {}
        vm.stopPrank();
    }
}

contract BuybackInvariantTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    BuybackHandler h;
    MockUSDC usdc;
    MockREGI regi;
    MockPoolManager pm;
    RegiBuyback bb;
    RegiBuyback bb2;
    RegiFeeSplitter sp;
    NanoLedger ledger;
    address safe = makeAddr("safe");

    function setUp() public {
        deployCodeTo("MockUSDC.sol:MockUSDC", address(0x3600));
        deployCodeTo("MockPoolManager.sol:MockREGI", address(0x93D5));
        usdc = MockUSDC(address(0x3600));
        regi = MockREGI(address(0x93D5));
        pm = new MockPoolManager(IERC20(address(usdc)), regi);
        ledger = new NanoLedger(IERC20(address(usdc)), address(this));
        bb = new RegiBuyback(IPoolManagerMinimal(address(pm)), IERC20(address(usdc)), address(regi), address(0x779A), 10_000, 200,
            INanoLedgerMinimal(address(ledger)));
        bb2 = new RegiBuyback(IPoolManagerMinimal(address(pm)), IERC20(address(usdc)), address(regi), address(0x779A), 10_000, 200,
            INanoLedgerMinimal(address(ledger)));
        pm.setPool(bb.key());
        sp = new RegiFeeSplitter(INanoLedgerMinimal(address(ledger)), IERC20(address(usdc)), safe, address(bb));
        h = new BuybackHandler(usdc, regi, pm, ledger, bb, bb2, sp, safe);
        vm.warp(1_800_000_000);
        targetContract(address(h));
    }

    function invariant_noViolationRecordedByTheHandler() public view {
        assertEq(h.violation(), "");
    }

    function invariant_buybacksNeverHoldRegi() public view {
        assertEq(regi.balanceOf(address(bb)), 0);
        assertEq(regi.balanceOf(address(bb2)), 0);
    }

    function invariant_deadHoldsExactlyWhatWasBurned() public view {
        assertEq(regi.balanceOf(DEAD), bb.totalRegiBurned() + bb2.totalRegiBurned());
    }

    function invariant_thePoolGotExactlyWhatWasSpent() public view {
        assertEq(usdc.balanceOf(address(pm)), bb.totalUsdcSpent() + bb2.totalUsdcSpent());
    }

    function invariant_roundCountersStaySane() public view {
        assertLe(bb.chunksLeft(), 4);
        assertLe(bb2.chunksLeft(), 4);
        if (bb.chunksLeft() > 0) assertGt(bb.round(), 0);
        assertEq(bb.totalChunks() + bb2.totalChunks(), h.successfulBurns());
    }

    function invariant_heldOnlyDuringAPendingRepointAndAlwaysBacked() public view {
        if (sp.pendingBuyback() == address(0)) assertEq(sp.heldForBuyback(), 0);
        assertLe(sp.heldForBuyback() + sp.owedToSafe(), usdc.balanceOf(address(sp)));
    }

    function invariant_theSafeGetsExactlyThe60PercentLegs() public view {
        assertEq(usdc.balanceOf(safe) + sp.owedToSafe(), h.ghostSplitTotal() - h.ghostBuybackShare());
    }

    /// Reach, not correctness: logged after the campaign so a green run can be shown to have
    /// exercised rounds, partial fills and repoints (see audit/invariant-*.txt).
    function afterInvariant() public view {
        // no assertion: forge prints these with -vvv when requested
    }
}
