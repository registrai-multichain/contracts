// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MockPoolManager, MockREGI} from "./MockPoolManager.sol";
import {RegiBuyback} from "../../src/buyback/RegiBuyback.sol";
import {IPoolManagerMinimal} from "../../src/buyback/UniswapV4Minimal.sol";
import {INanoLedgerMinimal} from "../../src/buyback/INanoLedgerMinimal.sol";

contract RegiBuybackTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOOKS = address(0x779A);
    MockUSDC usdc;
    MockREGI regi;
    MockPoolManager pm;
    NanoLedger ledger;
    RegiBuyback bb;
    address alice = makeAddr("alice");

    event Burned(uint256 indexed round, uint256 chunk, uint256 usdcIn, uint256 regiBurned, address indexed caller);

    function setUp() public {
        // Fixed addresses so USDC sorts below REGI, as on mainnet (0x3600… < 0x93D5…).
        deployCodeTo("MockUSDC.sol:MockUSDC", address(0x3600));
        deployCodeTo("MockPoolManager.sol:MockREGI", address(0x93D5));
        usdc = MockUSDC(address(0x3600));
        regi = MockREGI(address(0x93D5));
        pm = new MockPoolManager(IERC20(address(usdc)), regi);
        ledger = new NanoLedger(IERC20(address(usdc)), address(this));
        bb = new RegiBuyback(IPoolManagerMinimal(address(pm)), IERC20(address(usdc)), address(regi), HOOKS, 10_000, 200,
            INanoLedgerMinimal(address(ledger)));
        pm.setPool(bb.key());
        vm.warp(1_800_000_000);
    }

    function fund(uint256 amount) internal {
        usdc.mint(address(bb), amount);
    }

    function test_constructorRejectsUsdcAboveRegi() public {
        vm.expectRevert(RegiBuyback.BadPair.selector);
        new RegiBuyback(IPoolManagerMinimal(address(pm)), IERC20(address(regi)), address(usdc), HOOKS, 10_000, 200,
            INanoLedgerMinimal(address(ledger)));
    }

    function test_triggerBoundary() public {
        fund(200e6 - 1);
        vm.expectRevert(RegiBuyback.NotReady.selector);
        bb.burnChunk();
        fund(1);
        bb.burnChunk();
        assertEq(bb.round(), 1);
        assertEq(bb.chunksLeft(), 3);
    }

    function test_fourChunksTenMinutesApartThenIdle() public {
        fund(200e6);
        uint256 t = 1_800_000_000; // local clock: under via_ir, block.timestamp reads get reused
        for (uint256 i; i < 4; i++) {
            if (i > 0) {
                vm.expectRevert(abi.encodeWithSelector(RegiBuyback.Cooldown.selector, t + 10 minutes));
                bb.burnChunk();
                t += 10 minutes;
                vm.warp(t);
            }
            (uint256 inAmt,) = bb.burnChunk();
            assertEq(inAmt, 50e6);
        }
        assertEq(bb.chunksLeft(), 0);
        assertEq(usdc.balanceOf(address(bb)), 0);
        t += 10 minutes;
        vm.warp(t);
        vm.expectRevert(RegiBuyback.NotReady.selector);
        bb.burnChunk();
    }

    function test_regiGoesStraightToDeadAndTotalsAddUp() public {
        fund(200e6);
        vm.expectEmit(true, true, false, true, address(bb));
        emit Burned(1, 1, 50e6, 50e6 * 8_000e12 * 9_900 / 10_000, alice);
        vm.prank(alice);
        (uint256 inAmt, uint256 burned) = bb.burnChunk();
        assertEq(regi.balanceOf(DEAD), burned);
        assertEq(regi.balanceOf(address(bb)), 0);
        assertEq(bb.totalUsdcSpent(), inAmt);
        assertEq(bb.totalRegiBurned(), burned);
        assertEq(bb.totalChunks(), 1);
    }

    function test_leftoverCarriesToNextRound() public {
        fund(260e6);
        uint256 t = 1_800_000_000;
        for (uint256 i; i < 4; i++) {
            bb.burnChunk();
            t += 10 minutes;
            vm.warp(t);
        }
        assertEq(usdc.balanceOf(address(bb)), 60e6);
        vm.expectRevert(RegiBuyback.NotReady.selector);
        bb.burnChunk();
        fund(140e6); // 200 again: round 2
        bb.burnChunk();
        assertEq(bb.round(), 2);
    }

    function test_midRoundFundingDoesNotLengthenTheRound() public {
        fund(200e6);
        bb.burnChunk();
        fund(500e6);
        uint256 t = 1_800_000_000;
        for (uint256 i; i < 3; i++) {
            t += 10 minutes;
            vm.warp(t);
            bb.burnChunk();
        }
        assertEq(bb.chunksLeft(), 0);
        assertEq(bb.round(), 1);
        t += 10 minutes;
        vm.warp(t);
        bb.burnChunk(); // 500 left >= 200: round 2 opens on the next press
        assertEq(bb.round(), 2);
    }

    function test_swapRevertLeavesStateUntouched() public {
        fund(200e6);
        pm.setRevertSwap(true);
        vm.expectRevert(bytes("pool: swap failed"));
        bb.burnChunk();
        assertEq(bb.round(), 0);
        assertEq(bb.chunksLeft(), 0);
        assertEq(bb.nextChunkAt(), 0);
        assertEq(usdc.balanceOf(address(bb)), 200e6);
    }

    function test_acceptsNativeSends() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(bb).call{value: 1 ether}("");
        assertTrue(ok, "receive()");
    }

    function test_sweepLedgerPullsLedgerBalanceIntoUsdc() public {
        usdc.mint(address(this), 75e6);
        usdc.approve(address(ledger), 75e6);
        ledger.depositTo(address(bb), 75e6);
        assertEq(bb.sweepLedger(), 75e6);
        assertEq(usdc.balanceOf(address(bb)), 75e6);
        assertEq(bb.sweepLedger(), 0); // empty: no revert (NanoLedger.withdraw(0) would)
    }

    function test_statusReadyFlag() public {
        (,,, bool ready,,,) = bb.status();
        assertFalse(ready);
        fund(200e6);
        (uint256 bal,,, bool ready2,,,) = bb.status();
        assertEq(bal, 200e6);
        assertTrue(ready2);
        bb.burnChunk();
        (, uint256 left, uint256 next, bool ready3,,, uint256 chunks) = bb.status();
        assertEq(left, 3);
        assertEq(next, block.timestamp + 10 minutes);
        assertFalse(ready3);
        assertEq(chunks, 1);
        vm.warp(next);
        (,,, bool ready4,,,) = bb.status();
        assertTrue(ready4);
    }

    function test_priceLimitCapsImpactAtTwoPercent() public {
        pm.setSqrtPrice(uint160(79228162514264337593543950336)); // 2**96
        fund(200e6);
        bb.burnChunk();
        uint160 limit = pm.lastParams().sqrtPriceLimitX96;
        assertEq(limit, uint160(uint256(79228162514264337593543950336) * 98_995 / 100_000));
        assertTrue(pm.lastParams().zeroForOne);
        assertEq(pm.lastParams().amountSpecified, -int256(50e6));
        assertEq(pm.lastPoolId(), keccak256(abi.encode(bb.key())));
    }

    function test_partialFillSettlesOnlyWhatWasUsedAndKeepsTheRest() public {
        pm.setFillBps(4_000); // the 2% cap stopped the swap at 40% of the chunk
        fund(200e6);
        (uint256 inAmt, uint256 burned) = bb.burnChunk();
        assertEq(inAmt, 20e6);
        assertEq(usdc.balanceOf(address(bb)), 180e6);
        assertEq(regi.balanceOf(DEAD), burned);
        assertEq(bb.totalUsdcSpent(), 20e6);
    }

    function test_callbackOnlyFromOurUnlock() public {
        vm.expectRevert(RegiBuyback.NotPoolManager.selector);
        bb.unlockCallback(abi.encode(uint256(50e6)));
        vm.prank(address(pm));
        vm.expectRevert(RegiBuyback.UnexpectedCallback.selector);
        bb.unlockCallback(abi.encode(uint256(50e6)));
    }

    function test_limitClampsAboveMinPrice() public {
        pm.setSqrtPrice(4295128740); // just above v4's MIN_SQRT_PRICE
        fund(200e6);
        bb.burnChunk();
        assertEq(pm.lastParams().sqrtPriceLimitX96, uint160(4295128739 + 1)); // clamped to MIN_SQRT_PRICE + 1
    }
}
