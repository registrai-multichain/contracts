// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SuffixTreasury} from "../src/suffix/SuffixTreasury.sol";
import {SuffixSenior} from "../src/suffix/SuffixSenior.sol";
import {SuffixJunior} from "../src/suffix/SuffixJunior.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract SuffixTreasuryTest is Test {
    MockUSDC usdc;
    SuffixTreasury t;
    SuffixSenior senior;
    SuffixJunior junior;

    address owner = address(this);
    address alice = makeAddr("alice"); // senior buyer (wants the floor)
    address dora = makeAddr("dora");   // junior buyer (wants the upside)

    function setUp() public {
        usdc = new MockUSDC();
        t = new SuffixTreasury(usdc, owner, "Suffix AI", "ai");
        senior = t.senior();
        junior = t.junior();
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(dora, 1_000_000e6);
        usdc.mint(owner, 1_000_000e6);
    }

    function _seedSenior(address who, uint256 amt) internal returns (uint256 minted) {
        vm.startPrank(who);
        usdc.approve(address(t), amt);
        minted = t.seedSenior(amt);
        vm.stopPrank();
    }

    function _seedJunior(address who, uint256 amt) internal returns (uint256 minted) {
        vm.startPrank(who);
        usdc.approve(address(t), amt);
        minted = t.seedJunior(amt);
        vm.stopPrank();
    }

    // ── basic floor: senior buys at par, exits at k×par (the 10% gap) ──
    function test_seniorBuysAtParExitsAtFloor() public {
        uint256 sh = _seedSenior(alice, 1_000e6);
        assertEq(sh, 1_000e6);                       // 1:1 at par
        assertEq(t.seniorFloorPrice(), 0.9e6);       // 0.9 USDC
        _seedJunior(dora, 500e6);                    // cushion so reserve covers it

        vm.prank(alice);
        uint256 out = t.redeemSeniorAtFloor(1_000e6);
        assertEq(out, 900e6);                         // floor payout
        assertEq(senior.balanceOf(alice), 0);
    }

    // ── junior absorbs losses FIRST; senior floor intact ──
    function test_juniorAbsorbsLossFirst() public {
        _seedSenior(alice, 1_000e6);   // claim 1000
        _seedJunior(dora, 500e6);      // juniorEquity 500, 500 jr tokens @ par
        assertEq(t.juniorEquityUSDC(), 500e6);
        assertTrue(t.seniorSolvent());

        t.applyLoss(300e6);            // loss < junior equity

        assertEq(t.juniorEquityUSDC(), 200e6);        // junior ate it
        assertTrue(t.seniorSolvent());                // senior untouched
        assertEq(t.seniorFloorPrice(), 0.9e6);        // floor unchanged
        assertApproxEqAbs(t.juniorNAVPerToken(), 0.4e6, 1); // 200/500
        // senior can still exit at floor
        vm.prank(alice);
        assertEq(t.redeemSeniorAtFloor(100e6), 90e6);
    }

    // ── senior impaired ONLY after junior is wiped; NO junior minted (anti-LUNA) ──
    function test_seniorImpairedOnlyAfterJuniorWiped() public {
        _seedSenior(alice, 1_000e6);
        _seedJunior(dora, 500e6);      // total 1500, claim 1000, cushion 500
        uint256 jrSupplyBefore = junior.totalSupply();

        t.applyLoss(700e6);            // total 800 < claim 1000

        assertEq(t.juniorEquityUSDC(), 0);            // junior wiped
        assertEq(t.juniorNAVPerToken(), 0);
        assertFalse(t.seniorSolvent());               // senior now under-backed

        // The floor cannot be fully honored: a full redeem reverts rather than
        // minting junior to cover it.
        vm.prank(alice);
        vm.expectRevert(SuffixTreasury.InsufficientReserve.selector);
        t.redeemSeniorAtFloor(1_000e6); // would need 900, only 800 in reserve

        // A partial redeem within reserve still works (first-come).
        vm.prank(alice);
        assertEq(t.redeemSeniorAtFloor(800e6), 720e6);

        // ANTI-LUNA: junior supply never increased to defend the senior.
        assertEq(junior.totalSupply(), jrSupplyBefore);
    }

    // ── realized revenue ratchets the senior floor up ──
    function test_revenueRatchetsFloor() public {
        _seedSenior(alice, 1_000e6);   // 1000 tokens, par 1.0
        usdc.approve(address(t), 100e6);
        t.recordRevenue(100e6, t.BPS()); // 100% to senior ratchet

        assertEq(t.floorPar(), 1.1e6);                // par 1.0 → 1.1
        assertEq(t.seniorFloorPrice(), 0.99e6);       // 0.9 × 1.1
        assertEq(t.seniorClaimUSDC(), 1_100e6);       // claim rose with par
        assertEq(t.juniorEquityUSDC(), 0);            // all revenue went to senior
    }

    function test_revenueSplitSeniorJunior() public {
        _seedSenior(alice, 1_000e6);
        _seedJunior(dora, 500e6);      // jr equity 500, 500 tokens
        usdc.approve(address(t), 200e6);
        t.recordRevenue(200e6, 5_000); // half ratchets floor, half to junior

        assertEq(t.floorPar(), 1.1e6); // 100/1000 ratchet
        // total 1700, claim 1100 → junior equity 600 → NAV 600/500 = 1.2
        assertEq(t.juniorEquityUSDC(), 600e6);
        assertApproxEqAbs(t.juniorNAVPerToken(), 1.2e6, 1);
    }

    // ── junior captures upside: redeem above what was paid in ──
    function test_juniorUpsideOnRevenue() public {
        _seedSenior(alice, 1_000e6);
        uint256 jr = _seedJunior(dora, 500e6); // 500 tokens
        usdc.approve(address(t), 200e6);
        t.recordRevenue(200e6, 0);             // all to junior

        // junior equity 700 over 500 tokens → 1.4 each
        vm.prank(dora);
        uint256 out = t.redeemJunior(jr);
        assertEq(out, 700e6);                  // paid 500, got 700 (+40%)
    }

    // ── tokens carry the deploy-time name/symbol (multi-suffix ready) ──
    function test_tokenNamingPerSuffix() public {
        assertEq(senior.symbol(), "ai");
        assertEq(junior.symbol(), "aiLP");
        assertEq(senior.name(), "Suffix AI (senior)");
        assertEq(junior.name(), "Suffix AI (junior)");
        assertEq(senior.decimals(), 6);

        // a second suffix deploys with its own ticker — no code change
        SuffixTreasury xyz = new SuffixTreasury(usdc, owner, "Suffix XYZ", "xyz");
        assertEq(xyz.senior().symbol(), "xyz");
        assertEq(xyz.junior().symbol(), "xyzLP");
        assertEq(xyz.senior().name(), "Suffix XYZ (senior)");
    }

    // ── only the treasury can mint/burn the tokens ──
    function test_onlyTreasuryMints() public {
        vm.expectRevert(SuffixSenior.OnlyTreasury.selector);
        senior.mint(alice, 1e6);
        vm.expectRevert(SuffixJunior.OnlyTreasury.selector);
        junior.mint(dora, 1e6);
    }

    // ── FIX-1 (review CRITICAL): orphaned residual at junior-supply-0 cannot be
    //    captured by the next junior buyer; it must be swept to the floor first ──
    function test_fix1_orphanedResidualBlockedThenSwept() public {
        _seedSenior(alice, 1_000e6);
        _seedJunior(dora, 500e6);
        vm.prank(dora);
        t.redeemJunior(500e6);                       // junior supply → 0, equity 0
        assertEq(junior.totalSupply(), 0);
        assertEq(t.juniorEquityUSDC(), 0);

        // Book revenue to the junior side while no junior exists → orphaned residual.
        usdc.approve(address(t), 100e6);
        t.recordRevenue(100e6, 0);                   // 0 bps to senior → all residual
        assertEq(t.juniorEquityUSDC(), 100e6);       // ownerless surplus

        // A new junior buyer CANNOT seed in and capture it.
        vm.startPrank(dora);
        usdc.approve(address(t), 1_000e6);
        vm.expectRevert(SuffixTreasury.OrphanedResidual.selector);
        t.seedJunior(1_000e6);
        vm.stopPrank();

        // Sweep routes the orphaned residual into the senior floor.
        uint256 parBefore = t.floorPar();
        t.sweepResidualToFloor();
        assertEq(t.juniorEquityUSDC(), 0);
        assertGt(t.floorPar(), parBefore);

        // Now seeding works again, at par — no free residual to capture.
        _seedJunior(dora, 1_000e6);
        assertApproxEqAbs(t.juniorNAVPerToken(), 1e6, 2);
    }

    // ── FIX-2 (review HIGH): the first-loss buffer can't be voluntarily stripped
    //    below minCushionBps ──
    function test_fix2_bufferStripBlocked() public {
        _seedSenior(alice, 1_000e6);
        _seedJunior(dora, 500e6);     // cushion 5000 bps
        t.setMinCushion(2_500);       // lock 25% of senior claim as buffer

        // Full strip would drop cushion to 0 → blocked.
        vm.startPrank(dora);
        vm.expectRevert(SuffixTreasury.BufferLocked.selector);
        t.redeemJunior(500e6);
        vm.stopPrank();

        // Partial down to exactly the floor is allowed; one wei more is not.
        vm.prank(dora);
        t.redeemJunior(250e6);
        assertEq(t.cushionBps(), 2_500);
        vm.prank(dora);
        vm.expectRevert(SuffixTreasury.BufferLocked.selector);
        t.redeemJunior(1e6);
    }

    function test_setMinCushion_onlyGovernor() public {
        bytes32 gov = t.GOVERNOR_ROLE(); // read before the prank (it's a call too)
        vm.prank(alice); // alice has no role
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                gov
            )
        );
        t.setMinCushion(2_500);
    }

    // ── SENIOR_CAP: bounded senior float (hybrid supply model) ──
    function test_seniorCapEnforced() public {
        t.setSeniorCap(1_000e6); // governor (this) sets cap
        _seedSenior(alice, 800e6); // ok, external 800
        // next seed would push external senior past 1000 → revert
        vm.startPrank(alice);
        usdc.approve(address(t), 300e6);
        vm.expectRevert(SuffixTreasury.SeniorCapExceeded.selector);
        t.seedSenior(300e6);
        vm.stopPrank();
        // exactly to the cap is allowed
        _seedSenior(alice, 200e6);
        assertEq(t.externalSeniorSupply(), 1_000e6);
    }

    // ── internal accounting tracks balance (donation-proof) ──
    function test_totalUSDCMatchesBalance() public {
        _seedSenior(alice, 1_000e6);
        _seedJunior(dora, 500e6);
        // a stray donation must not change accounting
        usdc.mint(address(this), 999e6);
        usdc.transfer(address(t), 999e6);
        assertEq(t.totalUSDC(), 1_500e6);
        assertLe(t.totalUSDC(), usdc.balanceOf(address(t)));
    }
}
