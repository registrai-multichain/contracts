// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {BlocklistUSDC} from "./BlocklistUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {RegiFeeSplitter} from "../../src/buyback/RegiFeeSplitter.sol";
import {INanoLedgerMinimal} from "../../src/buyback/INanoLedgerMinimal.sol";

contract RegiFeeSplitterTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    RegiFeeSplitter sp;
    address safe = makeAddr("safe");
    address buyback = makeAddr("buyback");
    address next = makeAddr("next");

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(IERC20(address(usdc)), address(this));
        sp = new RegiFeeSplitter(INanoLedgerMinimal(address(ledger)), IERC20(address(usdc)), safe, buyback);
        vm.warp(1_800_000_000);
    }

    function ledgerPay(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(ledger), amount);
        ledger.depositTo(address(sp), amount); // how MarketsV4 pays: an internal ledger balance
    }

    function test_splitsLedgerIncome40To60() public {
        ledgerPay(100e6);
        (uint256 b, uint256 s) = sp.distribute();
        assertEq(b, 40e6);
        assertEq(s, 60e6);
        assertEq(usdc.balanceOf(buyback), 40e6);
        assertEq(sp.owedToSafe(), 60e6);
        assertEq(usdc.balanceOf(safe), 0, "the Safe's leg is recorded, not pushed");
        assertEq(ledger.balanceOf(address(sp)), 0);
    }

    function test_splitsUsdcSentDirectlyToo() public {
        usdc.mint(address(sp), 10e6);
        ledgerPay(15e6);
        sp.distribute();
        assertEq(usdc.balanceOf(buyback), 10e6);
        assertEq(sp.owedToSafe(), 15e6);
    }

    function test_roundingGoesToTheSafe() public {
        usdc.mint(address(sp), 3); // 3 * 0.4 = 1.2 -> 1 to the buyback, 2 to the Safe
        (uint256 b, uint256 s) = sp.distribute();
        assertEq(b, 1);
        assertEq(s, 2);
    }

    function test_emptyIsANoOp() public {
        (uint256 b, uint256 s) = sp.distribute();
        assertEq(b + s, 0);
    }

    function test_onlyTheSafeRepoints() public {
        vm.expectRevert(RegiFeeSplitter.NotSafe.selector);
        sp.proposeBuyback(next);
        vm.prank(safe);
        vm.expectRevert(RegiFeeSplitter.ZeroAddress.selector);
        sp.proposeBuyback(address(0));
    }

    function test_repointTakesExactlySevenDays() public {
        vm.prank(safe);
        sp.proposeBuyback(next);
        uint256 at = block.timestamp + 7 days;
        vm.warp(at - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(RegiFeeSplitter.TooEarly.selector, at));
        sp.acceptBuyback();
        vm.warp(at);
        vm.prank(safe);
        sp.acceptBuyback();
        assertEq(sp.buyback(), next);
        assertEq(sp.pendingBuyback(), address(0));
    }

    function test_aNewProposalRestartsTheClockAndCancelClears() public {
        uint256 t = 1_800_000_000; // local clock (via_ir reuses block.timestamp reads)
        vm.startPrank(safe);
        sp.proposeBuyback(next);
        t += 6 days;
        vm.warp(t);
        sp.proposeBuyback(makeAddr("other"));
        t += 2 days; // 8 days after the first, 2 after the second
        vm.warp(t);
        vm.expectRevert(abi.encodeWithSelector(RegiFeeSplitter.TooEarly.selector, t + 5 days));
        sp.acceptBuyback();
        sp.cancelBuyback();
        vm.expectRevert(RegiFeeSplitter.NoPending.selector);
        sp.acceptBuyback();
        vm.stopPrank();
        assertEq(sp.buyback(), buyback);
    }

    function test_nonSafeCannotAcceptOrCancel() public {
        vm.prank(safe);
        sp.proposeBuyback(next);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(RegiFeeSplitter.NotSafe.selector);
        sp.acceptBuyback();
        vm.expectRevert(RegiFeeSplitter.NotSafe.selector);
        sp.cancelBuyback();
    }

    function test_acceptsNativeSends() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(sp).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // I1: while a repoint is pending, the buyback's 40% waits in the splitter instead of
    // flowing to the buyback being replaced (which may be unable to swap).
    function test_pendingRepointHoldsTheBuybackShare() public {
        vm.prank(safe);
        sp.proposeBuyback(next);
        ledgerPay(100e6);
        (uint256 b, uint256 s) = sp.distribute();
        assertEq(b, 40e6);
        assertEq(s, 60e6);
        assertEq(usdc.balanceOf(buyback), 0, "old buyback must not receive during a pending repoint");
        assertEq(sp.owedToSafe(), 60e6);
        assertEq(sp.heldForBuyback(), 40e6);
        assertEq(usdc.balanceOf(address(sp)), 100e6); // 40 held for the repoint + 60 owed to the Safe
        ledgerPay(50e6); // a second distribute splits only the new money, never the held share
        sp.distribute();
        assertEq(sp.heldForBuyback(), 60e6);
        assertEq(sp.owedToSafe(), 90e6);
    }

    function test_acceptReleasesTheHeldShareToTheNewBuyback() public {
        vm.prank(safe);
        sp.proposeBuyback(next);
        ledgerPay(100e6);
        sp.distribute();
        vm.warp(1_800_000_000 + 7 days);
        vm.prank(safe);
        sp.acceptBuyback();
        assertEq(usdc.balanceOf(next), 40e6);
        assertEq(sp.heldForBuyback(), 0);
        assertEq(usdc.balanceOf(address(sp)), 60e6); // only the Safe's uncollected leg remains
    }

    function test_cancelReleasesTheHeldShareToTheCurrentBuyback() public {
        vm.prank(safe);
        sp.proposeBuyback(next);
        ledgerPay(100e6);
        sp.distribute();
        vm.prank(safe);
        sp.cancelBuyback();
        assertEq(usdc.balanceOf(buyback), 40e6);
        assertEq(sp.heldForBuyback(), 0);
    }

    // ---- audit L-5: the Safe collects its 60%; a blocklisted Safe can't stop the buyback ----

    function test_collectSafePaysTheSafeAndZeroes() public {
        ledgerPay(100e6);
        sp.distribute();
        assertEq(sp.collectSafe(), 60e6);
        assertEq(usdc.balanceOf(safe), 60e6);
        assertEq(sp.owedToSafe(), 0);
        assertEq(usdc.balanceOf(address(sp)), 0);
    }

    function test_collectWithNothingOwedIsANoOp() public {
        assertEq(sp.collectSafe(), 0);
    }

    function test_anyoneCanCollectButOnlyTheSafeIsPaid() public {
        ledgerPay(100e6);
        sp.distribute();
        vm.prank(makeAddr("stranger"));
        sp.collectSafe();
        assertEq(usdc.balanceOf(safe), 60e6);
        assertEq(usdc.balanceOf(makeAddr("stranger")), 0);
    }

    function test_owedToSafeIsNeverResplit() public {
        ledgerPay(100e6);
        sp.distribute(); // 40 to the buyback, 60 owed to the Safe
        ledgerPay(10e6);
        (uint256 b, uint256 s) = sp.distribute(); // only the new 10 is split
        assertEq(b, 4e6);
        assertEq(s, 6e6);
        assertEq(sp.owedToSafe(), 66e6);
        assertEq(usdc.balanceOf(buyback), 44e6);
    }

    function test_aBlocklistedSafeDoesNotStopTheBuyback() public {
        BlocklistUSDC bu = new BlocklistUSDC();
        NanoLedger bl = new NanoLedger(IERC20(address(bu)), address(this));
        RegiFeeSplitter s2 = new RegiFeeSplitter(INanoLedgerMinimal(address(bl)), IERC20(address(bu)), safe, buyback);
        bu.setBlocked(safe, true); // Circle blocklists the Safe
        bu.mint(address(this), 100e6);
        bu.approve(address(bl), 100e6);
        bl.depositTo(address(s2), 100e6);
        s2.distribute(); // must not revert
        assertEq(bu.balanceOf(buyback), 40e6, "the buyback still gets its 40%");
        assertEq(s2.owedToSafe(), 60e6);
        vm.expectRevert(bytes("blocklisted"));
        s2.collectSafe(); // only the Safe's own collection fails
        bu.setBlocked(safe, false);
        s2.collectSafe();
        assertEq(bu.balanceOf(safe), 60e6);
    }
}
