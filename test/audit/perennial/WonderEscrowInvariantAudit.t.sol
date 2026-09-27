// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../../src/perennial/BuilderFund.sol";
import {VerifiedBuilderBadge} from "../../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../../src/perennial/WonderEscrow.sol";
import {FundKit} from "../../perennial/FundKit.sol";
import {MarketsKit} from "../../perennial/MarketsKit.sol";

/// Audit handler: every escrow role at once (markets, releaser, Safe), plus
/// donations, squatters, unrelease, cancels, project removal and badge lapses.
/// No yield vault (removed 2026-09-27): the accounting is exact.
contract WonderAuditHandler is Test {
    NanoLedger ledger;
    MockUSDC usdc;
    WonderEscrow escrow;
    BuilderRegistry builders;
    VerifiedBuilderBadge badge;
    BuilderFund fund;

    bytes32[3] keys;
    string[3] sources = ["github:a/one", "github:b/two", "domain:c.dev"];
    address squatter = address(0x5A70);
    mapping(address => mapping(uint256 => uint256)) public projectOf; // owner => k => projectId

    uint256 public credited;
    uint256 public forwarded;
    uint256 public released;
    uint256 public swept;
    uint256 public topUps;
    uint256 public creditFailures;
    uint256 public sweptWhilePending;
    uint256 public badRelease;
    uint256 public calls;
    uint256 public execAttempts;
    uint256 public execOk;
    uint256 public queued;
    uint256 public sweptWhileBlocked;

    constructor(NanoLedger l, MockUSDC u, WonderEscrow e, BuilderRegistry b, VerifiedBuilderBadge bd, BuilderFund f) {
        (ledger, usdc, escrow, builders, badge, fund) = (l, u, e, b, bd, f);
        for (uint256 i; i < 3; ++i) keys[i] = keccak256(bytes(sources[i]));
    }

    function keyAt(uint256 i) external view returns (bytes32) {
        return keys[i];
    }

    // ── markets ──
    function credit(uint256 k, uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 500e6);
        bytes32 key = keys[k % 3];
        bool isReleased = escrow.releasedTo(key) != 0;
        ledger.internalTransfer(address(escrow), amount);
        try escrow.credit(key, amount) {
            if (isReleased) forwarded += amount;
            else credited += amount;
        } catch {
            creditFailures++;
        }
    }

    // ── the world ──
    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1 hours, 40 days));
    }

    // ── the Safe ──
    function topUp(uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 200e6);
        ledger.internalTransfer(address(escrow), amount);
        topUps += amount;
    }

    function cancel(uint256 k) external {
        calls++;
        if (k % 4 != 0) return; // rarer than claims
        try escrow.cancelRelease(keys[k % 3]) {} catch {}
    }

    function unrelease(uint256 k) external {
        calls++;
        try escrow.unrelease(keys[k % 3]) {} catch {}
    }

    // ── builders ──
    function claim(uint256 k, bool bySquatter) external {
        calls++;
        k %= 3;
        if (escrow.escrowOf(keys[k]) == 0) return; // the keeper queues only with escrow waiting
        address owner = bySquatter ? squatter : address(uint160(0x7000 + k));
        uint256 id = builders.builderIdOf(owner);
        if (id == 0) id = builders.registerFor(owner, "");
        uint256 pid = projectOf[owner][k];
        if (pid == 0) {
            try builders.addProjectFor(id, sources[k]) returns (uint256 p) {
                pid = p;
                projectOf[owner][k] = p;
            } catch {
                return;
            }
        }
        if (badge.serialOf(id) == 0) {
            try badge.issue(id) {} catch {}
        }
        try escrow.queueRelease(sources[k], pid) {
            queued++;
        } catch {}
    }

    function toggleProject(uint256 k, bool bySquatter, bool active) external {
        calls++;
        k %= 3;
        address owner = bySquatter ? squatter : address(uint160(0x7000 + k));
        uint256 pid = projectOf[owner][k];
        if (pid == 0) return;
        builders.setProjectActive(pid, active);
    }

    function lapse(uint256 k, bool bySquatter, bool isLapsed) external {
        calls++;
        address owner = bySquatter ? squatter : address(uint160(0x7000 + (k % 3)));
        uint256 id = builders.builderIdOf(owner);
        if (id == 0 || badge.serialOf(id) == 0) return;
        badge.setLapsed(id, isLapsed);
    }

    function execute(uint256 k) external {
        calls++;
        bytes32 key = keys[k % 3];
        (uint256 bId, uint256 pid, uint64 ready) = escrow.pendingRelease(key);
        if (ready == 0) return;
        if (block.timestamp < ready) vm.warp(ready); // coverage: releases do happen
        uint256 before = escrow.escrowOf(key);
        execAttempts++;
        try escrow.executeRelease(key) {
            execOk++;
            released += before;
            // independent check of the destination
            (uint256 pb, string memory src, bool active,) = builders.projects(pid);
            uint256 serial = badge.serialOf(pb);
            if (
                pb != bId || !active || keccak256(bytes(src)) != key || !builders.isActiveBuilderId(pb) || serial == 0
                    || badge.isLapsed(serial) || escrow.releasedTo(key) != bId
            ) badRelease++;
        } catch {}
    }

    function sweep(uint256 k, bool jump) external {
        calls++;
        bytes32 key = keys[k % 3];
        uint64 first = escrow.firstCreditAt(key);
        if (jump && first != 0 && block.timestamp < first + escrow.EXPIRY()) vm.warp(first + escrow.EXPIRY());
        (,, uint64 ready) = escrow.pendingRelease(key);
        uint256 before = escrow.escrowOf(key);
        bool blocked = block.timestamp < escrow.sweepBlockedUntil(key);
        try escrow.sweep(key) {
            if (ready != 0) sweptWhilePending++;
            if (blocked) sweptWhileBlocked++;
            swept += before;
        } catch {}
    }
}

