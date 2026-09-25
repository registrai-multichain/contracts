// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../src/perennial/WonderEscrow.sol";
import {FundKit} from "./FundKit.sol";
import {MarketsKit} from "./MarketsKit.sol";
import {MockVault, OffsetMockVault} from "./MockVault.sol";

contract WonderYieldTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    BuilderFund fund;
    SeasonPool pool;
    VerifiedBuilderBadge badge;
    WonderEscrow escrow;
    MockVault vault;

    address markets = address(0x3A2);
    address operator = address(0x0FE2);
    string constant SRC = "github:acme/tool";
    bytes32 KEY = keccak256(bytes(SRC));

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        badge = MarketsKit.deployBadge(builders);
        escrow = new WonderEscrow(ledger, fund, badge, address(this), 180 days);
        escrow.grantRole(escrow.MARKETS_ROLE(), markets);
        escrow.grantRole(escrow.RELEASER_ROLE(), operator);
        escrow.grantRole(escrow.YIELD_ROLE(), operator);
        escrow.grantRole(escrow.YIELD_ROLE(), address(this)); // the tests harvest as the keeper too
        FundKit.wire(fund, address(escrow));
        vault = new MockVault(usdc);
        escrow.setVault(IERC4626(address(vault)));
        escrow.setCap(1_000e6);
        escrow.setMinLiquid(10e6);
        usdc.mint(markets, 1_000_000e6);
        vm.startPrank(markets);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000_000e6);
        ledger.internalTransfer(address(escrow), 100e6);
        escrow.credit(KEY, 100e6);
        vm.stopPrank();
    }

    function test_deployRespectsCapAndMinLiquid() public {
        vm.startPrank(operator);
        vm.expectRevert(WonderEscrow.BelowMinLiquid.selector);
        escrow.deploy(95e6); // would leave 5 < 10 liquid
        escrow.deploy(90e6);
        vm.stopPrank();
        assertEq(escrow.deployedPrincipal(), 90e6);
        assertEq(ledger.balanceOf(address(escrow)), 10e6);
        assertEq(escrow.vaultAssets(), 90e6);
        escrow.setCap(50e6);
        vm.prank(operator);
        vm.expectRevert(WonderEscrow.OverCap.selector);
        escrow.deploy(1e6);
    }

    function test_deployOnlyYieldRole() public {
        vm.expectRevert();
        vm.prank(markets);
        escrow.deploy(1e6);
    }

    function test_harvestSendsYieldToSeasonPoolOnly() public {
        vm.prank(operator);
        escrow.deploy(90e6);
        vault.accrue(9e6); // 10% yield
        uint256 poolBefore = ledger.balanceOf(address(pool));
        uint256 got = escrow.harvest();
        assertApproxEqAbs(got, 9e6, 2);
        assertApproxEqAbs(ledger.balanceOf(address(pool)) - poolBefore, 9e6, 2);
        assertEq(escrow.totalEscrow(), 100e6);
        assertGe(ledger.balanceOf(address(escrow)) + escrow.vaultAssets() + 2, 100e6);
        assertFalse(escrow.yieldPaused());
    }

    function test_lossPausesDepositsAndKeepsEscrow() public {
        vm.prank(operator);
        escrow.deploy(90e6);
        vault.lose(30e6);
        assertEq(escrow.harvest(), 0);
        assertTrue(escrow.yieldPaused());
        assertEq(escrow.escrowOf(KEY), 100e6);
        vm.prank(operator);
        vm.expectRevert(WonderEscrow.YieldPausedError.selector);
        escrow.deploy(1e6);
    }

    function test_roundingDustDoesNotPause() public {
        vm.prank(operator);
        escrow.deploy(90e6);
        vault.lose(1); // one wei of rounding
        assertEq(escrow.harvest(), 0);
        assertFalse(escrow.yieldPaused());
    }

    function test_releaseRecallsFromVault() public {
        vm.prank(operator);
        escrow.deploy(90e6);
        (uint256 id, uint256 projectId) = MarketsKit.onboard(builders, badge, address(0x7EA3), SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.warp(block.timestamp + 7 days);
        escrow.executeRelease(KEY);
        assertEq(fund.incomeOf(fund.currentEpoch(), id), 100e6);
        assertEq(escrow.totalEscrow(), 0);
        assertEq(escrow.deployedPrincipal(), 0);
    }

    function test_releaseRevertsWhenVaultIlliquid() public {
        vm.prank(operator);
        escrow.deploy(90e6);
        (, uint256 projectId) = MarketsKit.onboard(builders, badge, address(0x7EA3), SRC);
        vm.prank(operator);
        escrow.queueRelease(SRC, projectId);
        vm.warp(block.timestamp + 7 days);
        vault.setFrozen(true);
        vm.expectRevert();
        escrow.executeRelease(KEY);
        assertEq(escrow.escrowOf(KEY), 100e6);
        (,, uint64 readyAt) = escrow.pendingRelease(KEY);
        assertGt(readyAt, 0);
        vault.setFrozen(false);
        escrow.executeRelease(KEY); // retry succeeds
        assertEq(escrow.escrowOf(KEY), 0);
    }

    function test_creditNeverTouchesTheVault() public {
        vm.prank(operator);
        escrow.deploy(90e6);
        vault.setBroken(true);
        vm.startPrank(markets);
        ledger.internalTransfer(address(escrow), 5e6);
        escrow.credit(KEY, 5e6); // must not revert
        vm.stopPrank();
        assertEq(escrow.escrowOf(KEY), 105e6);
    }

    function test_setVaultOnlyWhenEmptyAndMatchingAsset() public {
        vm.prank(operator);
        escrow.deploy(50e6);
        MockVault other = new MockVault(usdc);
        vm.expectRevert(WonderEscrow.VaultInUse.selector);
        escrow.setVault(IERC4626(address(other)));
        vm.prank(operator);
        escrow.recall(50e6);
        MockUSDC notUsdc = new MockUSDC();
        MockVault wrong = new MockVault(notUsdc);
        vm.expectRevert(WonderEscrow.WrongAsset.selector);
        escrow.setVault(IERC4626(address(wrong)));
        escrow.setVault(IERC4626(address(other)));
    }

    /// A vault whose share price was inflated before our deposit (a donation to
    /// an empty vault) would mint shares worth less than we put in: refused.
    function test_deployRefusesSlippage() public {
        vault.accrue(1_000e6); // donation into the empty vault
        vm.prank(operator);
        vm.expectRevert(WonderEscrow.Slippage.selector);
        escrow.deploy(50e6);
        assertEq(escrow.deployedPrincipal(), 0);
        assertEq(ledger.balanceOf(address(escrow)), 100e6);
    }

    /// Surplus that sits in the vault as principal (it paid a sweep from the
    /// ledger) is paid once the keeper recalls it; harvest itself pays only
    /// from the ledger, so it never takes principal the book still counts.
    function test_harvestPaysOnlyFromLiquid() public {
        vm.prank(operator);
        escrow.deploy(90e6);
        vm.prank(markets);
        ledger.internalTransfer(address(escrow), 20e6); // donation, not credited
        vm.warp(block.timestamp + 180 days);
        escrow.sweep(KEY); // recalls 70: ledger 0, principal 20, owed 0
        assertEq(escrow.harvest(), 0);
        vm.prank(operator);
        escrow.recall(20e6);
        assertEq(escrow.harvest(), 20e6);
        assertEq(escrow.deployedPrincipal(), 0);
    }

    /// At a high share price, withdrawing the yield by exact assets would burn a
    /// rounded-up share out of principal; harvest redeems whole shares instead
    /// and keeps book principal backed.
    function test_harvestNeverDipsIntoPrincipalAtHighSharePrice() public {
        vm.prank(operator);
        escrow.deploy(1_000); // 1,000 wei of shares
        vault.accrue(3_333_333); // share price ~3,334 assets
        escrow.harvest();
        assertGe(escrow.vaultAssets(), escrow.deployedPrincipal(), "principal still in the vault");
        assertGe(
            ledger.balanceOf(address(escrow)) + escrow.deployedPrincipal(), escrow.totalEscrow(), "book solvent"
        );
    }

    // ── share dust, total loss and who may harvest (final review I1-I3) ──

    function _offsetVault() internal returns (OffsetMockVault v) {
        v = new OffsetMockVault(usdc);
        escrow.setVault(IERC4626(address(v)));
    }

    /// Exact-asset recalls leave 18-decimal share dust worth 0: a full exit
    /// (recallAll) and a vault switch must still work.
    function test_setVaultAfterFullExitWithShareDust() public {
        OffsetMockVault v = _offsetVault();
        vm.prank(operator);
        escrow.deploy(90e6);
        v.accrue(7_777_777);
        vm.prank(operator);
        escrow.harvest();
        uint256 all = escrow.vaultAssets();
        vm.prank(operator);
        escrow.recall(all);
        assertEq(escrow.vaultAssets(), 0);
        assertGt(v.balanceOf(address(escrow)), 0, "share dust left behind");
        escrow.setVault(IERC4626(address(new OffsetMockVault(usdc))));
        assertEq(escrow.deployedPrincipal(), 0);
    }

    function test_recallAllRedeemsEveryShare() public {
        OffsetMockVault v = _offsetVault();
        vm.prank(operator);
        escrow.deploy(90e6);
        v.accrue(1);
        vm.prank(operator);
        escrow.recallAll();
        assertEq(v.balanceOf(address(escrow)), 0);
        assertEq(escrow.deployedPrincipal(), 0);
        assertGe(ledger.balanceOf(address(escrow)), 100e6);
    }

    /// After a total loss the Safe tops the escrow up, then leaves the vault;
    /// the lost principal leaves the book only once the ledger covers the escrow.
    function test_setVaultAfterTotalLossNeedsTopUp() public {
        OffsetMockVault v = _offsetVault();
        vm.prank(operator);
        escrow.deploy(90e6);
        v.lose(90e6);
        vm.expectRevert(WonderEscrow.Unfunded.selector);
        escrow.setVault(IERC4626(address(0)));
        vm.prank(markets);
        ledger.internalTransfer(address(escrow), 90e6); // the Safe's top-up
        escrow.setVault(IERC4626(address(0)));
        assertEq(escrow.deployedPrincipal(), 0);
        // trading still credits
        vm.startPrank(markets);
        ledger.internalTransfer(address(escrow), 1e6);
        escrow.credit(KEY, 1e6);
        vm.stopPrank();
    }

    function test_harvestWhenGainIsOneWei() public {
        OffsetMockVault v = _offsetVault();
        vm.prank(operator);
        escrow.deploy(90e6);
        v.accrue(2); // the virtual share takes a wei: 1 wei of gain
        assertEq(escrow.vaultAssets() - escrow.deployedPrincipal(), 1);
        vm.prank(operator);
        assertEq(escrow.harvest(), 0);
    }

    /// A Safe top-up that bridges an illiquid vault is not surplus for anyone
    /// to sweep into the season pool: harvest is the keeper's (YIELD_ROLE).
    function test_harvestOnlyYieldRole() public {
        vm.prank(markets);
        vm.expectRevert();
        escrow.harvest();
    }
}
