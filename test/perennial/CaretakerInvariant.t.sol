// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {FundKit} from "./FundKit.sol";

/// Handler over the BuilderFund: it plays the markets (credits income it paid
/// in), the Safe (deactivates / reactivates builders, sweeps frozen income) and
/// a claim cranker (the caretaker / keeper key: anyone may crank claimFor).
contract IncomeHandler is Test {
    NanoLedger public ledger;
    BuilderFund public fund;
    BuilderRegistry public builders;
    address public cranker = address(0xCA4E);
    uint256[3] public builderIds = [uint256(1), 2, 3]; // 0xB1, 0xB2, 0xB3
    uint256 public credited; // ghost: every unit credited as income

    constructor(NanoLedger ledger_, BuilderFund fund_, BuilderRegistry builders_) {
        ledger = ledger_;
        fund = fund_;
        builders = builders_;
    }

    function earn(uint256 bIdx, uint256 amount) external {
        amount = bound(amount, 1, 200_000e6);
        if (ledger.balanceOf(address(this)) < amount) return;
        ledger.internalTransfer(address(fund), amount);
        fund.credit(builderIds[bIdx % 3], amount);
        credited += amount;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 20 days));
    }

    function claim(uint256 epoch, uint256 bIdx) external {
        uint256 cur = fund.currentEpoch();
        vm.prank(cranker);
        try fund.claimFor(epoch % (cur + 1), builderIds[bIdx % 3]) {} catch {}
    }

    function toggle(uint256 bIdx) external {
        uint256 id = builders.builderIdOf(address(uint160(0xB1 + bIdx % 3)));
        builders.setActive(id, !builders.isActiveBuilderId(id));
    }

    function sweep(uint256 epoch, uint256 bIdx) external {
        uint256 cur = fund.currentEpoch();
        try fund.sweepFrozen(epoch % (cur + 1), builderIds[bIdx % 3]) {} catch {}
    }
}

contract CaretakerInvariantTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    BuilderFund fund;
    SeasonPool pool;
    IncomeHandler handler;
    address treasury = address(0x7EA5);

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        builders.registerFor(address(0xB1), "b1");
        builders.registerFor(address(0xB2), "b2");
        builders.registerFor(address(0xB3), "b3");
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, treasury, 7 days);
        handler = new IncomeHandler(ledger, fund, builders);
        FundKit.wire(fund, address(handler));
        fund.grantRole(fund.GOVERNOR_ROLE(), address(handler));
        builders.grantRole(builders.REGISTRAR_ROLE(), address(handler));

        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000_000e6);
        ledger.internalTransfer(address(handler), 100_000_000e6);

        bytes4[] memory sel = new bytes4[](5);
        sel[0] = IncomeHandler.earn.selector;
        sel[1] = IncomeHandler.warp.selector;
        sel[2] = IncomeHandler.claim.selector;
        sel[3] = IncomeHandler.toggle.selector;
        sel[4] = IncomeHandler.sweep.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// Whoever cranks claims never gains a unit. ("Can't rug.")
    function invariant_crankerCannotSkim() public view {
        assertEq(ledger.balanceOf(handler.cranker()), 0, "cranker skimmed funds");
    }

    function invariant_solvent() public view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
        assertGe(ledger.balanceOf(address(fund)), fund.outstanding(), "fund below outstanding income");
        assertEq(ledger.balanceOf(address(pool)), pool.unallocated() + pool.reserved(), "pool books");
    }

    /// Every credited unit is in the fund, with a builder, the treasury or the pool.
    function invariant_conservation() public view {
        uint256 out = ledger.balanceOf(address(0xB1)) + ledger.balanceOf(address(0xB2))
            + ledger.balanceOf(address(0xB3)) + ledger.balanceOf(treasury) + ledger.balanceOf(address(pool));
        assertEq(ledger.balanceOf(address(fund)) + out, handler.credited(), "income leaked");
        assertEq(ledger.balanceOf(address(fund)), fund.outstanding(), "fund holds exactly the unclaimed income");
    }

    /// Income credited to an id that is not an active builder (a compromised
    /// markets role, or a builder deactivated mid-epoch) can never be claimed
    /// to anyone; only the Safe can sweep it to the season pool.
    function test_unregisteredIdIncomeIsNeverClaimable() public {
        vm.startPrank(address(handler));
        ledger.internalTransfer(address(fund), 100e6);
        fund.credit(99, 100e6); // an id never registered
        vm.stopPrank();
        vm.warp(fund.epochEnd(0));
        vm.expectRevert(BuilderFund.BuilderInactive.selector);
        fund.claimFor(0, 99);
        fund.sweepFrozen(0, 99);
        assertEq(pool.unallocated(), 100e6);
        assertEq(ledger.balanceOf(address(0xDEAD)), 0);
    }
}
