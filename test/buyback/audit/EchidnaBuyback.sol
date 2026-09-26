// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {MockPoolManager, MockREGI} from "../MockPoolManager.sol";
import {RegiBuyback} from "../../../src/buyback/RegiBuyback.sol";
import {RegiFeeSplitter} from "../../../src/buyback/RegiFeeSplitter.sol";
import {IPoolManagerMinimal} from "../../../src/buyback/UniswapV4Minimal.sol";
import {INanoLedgerMinimal} from "../../../src/buyback/INanoLedgerMinimal.sol";
import {BuybackHandler} from "./BuybackInvariant.t.sol";

/// Echidna harness over the same handler and properties as the Foundry invariants:
///   echidna test/buyback/audit/EchidnaBuyback.sol --contract EchidnaBuyback --config test/buyback/audit/echidna.yaml
contract EchidnaBuyback {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    BuybackHandler public h;
    MockUSDC usdc;
    MockREGI regi;
    MockPoolManager pm;
    RegiBuyback bb;
    RegiBuyback bb2;
    RegiFeeSplitter sp;
    address safe = address(0x5AFE);

    constructor() {
        usdc = new MockUSDC();
        regi = new MockREGI();
        // RegiBuyback needs USDC to sort below REGI (as on mainnet): redeploy until it does.
        for (uint256 i; i < 16 && address(regi) < address(usdc); i++) regi = new MockREGI();
        require(address(usdc) < address(regi), "ordering");
        pm = new MockPoolManager(IERC20(address(usdc)), regi);
        NanoLedger ledger = new NanoLedger(IERC20(address(usdc)), address(this));
        bb = new RegiBuyback(IPoolManagerMinimal(address(pm)), IERC20(address(usdc)), address(regi), address(0x779A), 10_000, 200,
            INanoLedgerMinimal(address(ledger)));
        bb2 = new RegiBuyback(IPoolManagerMinimal(address(pm)), IERC20(address(usdc)), address(regi), address(0x779A), 10_000, 200,
            INanoLedgerMinimal(address(ledger)));
        pm.setPool(bb.key());
        sp = new RegiFeeSplitter(INanoLedgerMinimal(address(ledger)), IERC20(address(usdc)), safe, address(bb));
        h = new BuybackHandler(usdc, regi, pm, ledger, bb, bb2, sp, safe);
    }

    // ---- actions (forwarded to the handler) ----
    function fundDirect(uint256 a, bool s) external { h.fundDirect(a, s); }
    function payBuybackOnLedger(uint256 a) external { h.payBuybackOnLedger(a); }
    function sweep() external { h.sweep(); }
    function payTreasury(uint256 a, bool l) external { h.payTreasury(a, l); }
    function distribute() external { h.distribute(); }
    function burn(bool s) external { h.burn(s); }
    function warp(uint256 s) external { h.warp(s); }
    function warpLong(uint256 s) external { h.warpLong(s); }
    function setFill(uint256 b) external { h.setFill(b); }
    function setPrice(uint256 p) external { h.setPrice(p); }
    function propose(bool s) external { h.propose(s); }
    function accept() external { h.accept(); }
    function cancel() external { h.cancel(); }
    function attack(uint256 w) external { h.attack(w); }

    // ---- properties ----
    function echidna_no_violation() external view returns (bool) {
        return bytes(h.violation()).length == 0;
    }

    function echidna_buybacks_never_hold_regi() external view returns (bool) {
        return regi.balanceOf(address(bb)) == 0 && regi.balanceOf(address(bb2)) == 0;
    }

    function echidna_dead_holds_exactly_the_burns() external view returns (bool) {
        return regi.balanceOf(DEAD) == bb.totalRegiBurned() + bb2.totalRegiBurned();
    }

    function echidna_pool_got_exactly_the_spend() external view returns (bool) {
        return usdc.balanceOf(address(pm)) == bb.totalUsdcSpent() + bb2.totalUsdcSpent();
    }

    function echidna_held_only_while_pending() external view returns (bool) {
        return (sp.pendingBuyback() != address(0) || sp.heldForBuyback() == 0) && sp.heldForBuyback() <= usdc.balanceOf(address(sp));
    }

    function echidna_safe_gets_exactly_60() external view returns (bool) {
        return usdc.balanceOf(safe) == h.ghostSplitTotal() - h.ghostBuybackShare();
    }

    function echidna_rounds_sane() external view returns (bool) {
        return bb.chunksLeft() <= 4 && bb2.chunksLeft() <= 4 && (bb.chunksLeft() == 0 || bb.round() > 0);
    }
}
