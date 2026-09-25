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

/// Drives the escrow as the markets (credit) and the keeper (deploy, recall,
/// harvest), with vault yield, time and permissionless sweeps in between.
contract WonderHandler is Test {
    NanoLedger ledger;
    WonderEscrow escrow;
    MockVault vault;
    bytes32[3] keys;
    uint256 public credited;
    uint256 public swept;
    uint256 public harvested;
    /// Upper bound on vault rounding so far: a deposit loses at most what the
    /// slippage check allows, an exact-assets withdrawal one share's worth, a
    /// harvest (whole-share redeem) a wei.
    uint256 public roundingBound;

    constructor(NanoLedger l, WonderEscrow e, MockVault v) {
        (ledger, escrow, vault) = (l, e, v);
        keys[0] = keccak256("github:a/one");
        keys[1] = keccak256("github:b/two");
        keys[2] = keccak256("domain:c.dev");
    }

    function credit(uint256 k, uint256 amount) external {
        amount = bound(amount, 1, 1_000e6);
        ledger.internalTransfer(address(escrow), amount);
        escrow.credit(keys[k % 3], amount);
        credited += amount;
    }

    function deploy(uint256 amount) external {
        uint256 bal = ledger.balanceOf(address(escrow));
        if (bal == 0 || escrow.yieldPaused()) return;
        amount = bound(amount, 1, bal);
        try escrow.deploy(amount) {
            roundingBound += amount / 1e6 + 1;
        } catch {} // Slippage on an inflated vault is the intended refusal
    }

    function recall(uint256 amount) external {
        uint256 assets = escrow.vaultAssets();
        if (assets == 0) return;
        roundingBound += vault.convertToAssets(1) + 1; // one share, at the price before
        escrow.recall(bound(amount, 1, assets));
    }

    function accrue(uint256 amount) external {
        vault.accrue(bound(amount, 0, 50e6));
    }

    function harvest() external {
        harvested += escrow.harvest();
        roundingBound += 1;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 60 days));
    }

    function sweep(uint256 k) external {
        bytes32 key = keys[k % 3];
        uint256 before = escrow.escrowOf(key);
        uint256 share = vault.convertToAssets(1) + 1; // a sweep may recall
        try escrow.sweep(key) {
            roundingBound += share;
            swept += before;
        } catch {}
    }
}

contract WonderInvariantTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    WonderEscrow escrow;
    MockVault vault;
    WonderHandler handler;

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        BuilderRegistry builders = new BuilderRegistry(address(this));
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, address(this));
        (, BuilderFund fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        VerifiedBuilderBadge badge = MarketsKit.deployBadge(builders);
        escrow = new WonderEscrow(ledger, fund, badge, address(this), 90 days);
        vault = new OffsetMockVault(usdc); // 18-decimal shares, like Morpho
        escrow.setVault(IERC4626(address(vault)));
        escrow.setCap(type(uint128).max);
        FundKit.wire(fund, address(escrow));
        handler = new WonderHandler(ledger, escrow, vault);
        escrow.grantRole(escrow.MARKETS_ROLE(), address(handler));
        escrow.grantRole(escrow.YIELD_ROLE(), address(handler));
        usdc.mint(address(handler), 10_000_000e6);
        vm.startPrank(address(handler));
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(10_000_000e6);
        vm.stopPrank();
        targetContract(address(handler));
    }

    /// Everything credited is still owed or left through a sweep (no releases here).
    function invariant_accounting() public view {
        assertEq(handler.credited(), escrow.totalEscrow() + handler.swept());
    }

    /// Book solvency: ledger balance + deployed principal covers what is owed.
    function invariant_solventBook() public view {
        assertGe(ledger.balanceOf(address(escrow)) + escrow.deployedPrincipal(), escrow.totalEscrow());
    }

    /// Real solvency (the vault only gains here): what the escrow holds covers
    /// what it owes, up to the vault rounding its operations can lose.
    function invariant_solventReal() public view {
        assertGe(
            ledger.balanceOf(address(escrow)) + escrow.vaultAssets() + handler.roundingBound(), escrow.totalEscrow()
        );
    }
}
