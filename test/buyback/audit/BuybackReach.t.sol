// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BuybackInvariantTest} from "./BuybackInvariant.t.sol";

/// Proves the invariant campaign reaches the states that matter: replays random action
/// sequences through the same handler and counts rounds, partial fills, repoints and holds.
contract BuybackReachTest is BuybackInvariantTest {
    function test_campaignReachesRoundsPartialFillsAndRepoints() public {
        (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSignature("handler()"));
        ok; ret;
        uint256 seed = 42;
        for (uint256 i; i < 6000; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = seed % 13;
            uint256 x = seed >> 8;
            if (a == 0) h.fundDirect(x, x & 1 == 1);
            else if (a == 1) h.payTreasury(x, x & 1 == 1);
            else if (a == 2) h.distribute();
            else if (a == 3 || a == 4) h.burn(x & 1 == 1);
            else if (a == 5 || a == 6) h.warp(x);
            else if (a == 7) h.setFill(x % 3 == 0 ? x : 10_000);
            else if (a == 8) h.propose(x & 1 == 1);
            else if (a == 9) h.accept();
            else if (a == 10) h.cancel();
            else if (a == 12) h.warpLong(x);
            else if (a == 11) { h.payBuybackOnLedger(x); h.sweep(); }
        }
        console.log("successful burns ", h.successfulBurns());
        console.log("rounds opened    ", h.roundsOpened());
        console.log("partial fills    ", h.partialFills());
        console.log("held distributes ", h.heldDistributes());
        console.log("repoints accepted", h.repointsAccepted());
        console.log("repoints cancelled", h.repointsCancelled());
        assertEq(h.violation(), "");
        assertGt(h.roundsOpened(), 10);
        assertGt(h.partialFills(), 5);
        assertGt(h.heldDistributes(), 5);
        assertGt(h.repointsAccepted(), 5);
        assertGt(h.repointsCancelled(), 5);
    }
}