contract WonderEscrowInvariantAudit is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    WonderEscrow escrow;
    BuilderFund fund;
    WonderAuditHandler handler;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        BuilderRegistry builders = new BuilderRegistry(address(this));
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, address(this));
        (, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 7 days);
        VerifiedBuilderBadge badge = MarketsKit.deployBadge(builders);
        escrow = new WonderEscrow(ledger, fund, badge, address(this), 90 days);
        FundKit.wireEscrow(fund, address(escrow));
        handler = new WonderAuditHandler(ledger, usdc, escrow, builders, badge, fund);
        builders.grantRole(builders.REGISTRAR_ROLE(), address(handler));
        badge.grantRole(badge.ISSUER_ROLE(), address(handler));
        badge.grantRole(badge.STATUS_ROLE(), address(handler));
        escrow.grantRole(escrow.RELEASER_ROLE(), address(handler));
        escrow.grantRole(escrow.MARKETS_ROLE(), address(handler));
        escrow.grantRole(escrow.GOVERNOR_ROLE(), address(handler));
        usdc.mint(address(handler), 100_000_000e6);
        vm.startPrank(address(handler));
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000_000e6);
        vm.stopPrank();
        targetContract(address(handler));
    }

    /// Escrow in == escrow owed + escrow out (release / sweep); exact.
    function invariant_accounting() public view {
        assertEq(handler.credited(), escrow.totalEscrow() + handler.swept() + handler.released());
    }

    function invariant_totalIsTheSum() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) sum += escrow.escrowOf(handler.keyAt(i));
        assertEq(sum, escrow.totalEscrow());
    }

    /// The ledger account always covers what is owed (donations only add).
    function invariant_solvent() public view {
        assertGe(ledger.balanceOf(address(escrow)), escrow.totalEscrow());
    }

    /// Per-epoch buckets: they add up to the source's escrow, never exceed
    /// MAX_BUCKETS, are in increasing epoch order and never in the future.
    function invariant_bucketsAddUp() public view {
        uint256 current = fund.currentEpoch();
        for (uint256 i; i < 3; ++i) {
            bytes32 key = handler.keyAt(i);
            uint256 n = escrow.bucketCount(key);
            assertLe(n, escrow.MAX_BUCKETS());
            uint256 sum;
            uint64 last;
            for (uint256 j; j < n; ++j) {
                (uint64 e, uint192 a) = escrow.bucketAt(key, j);
                if (j > 0) assertGt(e, last, "buckets out of order");
                assertLe(e, current, "bucket in the future");
                last = e;
                sum += a;
            }
            assertEq(sum, escrow.escrowOf(key));
        }
    }

    /// Everything that left the escrow toward builders is in the fund's books.
    function invariant_fundGotReleasesAndForwards() public view {
        assertEq(fund.outstanding(), handler.released() + handler.forwarded());
        assertGe(ledger.balanceOf(address(fund)), fund.outstanding());
    }

    function invariant_perKeyConsistency() public view {
        for (uint256 i; i < 3; ++i) {
            bytes32 key = handler.keyAt(i);
            (,, uint64 ready) = escrow.pendingRelease(key);
            if (escrow.releasedTo(key) != 0) {
                assertEq(escrow.escrowOf(key), 0, "released key holds escrow");
                assertEq(escrow.bucketCount(key), 0, "released key holds buckets");
                assertEq(escrow.firstCreditAt(key), 0, "released key has a clock");
                assertEq(ready, 0, "released key has a pending release");
            }
            if (escrow.escrowOf(key) != 0) assertGt(escrow.firstCreditAt(key), 0, "escrow without a clock");
        }
    }

    function invariant_liveness_and_safety() public view {
        assertEq(handler.creditFailures(), 0, "credit (trading) reverted");
        assertEq(handler.sweptWhilePending(), 0, "swept while a release was queued");
        assertEq(handler.badRelease(), 0, "released to a builder that fails the checks");
        assertEq(handler.sweptWhileBlocked(), 0, "swept within RELEASE_DELAY of a cancel");
    }

    function afterInvariant() external view {
        // coverage of the money paths (printed with -vvv)
        console2.log("released", handler.released(), "swept", handler.swept());
        console2.log("forwarded", handler.forwarded(), "topUps", handler.topUps());
        console2.log("credited", handler.credited(), "owed", escrow.totalEscrow());
        console2.log("queued", handler.queued(), "exec ok/attempts", handler.execOk() * 1000 + handler.execAttempts());
        assertGt(handler.calls(), 0);
    }
}
