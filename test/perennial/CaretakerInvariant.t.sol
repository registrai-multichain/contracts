// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// Handler that drives ONLY the caretaker-key-callable surface of ProgressPool,
/// assigning weight to a fixed builder set that EXCLUDES the caretaker (the
/// "honest weights" precondition). The caretaker actor is address(this).
contract CaretakerHandler is Test {
    ProgressPool public pool;
    NanoLedger public ledger;
    address[3] public builders = [address(0xB1), address(0xB2), address(0xB3)];

    constructor(ProgressPool pool_, NanoLedger ledger_) {
        pool = pool_;
        ledger = ledger_;
    }

    function addProgress(uint256 bIdx, uint256 w) external {
        address b = builders[bIdx % 3];
        pool.addProgress(b, bound(w, 0, 1_000));
    }

    function closeEpoch() external {
        // epochLength is 0 in this harness, so this always advances.
        pool.closeEpoch();
    }

    function claimFor(uint256 epoch, uint256 bIdx) external {
        address b = builders[bIdx % 3];
        uint256 e = pool.currentEpoch();
        if (e == 0) return;
        try pool.claimFor(epoch % e, b) {} catch {}
    }

    function settle(uint256 epoch, uint256 bIdx) external {
        address b = builders[bIdx % 3];
        uint256 e = pool.currentEpoch();
        if (e == 0) return;
        uint256 id = pool.streamIdOf(epoch % e, b);
        try ledger.settleStream(id) {} catch {}
    }
}

contract CaretakerInvariantTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    ProgressPool pool;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    CaretakerHandler handler;

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        builders.registerFor(address(0xB1), "b1");
        builders.registerFor(address(0xB2), "b2");
        builders.registerFor(address(0xB3), "b3");
        pool = new ProgressPool(ledger, builders, caretakers, address(this), 0, 1 hours); // epochLength 0, 1h window
        handler = new CaretakerHandler(pool, ledger);

        // the caretaker (the handler) holds PROGRESS_ROLE — the keeper seam
        pool.grantRole(pool.PROGRESS_ROLE(), address(handler));

        // give the pool a real commons balance to distribute
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000_000e6);
        ledger.internalTransfer(address(pool), 1_000_000e6);

        targetContract(address(handler));
    }

    /// The caretaker, acting as operator over legitimate builders, can never
    /// increase its own ledger balance. ("Can't rug.")
    function invariant_caretakerCannotSkim() public view {
        assertEq(ledger.balanceOf(address(handler)), 0, "caretaker skimmed funds");
    }

    /// Ledger stays solvent throughout.
    function invariant_solvent() public view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
    }

    /// Even if a progress writer is compromised, an unregistered sock puppet
    /// cannot receive progress or drain a claim.
    function test_unregisteredSelfWeightIsRejected() public {
        address puppet = address(0xDEAD);
        vm.prank(address(handler));
        vm.expectRevert(ProgressPool.BuilderInactive.selector);
        pool.addProgress(puppet, 100);
        assertEq(ledger.balanceOf(puppet), 0);
    }
}
