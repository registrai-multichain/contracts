// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {BinaryMathBase} from "./BinaryMathBase.t.sol";
import {BinaryMarket} from "../../../src/nanopay/BinaryMarket.sol";
import {Attestation} from "../../../src/Attestation.sol";

/// A market that is CERTAIN to void while it still trades: the agent's free
/// bond is locked by a pending challenge (Attestation requires minBond free to
/// attest), yet Registry still reports it active, so BinaryMarket._trading lets
/// trading continue. Combined with the per-account netCost clamp, a two-account
/// trader extracts the LP's seed risk-free.
contract BinaryMathVoidPoCTest is BinaryMathBase {
    address challenger = address(0xC4A1);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        _deploy();
        _fund(alice, 1e12);
        _fund(bob, 1e12);
        usdc.mint(challenger, 100e6);
        vm.prank(challenger);
        usdc.approve(address(dispute), type(uint256).max);
    }

    /// FIXED (BinaryMarket M-1 vector): once challenges hold the agent's bond below
    /// the feed's minBond it cannot attest, so no market opens or trades on it; a
    /// market already open stops trading (no farming a certain void) and resumes
    /// when the bond is topped up.
    function test_fixed_lockedBondAgent_noOpenNoTrade_resumesOnTopUp() public {
        uint256 expiry = (block.timestamp / 5 minutes + 2) * 5 minutes;
        vm.prank(creator);
        bytes32 open = markets.createMarket(feedId, agent, 100, BinaryMarket.Comparator.GreaterOrEqual, expiry, 5e6);
        for (uint256 i; i < 10; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(agent);
            bytes32 att = attestation.attest(feedId, 1, bytes32(i));
            vm.prank(challenger);
            dispute.challenge(att, bytes32("e"));
        }
        assertTrue(registry.isActiveAgent(feedId, agent), "still 'active'");
        assertLt(registry.availableBond(feedId, agent), registry.getFeed(feedId).minBond);

        vm.prank(creator);
        vm.expectRevert(BinaryMarket.AgentBondLocked.selector);
        markets.createMarket(feedId, agent, 100, BinaryMarket.Comparator.GreaterOrEqual, expiry + 300, 5e6);
        vm.prank(alice);
        vm.expectRevert(BinaryMarket.AgentBondLocked.selector);
        markets.buy(open, BinaryMarket.Outcome.Yes, 5e6, 0, type(uint256).max);

        // the agent tops up: trading resumes
        uint256 minBond = registry.getFeed(feedId).minBond;
        usdc.mint(agent, minBond);
        vm.startPrank(agent);
        usdc.approve(address(registry), minBond);
        registry.topUpBond(feedId, minBond);
        vm.stopPrank();
        vm.prank(alice);
        markets.buy(open, BinaryMarket.Outcome.Yes, 5e6, 0, type(uint256).max);
    }
}
