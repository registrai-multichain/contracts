// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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

/// Drives the escrow as the markets (credit) and the operator (queue a claim),
/// with time and permissionless releases and sweeps in between. No vault.
contract WonderHandler is Test {
    NanoLedger ledger;
    WonderEscrow escrow;
    BuilderRegistry builders;
    VerifiedBuilderBadge badge;
    bytes32[3] keys;
    string[3] sources = ["github:a/one", "github:b/two", "domain:c.dev"];
    uint256 public released;
    uint256 public forwarded;
    uint256 public credited;
    uint256 public swept;
    constructor(NanoLedger l, WonderEscrow e, BuilderRegistry b, VerifiedBuilderBadge bd) {
        (ledger, escrow, builders, badge) = (l, e, b, bd);
        for (uint256 i; i < 3; ++i) keys[i] = keccak256(bytes(sources[i]));
    }

    function keyAt(uint256 i) external view returns (bytes32) {
        return keys[i];
    }

    /// A team claims source k: registered, project added, badge issued, release queued.
    function claim(uint256 k) external {
        k %= 3;
        bytes32 key = keys[k];
        (,, uint64 ready) = escrow.pendingRelease(key);
        if (escrow.releasedTo(key) != 0 || ready != 0) return;
        address owner = address(uint160(0x7000 + k));
        uint256 id = builders.builderIdOf(owner);
        if (id == 0) id = builders.registerFor(owner, "");
        uint256 pid = builders.addProjectFor(id, sources[k]);
        if (badge.serialOf(id) == 0) badge.issue(id);
        escrow.queueRelease(sources[k], pid);
    }

    function execute(uint256 k) external {
        bytes32 key = keys[k % 3];
        (,, uint64 ready) = escrow.pendingRelease(key);
        if (ready == 0 || block.timestamp < ready) return;
        uint256 before = escrow.escrowOf(key);
        escrow.executeRelease(key);
        released += before;
    }

    function credit(uint256 k, uint256 amount) external {
        amount = bound(amount, 1, 1_000e6);
        bytes32 key = keys[k % 3];
        bool isReleased = escrow.releasedTo(key) != 0;
        ledger.internalTransfer(address(escrow), amount);
        escrow.credit(key, amount);
        if (isReleased) forwarded += amount; // straight to the builder's income
        else credited += amount;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 60 days));
    }

    function sweep(uint256 k) external {
        bytes32 key = keys[k % 3];
        uint256 before = escrow.escrowOf(key);
        try escrow.sweep(key) {
            swept += before;
        } catch {}
    }
}

contract WonderInvariantTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    WonderEscrow escrow;
    WonderHandler handler;

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        BuilderRegistry builders = new BuilderRegistry(address(this));
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, address(this));
        (, BuilderFund fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        VerifiedBuilderBadge badge = MarketsKit.deployBadge(builders);
        escrow = new WonderEscrow(ledger, fund, badge, address(this), 90 days);
        FundKit.wireEscrow(fund, address(escrow));
        handler = new WonderHandler(ledger, escrow, builders, badge);
        builders.grantRole(builders.REGISTRAR_ROLE(), address(handler));
        badge.grantRole(badge.ISSUER_ROLE(), address(handler));
        escrow.grantRole(escrow.RELEASER_ROLE(), address(handler));
        escrow.grantRole(escrow.MARKETS_ROLE(), address(handler));
        usdc.mint(address(handler), 10_000_000e6);
        vm.startPrank(address(handler));
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(10_000_000e6);
        vm.stopPrank();
        targetContract(address(handler));
    }

    /// Everything escrowed is still owed, or left through a release or a sweep.
    function invariant_accounting() public view {
        assertEq(handler.credited(), escrow.totalEscrow() + handler.swept() + handler.released());
    }

    /// totalEscrow is exactly the sum of the per-source escrows.
    function invariant_totalIsTheSum() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) sum += escrow.escrowOf(handler.keyAt(i));
        assertEq(sum, escrow.totalEscrow());
    }

    /// Solvency: the ledger account covers what is owed.
    function invariant_solvent() public view {
        assertGe(ledger.balanceOf(address(escrow)), escrow.totalEscrow());
    }
}
