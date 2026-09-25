// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {WonderEscrow} from "../../src/perennial/WonderEscrow.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {FundKit} from "../perennial/FundKit.sol";
import {MarketsKit} from "../perennial/MarketsKit.sol";

/// WonderEscrow against the real ERC-4626 vault the Safe would set (a curated
/// Morpho USDC vault on Arc). Skipped unless MORPHO_VAULT is set:
///   MORPHO_VAULT=0x… [ARC_MAINNET_RPC=https://rpc.mainnet.arc.io] [ARC_USDC=0x3600…] \
///     forge test --match-path test/fork/MorphoVaultFork.t.sol -vv
contract MorphoVaultForkTest is Test {
    address constant ARC_USDC_DEFAULT = 0x3600000000000000000000000000000000000000;

    function test_depositHarvestRecallOnRealVault() public {
        address vaultAddr = vm.envOr("MORPHO_VAULT", address(0));
        vm.skip(vaultAddr == address(0));
        vm.createSelectFork(vm.envOr("ARC_MAINNET_RPC", string("https://rpc.mainnet.arc.io")));
        address usdcAddr = vm.envOr("ARC_USDC", ARC_USDC_DEFAULT);
        IERC4626 vault = IERC4626(vaultAddr);
        assertEq(vault.asset(), usdcAddr, "vault asset is not ARC_USDC");

        NanoLedger ledger = new NanoLedger(IERC20(usdcAddr), address(this));
        BuilderRegistry builders = new BuilderRegistry(address(this));
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, address(this));
        (, BuilderFund fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        VerifiedBuilderBadge badge = MarketsKit.deployBadge(builders);
        WonderEscrow escrow = new WonderEscrow(ledger, fund, badge, address(this), 180 days);
        FundKit.wire(fund, address(escrow));
        escrow.grantRole(escrow.MARKETS_ROLE(), address(this));
        escrow.grantRole(escrow.YIELD_ROLE(), address(this));
        escrow.setVault(vault);
        escrow.setCap(1_000e6);

        // Arc's USDC is the native gas token behind an ERC-20 interface: if a
        // storage write cannot fund us on this fork, say so instead of passing.
        deal(usdcAddr, address(this), 1_000e6);
        vm.skip(IERC20(usdcAddr).balanceOf(address(this)) < 1_000e6);
        IERC20(usdcAddr).approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000e6);
        ledger.internalTransfer(address(escrow), 1_000e6);
        escrow.credit(keccak256("github:acme/tool"), 1_000e6);

        escrow.deploy(900e6); // reverts Slippage if the vault charges on deposit
        assertApproxEqAbs(escrow.vaultAssets(), 900e6, 2);
        vm.warp(block.timestamp + 30 days);
        escrow.harvest(); // any accrued yield goes to the season pool
        assertGe(ledger.balanceOf(address(escrow)) + escrow.deployedPrincipal(), escrow.totalEscrow(), "book");
        assertGe(ledger.balanceOf(address(escrow)) + escrow.vaultAssets() + 2, escrow.totalEscrow(), "real");
        escrow.recall(escrow.deployedPrincipal());
        assertEq(escrow.deployedPrincipal(), 0);
        assertFalse(escrow.yieldPaused());
    }
}
