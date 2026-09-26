// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MockPoolManager, MockREGI} from "./MockPoolManager.sol";
import {RegiBuyback} from "../../src/buyback/RegiBuyback.sol";
import {RegiFeeSplitter} from "../../src/buyback/RegiFeeSplitter.sol";
import {IPoolManagerMinimal} from "../../src/buyback/UniswapV4Minimal.sol";
import {INanoLedgerMinimal} from "../../src/buyback/INanoLedgerMinimal.sol";

/// Market fees (ledger balance on the splitter) -> distribute -> 40% to the buyback ->
/// a full round burns exactly that USDC's worth of REGI to dead.
contract BuybackFlowTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function test_marketFeesBecomeBurnedRegi() public {
        deployCodeTo("MockUSDC.sol:MockUSDC", address(0x3600));
        deployCodeTo("MockPoolManager.sol:MockREGI", address(0x93D5));
        MockUSDC usdc = MockUSDC(address(0x3600));
        MockREGI regi = MockREGI(address(0x93D5));
        MockPoolManager pm = new MockPoolManager(IERC20(address(usdc)), regi);
        NanoLedger ledger = new NanoLedger(IERC20(address(usdc)), address(this));
        RegiBuyback bb = new RegiBuyback(IPoolManagerMinimal(address(pm)), IERC20(address(usdc)), address(regi),
            address(0x779A), 10_000, 200, INanoLedgerMinimal(address(ledger)));
        pm.setPool(bb.key());
        address safe = makeAddr("safe");
        RegiFeeSplitter sp = new RegiFeeSplitter(INanoLedgerMinimal(address(ledger)), IERC20(address(usdc)), safe, address(bb));
        vm.warp(1_800_000_000);

        // $500 of treasury income arrives as ledger balance, like MarketsV4 pays it.
        usdc.mint(address(this), 500e6);
        usdc.approve(address(ledger), 500e6);
        ledger.depositTo(address(sp), 500e6);
        sp.distribute();
        assertEq(usdc.balanceOf(address(bb)), 200e6); // 40%
        assertEq(usdc.balanceOf(safe), 300e6); // 60%

        uint256 t = 1_800_000_000; // local clock (via_ir reuses block.timestamp reads)
        for (uint256 i; i < 4; i++) {
            bb.burnChunk();
            t += 10 minutes;
            vm.warp(t);
        }
        assertEq(usdc.balanceOf(address(bb)), 0);
        assertEq(bb.totalUsdcSpent(), 200e6);
        assertEq(regi.balanceOf(DEAD), bb.totalRegiBurned());
        assertGt(bb.totalRegiBurned(), 0);
    }
}
