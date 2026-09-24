// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {ProgressArbiter} from "../../src/perennial/ProgressArbiter.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

contract ProgressArbiterTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    ProgressPool pool;
    ProgressArbiter arb;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;

    address caretaker = address(0xCA4E);
    address challenger = address(0xC44A);
    address resolver = address(0x5E50);
    address builder = address(0xB111);
    uint256 constant WINDOW = 1 hours;
    uint256 constant STAKE = 10e6;
    uint256 constant MAX_WEIGHT = 10;
    uint256 constant TIMEOUT = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        uint256 builderId = builders.registerFor(builder, "github.com/example/builder");
        caretakers.setCaretaker(builderId, caretaker);
        pool = new ProgressPool(ledger, builders, caretakers, address(this), 0, 1 hours, address(0x7EA5));
        arb = new ProgressArbiter(ledger, pool, builders, caretakers, address(this), WINDOW, STAKE, MAX_WEIGHT, TIMEOUT);
        pool.grantRole(pool.PROGRESS_ROLE(), address(arb));
        arb.grantRole(arb.PROPOSER_ROLE(), caretaker);
        arb.grantRole(arb.RESOLVER_ROLE(), resolver);

        _fund(caretaker);
        _fund(challenger);
        vm.prank(caretaker);
        arb.depositBond(50e6);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(500e6);
        ledger.approveSpender(address(arb), type(uint256).max);
        vm.stopPrank();
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
    }

    function test_propose_finalize_creditsPool() public {
        vm.prank(caretaker);
        uint256 id = arb.propose(builder, 7);
        vm.warp(block.timestamp + WINDOW + 1);
        arb.finalize(id);
        assertEq(pool.progressWeight(0, builder), 7, "weight credited via arbiter");
        _solvent();
    }

    function test_finalize_beforeWindow_reverts() public {
        vm.prank(caretaker);
        uint256 id = arb.propose(builder, 7);
        vm.expectRevert(ProgressArbiter.WindowOpen.selector);
        arb.finalize(id);
    }

    function test_challenge_thenResolveInvalid_slashes_noCredit() public {
        vm.prank(caretaker);
        uint256 id = arb.propose(builder, 7);
        uint256 chBefore = ledger.balanceOf(challenger);
        vm.prank(challenger);
        arb.challenge(id);
        vm.prank(resolver);
        arb.resolve(id, false);
        assertEq(ledger.balanceOf(challenger), chBefore + STAKE, "challenger rewarded");
        assertEq(arb.bondOf(caretaker), 50e6 - STAKE, "proposer slashed");
        vm.expectRevert(ProgressArbiter.BadState.selector);
        arb.finalize(id);
        assertEq(pool.progressWeight(0, builder), 0, "no credit for false progress");
        _solvent();
    }

    function test_challenge_thenResolveValid_allowsFinalize() public {
        vm.prank(caretaker);
        uint256 id = arb.propose(builder, 7);
        vm.prank(challenger);
        arb.challenge(id);
        vm.prank(resolver);
        arb.resolve(id, true);
        assertEq(arb.bondOf(caretaker), 50e6 + STAKE, "proposer gains challenger stake");
        arb.finalize(id);
        assertEq(pool.progressWeight(0, builder), 7, "valid progress credited");
        _solvent();
    }

    function test_challenge_afterWindow_reverts() public {
        vm.prank(caretaker);
        uint256 id = arb.propose(builder, 7);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(challenger);
        vm.expectRevert(ProgressArbiter.WindowClosed.selector);
        arb.challenge(id);
    }

    function test_propose_onlyProposer() public {
        vm.prank(challenger);
        vm.expectRevert();
        arb.propose(builder, 7);
    }

    function test_resolve_onlyResolver() public {
        vm.prank(caretaker);
        uint256 id = arb.propose(builder, 7);
        vm.prank(challenger);
        arb.challenge(id);
        vm.prank(challenger);
        vm.expectRevert();
        arb.resolve(id, false);
    }

    function test_propose_insufficientBond_reverts() public {
        address poor = address(0x9999);
        arb.grantRole(arb.PROPOSER_ROLE(), poor);
        caretakers.setCaretaker(1, poor);
        vm.prank(poor);
        vm.expectRevert(ProgressArbiter.InsufficientBond.selector);
        arb.propose(builder, 7);
    }

    function test_propose_rejectsUnregisteredBuilder() public {
        vm.prank(caretaker);
        vm.expectRevert(ProgressArbiter.BuilderInactive.selector);
        arb.propose(address(0xBAD), 7);
    }

    function test_propose_rejectsWrongCaretaker() public {
        arb.grantRole(arb.PROPOSER_ROLE(), challenger);
        vm.prank(challenger);
        vm.expectRevert(ProgressArbiter.UnauthorizedCaretaker.selector);
        arb.propose(builder, 7);
    }

    function test_propose_rejectsZeroOrExcessiveWeight() public {
        vm.startPrank(caretaker);
        vm.expectRevert(ProgressArbiter.InvalidWeight.selector);
        arb.propose(builder, 0);
        vm.expectRevert(ProgressArbiter.InvalidWeight.selector);
        arb.propose(builder, MAX_WEIGHT + 1);
        vm.stopPrank();
    }

    function test_deployerDoesNotHaveProgressRole() public view {
        assertFalse(pool.hasRole(pool.PROGRESS_ROLE(), address(this)));
        assertTrue(pool.hasRole(pool.PROGRESS_ROLE(), address(arb)));
    }

    function test_paramsCannotDisableBondOrChallengeWindow() public {
        vm.expectRevert(ProgressArbiter.InvalidParams.selector);
        arb.setParams(0, STAKE);
        vm.expectRevert(ProgressArbiter.InvalidParams.selector);
        arb.setParams(WINDOW, 0);
    }

    // ── M2: no stake can lock forever ──

    event ProgressClosedInactive(uint256 indexed id, address indexed builder, bool challengerRefunded);
    event ChallengeExpired(uint256 indexed id, address indexed challenger);

    function _propose() internal returns (uint256 id) {
        vm.prank(caretaker);
        id = arb.propose(builder, 7);
    }

    function _challengeIt(uint256 id) internal {
        vm.prank(challenger);
        arb.challenge(id);
    }

    function test_closeInactive_proposed_refundsProposer_noCredit() public {
        uint256 id = _propose();
        builders.setActive(1, false);
        vm.expectRevert(ProgressArbiter.WindowOpen.selector);
        arb.closeInactive(id); // a challenger keeps the whole window
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectEmit(true, true, false, true, address(arb));
        emit ProgressClosedInactive(id, builder, false);
        arb.closeInactive(id);
        assertEq(uint8(arb.getEntry(id).state), uint8(ProgressArbiter.State.Closed));
        assertEq(arb.availableBond(caretaker), 50e6, "stake unlocked");
        assertEq(pool.progressWeight(0, builder), 0, "no weight credited");
        vm.expectRevert(ProgressArbiter.BadState.selector);
        arb.finalize(id);
        _solvent();
    }

    function test_closeInactive_activeBuilder_reverts() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(ProgressArbiter.BuilderActive.selector);
        arb.closeInactive(id);
    }

    function test_closeInactive_challenged_resolverOnly_refundsBoth() public {
        uint256 id = _propose();
        uint256 chBefore = ledger.balanceOf(challenger);
        _challengeIt(id);
        builders.setActive(1, false);
        vm.expectRevert(); // proposer (or anyone) cannot dodge a pending ruling
        arb.closeInactive(id);
        vm.prank(resolver);
        vm.expectEmit(true, true, false, true, address(arb));
        emit ProgressClosedInactive(id, builder, true);
        arb.closeInactive(id);
        assertEq(ledger.balanceOf(challenger), chBefore, "challenger stake refunded");
        assertEq(arb.availableBond(caretaker), 50e6);
        assertEq(arb.lockedBond(caretaker), 0);
        _solvent();
    }

    function test_closeInactive_resolvedValid() public {
        uint256 id = _propose();
        _challengeIt(id);
        vm.prank(resolver);
        arb.resolve(id, true);
        builders.setActive(1, false);
        arb.closeInactive(id);
        assertEq(arb.availableBond(caretaker), 50e6 + STAKE, "stake + won challenger stake");
        assertEq(pool.progressWeight(0, builder), 0);
        _solvent();
    }

    function test_closeInactive_terminalStates_revert() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + WINDOW + 1);
        arb.finalize(id);
        builders.setActive(1, false);
        vm.expectRevert(ProgressArbiter.BadState.selector);
        arb.closeInactive(id);
    }

    function test_expireChallenge_afterTimeout_refundsBoth() public {
        uint256 id = _propose();
        uint256 chBefore = ledger.balanceOf(challenger);
        _challengeIt(id);
        assertEq(arb.challengedAt(id), block.timestamp);
        vm.warp(block.timestamp + TIMEOUT - 1);
        vm.expectRevert(ProgressArbiter.TimeoutNotReached.selector);
        arb.expireChallenge(id);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, true, false, true, address(arb));
        emit ChallengeExpired(id, challenger);
        arb.expireChallenge(id);
        assertEq(uint8(arb.getEntry(id).state), uint8(ProgressArbiter.State.Expired));
        assertEq(ledger.balanceOf(challenger), chBefore);
        assertEq(arb.availableBond(caretaker), 50e6);
        assertEq(pool.progressWeight(0, builder), 0);
        vm.prank(resolver);
        vm.expectRevert(ProgressArbiter.BadState.selector);
        arb.resolve(id, false);
        vm.expectRevert(ProgressArbiter.BadState.selector);
        arb.finalize(id);
        _solvent();
    }

    function test_expireChallenge_unchallenged_reverts() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.expectRevert(ProgressArbiter.BadState.selector);
        arb.expireChallenge(id);
    }

    function test_resolverStillRulesBeforeExpiry() public {
        uint256 id = _propose();
        _challengeIt(id);
        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.prank(resolver);
        arb.resolve(id, false); // a late ruling is still accepted until someone expires it
        assertEq(uint8(arb.getEntry(id).state), uint8(ProgressArbiter.State.ResolvedInvalid));
        _solvent();
    }

    function test_constructor_rejectsZeroTimeout() public {
        vm.expectRevert(ProgressArbiter.InvalidParams.selector);
        new ProgressArbiter(ledger, pool, builders, caretakers, address(this), WINDOW, STAKE, MAX_WEIGHT, 0);
    }
}
