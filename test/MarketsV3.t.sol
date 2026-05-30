// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {MarketsV3} from "../src/MarketsV3.sol";
import {Markets} from "../src/Markets.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract MarketsV3Test is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    MarketsV3 markets;

    address creator = makeAddr("creator");
    address agent = creator;
    address resolver = makeAddr("resolver");
    address mm = makeAddr("mm");
    address alice = makeAddr("alice");
    address operator = makeAddr("operator"); // stands in for a lending contract
    address bob = makeAddr("bob");

    bytes32 constant METH = keccak256("m");
    uint256 constant DW = 1 days;
    uint256 constant MIN_BOND = 100e6;
    bytes32 feedId;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        markets = new MarketsV3(attestation, registry, usdc, makeAddr("treasury"));
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        usdc.mint(agent, 10_000e6);
        usdc.mint(mm, 1_000_000e6);
        usdc.mint(alice, 100_000e6);

        vm.prank(creator);
        feedId = registry.createFeed("f", METH, MIN_BOND, DW, resolver);
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgent(feedId, METH, MIN_BOND);
        vm.stopPrank();
    }

    function _market() internal returns (bytes32 mid) {
        vm.startPrank(mm);
        usdc.approve(address(markets), 1_000e6);
        mid = markets.createMarket(feedId, agent, 17_000, Markets.Comparator.GreaterThan, block.timestamp + 30 days, 1_000e6);
        vm.stopPrank();
    }

    function _aliceBuysYes(bytes32 mid, uint256 spend) internal returns (uint256 shares) {
        vm.startPrank(alice);
        usdc.approve(address(markets), spend);
        shares = markets.buy(mid, Markets.Outcome.Yes, spend, 0);
        vm.stopPrank();
    }

    // ── inherited behaviour still works (v3 is v2 + transfer) ──
    function test_inherited_buy_sell_intact() public {
        bytes32 mid = _market();
        uint256 sh = _aliceBuysYes(mid, 200e6);
        assertEq(markets.yesBalance(mid, alice), sh);
        vm.prank(alice);
        uint256 cash = markets.sell(mid, Markets.Outcome.Yes, sh, 0);
        assertGt(cash, 0);
        assertEq(markets.yesBalance(mid, alice), 0);
    }

    // ── operator approval gating ──
    function test_transfer_requires_operator_or_self() public {
        bytes32 mid = _market();
        uint256 sh = _aliceBuysYes(mid, 200e6);

        // operator not yet approved → revert
        vm.prank(operator);
        vm.expectRevert(MarketsV3.NotShareOperator.selector);
        markets.transferSharesFrom(mid, Markets.Outcome.Yes, alice, operator, sh);

        // alice approves
        vm.prank(alice);
        markets.setShareOperator(operator, true);

        // operator pulls the position in as collateral
        vm.prank(operator);
        markets.transferSharesFrom(mid, Markets.Outcome.Yes, alice, operator, sh);
        assertEq(markets.yesBalance(mid, alice), 0);
        assertEq(markets.yesBalance(mid, operator), sh);
    }

    function test_self_transfer_allowed_without_approval() public {
        bytes32 mid = _market();
        uint256 sh = _aliceBuysYes(mid, 200e6);
        // alice moves her own shares to bob (from == msg.sender)
        vm.prank(alice);
        markets.transferSharesFrom(mid, Markets.Outcome.Yes, alice, bob, sh);
        assertEq(markets.yesBalance(mid, bob), sh);
    }

    function test_revoke_operator() public {
        bytes32 mid = _market();
        uint256 sh = _aliceBuysYes(mid, 200e6);
        vm.startPrank(alice);
        markets.setShareOperator(operator, true);
        markets.setShareOperator(operator, false);
        vm.stopPrank();
        vm.prank(operator);
        vm.expectRevert(MarketsV3.NotShareOperator.selector);
        markets.transferSharesFrom(mid, Markets.Outcome.Yes, alice, operator, sh);
    }

    function test_transfer_more_than_balance_reverts() public {
        bytes32 mid = _market();
        uint256 sh = _aliceBuysYes(mid, 200e6);
        vm.prank(alice);
        markets.setShareOperator(operator, true);
        vm.prank(operator);
        vm.expectRevert(MarketsV3.InsufficientShareBalance.selector);
        markets.transferSharesFrom(mid, Markets.Outcome.Yes, alice, operator, sh + 1);
    }

    function test_self_transfer_to_self_reverts() public {
        bytes32 mid = _market();
        uint256 sh = _aliceBuysYes(mid, 200e6);
        vm.prank(alice);
        vm.expectRevert(MarketsV3.SelfTransfer.selector);
        markets.transferSharesFrom(mid, Markets.Outcome.Yes, alice, alice, sh);
    }

    // ── collateral round-trip: operator can hold, then return, then the
    //    holder can sell — proving the lending custody flow works ──
    function test_collateral_roundtrip_then_sell() public {
        bytes32 mid = _market();
        uint256 sh = _aliceBuysYes(mid, 200e6);
        vm.prank(alice);
        markets.setShareOperator(operator, true);

        // pull in as collateral
        vm.prank(operator);
        markets.transferSharesFrom(mid, Markets.Outcome.Yes, alice, operator, sh);

        // return on repay
        vm.prank(operator);
        markets.transferSharesFrom(mid, Markets.Outcome.Yes, operator, alice, sh);
        assertEq(markets.yesBalance(mid, alice), sh);

        // alice can sell as normal afterwards
        vm.prank(alice);
        uint256 cash = markets.sell(mid, Markets.Outcome.Yes, sh, 0);
        assertGt(cash, 0);
    }
}
