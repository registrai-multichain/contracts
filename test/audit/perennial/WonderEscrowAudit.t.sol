// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../../src/perennial/SeasonPool.sol";
import {VerifiedBuilderBadge} from "../../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../../src/perennial/WonderEscrow.sol";
import {FundKit} from "../../perennial/FundKit.sol";
import {MarketsKit} from "../../perennial/MarketsKit.sol";

/// Audit 2026-09-27 (wonder markets): PoCs against WonderEscrow.
contract WonderEscrowAuditTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    BuilderFund fund;
    SeasonPool pool;
    VerifiedBuilderBadge badge;
    WonderEscrow escrow;

    address markets = address(0x3A2);
    address operator = address(0x0FE2);
    address safe = address(this); // GOVERNOR / DEFAULT_ADMIN
    address team = address(0x7EA3);
    address anyone = address(0xA11CE);
    string constant SRC = "github:acme/tool";
    bytes32 KEY = keccak256(bytes(SRC));
    uint256 T0;

    function setUp() public {
        vm.warp(1_000_000);
        T0 = block.timestamp;
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        badge = MarketsKit.deployBadge(builders);
        escrow = new WonderEscrow(ledger, fund, badge, address(this), 180 days);
        escrow.grantRole(escrow.MARKETS_ROLE(), markets);
        escrow.grantRole(escrow.RELEASER_ROLE(), operator);
        FundKit.wireEscrow(fund, address(escrow));
        usdc.mint(markets, 1_000_000e6);
        vm.startPrank(markets);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000_000e6);
        ledger.internalTransfer(address(escrow), 100e6);
        escrow.credit(KEY, 100e6);
        vm.stopPrank();
        // the Safe's own USDC, for top-ups
        usdc.mint(safe, 1_000e6);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000e6);
    }

    /// FIXED (M-1, M-1b, L-2a, L-2b, TRUST "Safe drains escrow instantly"): the
    /// yield vault is gone (owner, 2026-09-27). Escrow sits in the ledger account
    /// and leaves only by a release or a sweep: no role, the Safe included, can
    /// point it anywhere else, and nothing can be harvested.
    function test_FIXED_noVault_safeCannotMoveEscrow() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("setVault(address)", address(0xBAD)),
            abi.encodeWithSignature("setCap(uint256)", type(uint256).max),
            abi.encodeWithSignature("deploy(uint256)", uint256(100e6)),
            abi.encodeWithSignature("recall(uint256)", uint256(1)),
            abi.encodeWithSignature("recallAll()"),
            abi.encodeWithSignature("harvest()")
        ];
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = address(escrow).call(calls[i]); // as the Safe (every admin role)
            assertFalse(ok);
        }
        assertEq(ledger.balanceOf(address(escrow)), 100e6);
        assertEq(escrow.totalEscrow(), 100e6);
    }

    /// FIXED L-1: a cancel no longer opens a sweep window. For RELEASE_DELAY after
    /// a cancel nobody can sweep, so the operator re-queues the team (here to its
    /// new project id) and the team is paid in full.
    function test_FIXED_L1_cancelAfterExpiry_teamStillPaid() public {
        (uint256 teamId, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.warp(T0 + 170 days);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId); // legit claim, before expiry
        vm.prank(team);
        builders.removeProject(projectId);
        uint256 newProject = builders.addProjectFor(teamId, SRC);
        vm.warp(T0 + 181 days);
        vm.expectRevert(WonderEscrow.ProjectMismatch.selector);
        escrow.executeRelease(KEY);
        vm.prank(operator);
        escrow.cancelRelease(KEY); // to re-queue for newProject
        vm.prank(anyone);
        vm.expectRevert(WonderEscrow.SweepBlocked.selector);
        escrow.sweep(KEY); // the back-run fails
        vm.prank(operator);
        escrow.queueRelease(SRC, newProject);
        vm.warp(T0 + 188 days);
        escrow.executeRelease(KEY);
        assertEq(fund.incomeOf(0, teamId), 100e6, "the team gets its escrow, in the epoch it was earned");
        assertEq(escrow.escrowOf(KEY), 0);
    }

    /// INFO: after a release every later credit is forwarded to that builder with
    /// no delay and no re-check, even after the builder removed the project and
    /// its badge lapsed; only the Safe's unrelease stops it.
    function test_Info_postReleaseCreditsIgnoreProjectAndBadge() public {
        (uint256 teamId, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.warp(T0 + 7 days);
        escrow.executeRelease(KEY);
        vm.prank(team);
        builders.removeProject(projectId);
        badge.setLapsed(teamId, true);
        uint256 e = fund.currentEpoch();
        uint256 before = fund.incomeOf(e, teamId);
        vm.startPrank(markets);
        ledger.internalTransfer(address(escrow), 7e6);
        escrow.credit(KEY, 7e6);
        vm.stopPrank();
        assertEq(fund.incomeOf(e, teamId) - before, 7e6);
        // and the lapsed-badge (still active) builder can claim it
        vm.warp(fund.epochEnd(e));
        assertGt(fund.claimFor(e, teamId), 0);
    }

    /// TRUST: a compromised operator (RELEASER) can re-queue a squatter right after
    /// every Safe cancel; each cancel only buys 7 days. The Safe must revoke the role.
    function test_Trust_operatorRequeuesSquatterAfterCancel() public {
        (uint256 squatId,) = MarketsKit.onboard(builders, badge, address(0x5A7), "github:squat/own");
        uint256 squatProject = builders.addProjectFor(squatId, SRC); // any verified builder may add any source
        vm.prank(operator);
        escrow.queueRelease(SRC, squatProject);
        escrow.cancelRelease(KEY);
        vm.prank(operator);
        escrow.queueRelease(SRC, squatProject); // immediately again
        (uint256 b,,) = escrow.pendingRelease(KEY);
        assertEq(b, squatId);
    }

    /// Verified: no double release, released keys never hold escrow, unrelease
    /// lets later credits wait again and a re-queue pays only those.
    function test_noDoubleReleaseAcrossUnrelease() public {
        (uint256 teamId, uint256 projectId) = MarketsKit.onboard(builders, badge, team, SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.warp(T0 + 7 days);
        escrow.executeRelease(KEY);
        vm.expectRevert(WonderEscrow.NotReady.selector);
        escrow.executeRelease(KEY);
        vm.prank(operator);
        vm.expectRevert(WonderEscrow.AlreadyReleased.selector);
        escrow.queueRelease(SRC, projectId);
        escrow.unrelease(KEY);
        vm.startPrank(markets);
        ledger.internalTransfer(address(escrow), 3e6);
        escrow.credit(KEY, 3e6);
        vm.stopPrank();
        assertEq(escrow.escrowOf(KEY), 3e6);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.warp(T0 + 14 days);
        escrow.executeRelease(KEY);
        // total income across epochs: 100 + 3
        uint256 sum;
        for (uint256 e; e <= fund.currentEpoch(); ++e) {
            sum += fund.incomeOf(e, teamId);
        }
        assertEq(sum, 103e6);
        assertEq(escrow.totalEscrow(), 0);
    }
}
