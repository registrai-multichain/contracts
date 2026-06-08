// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SuffixTreasury} from "../src/suffix/SuffixTreasury.sol";
import {SuffixSenior} from "../src/suffix/SuffixSenior.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// Competitive Dutch-auction MM: sell newly-minted senior above par into froth,
/// bank the premium as revenue, keep auction inventory out of the claim.
contract SuffixAuctionTest is Test {
    MockUSDC usdc;
    SuffixTreasury t;
    SuffixSenior senior;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        t = new SuffixTreasury(usdc, owner);
        senior = t.senior();
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    function _seedSenior(address who, uint256 amt) internal {
        vm.startPrank(who);
        usdc.approve(address(t), amt);
        t.seedSenior(amt);
        vm.stopPrank();
    }

    function test_auctionSellsAbovePar_banksPremium() public {
        _seedSenior(alice, 1_000e6);                  // floorPar 1.0, claim 1000
        t.openDutchAuction(500e6, 1.5e6, 1.0e6, 1 hours);

        // inventory excluded from claim
        assertEq(senior.totalSupply(), 1_500e6);
        assertEq(t.externalSeniorSupply(), 1_000e6);
        assertEq(t.seniorClaimUSDC(), 1_000e6);
        assertEq(t.dutchPrice(), 1.5e6);              // t0 = start price

        uint256 reserveBefore = t.totalUSDC();
        vm.startPrank(bob);
        usdc.approve(address(t), 300e6);
        uint256 got = t.takeDutch(200e6, 1.5e6);      // 200 @ 1.5 = 300 USDC
        vm.stopPrank();

        assertEq(got, 200e6);
        assertEq(senior.balanceOf(bob), 200e6);
        assertEq(t.externalSeniorSupply(), 1_200e6);  // bob's 200 now a claim
        assertEq(t.totalUSDC(), reserveBefore + 200e6); // par portion backs it
        assertEq(t.feesBankUsdc(), 100e6);            // premium (0.5×200) → revenue
    }

    function test_dutchPriceDeclines() public {
        _seedSenior(alice, 1_000e6);
        t.openDutchAuction(500e6, 1.5e6, 1.0e6, 1 hours);
        vm.warp(block.timestamp + 30 minutes);
        assertApproxEqAbs(t.dutchPrice(), 1.25e6, 1e3); // halfway → 1.25
        vm.warp(block.timestamp + 1 hours);
        assertEq(t.dutchPrice(), 1.0e6);                // past end → floor price
    }

    function test_takeRespectsMaxPrice() public {
        _seedSenior(alice, 1_000e6);
        t.openDutchAuction(500e6, 1.5e6, 1.0e6, 1 hours);
        vm.startPrank(bob);
        usdc.approve(address(t), 1_000e6);
        vm.expectRevert(SuffixTreasury.SlippageExceeded.selector);
        t.takeDutch(100e6, 1.2e6);                     // current 1.5 > max 1.2
        vm.stopPrank();
    }

    function test_closeBurnsUnsold() public {
        _seedSenior(alice, 1_000e6);
        t.openDutchAuction(500e6, 1.5e6, 1.0e6, 1 hours);
        vm.startPrank(bob);
        usdc.approve(address(t), 300e6);
        t.takeDutch(200e6, 1.5e6);                     // 200 sold, 300 unsold
        vm.stopPrank();

        t.closeDutchAuction();
        assertEq(senior.totalSupply(), 1_200e6);       // 300 unsold burned
        (, , , , , bool active) = t.auction();
        assertFalse(active);
        assertEq(t.externalSeniorSupply(), 1_200e6);
    }

    function test_openRejectsFloorBelowPar() public {
        _seedSenior(alice, 1_000e6);                   // floorPar 1.0
        vm.expectRevert(SuffixTreasury.BadAuctionParams.selector);
        t.openDutchAuction(500e6, 1.5e6, 0.9e6, 1 hours); // floor < par
    }

    function test_openOnlyGovernor() public {
        bytes32 gov = t.GOVERNOR_ROLE();
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, gov)
        );
        t.openDutchAuction(500e6, 1.5e6, 1.0e6, 1 hours);
    }

    function test_auctionRespectsSeniorCap() public {
        _seedSenior(alice, 1_000e6);
        t.setSeniorCap(1_100e6);                        // only 100 more external allowed
        t.openDutchAuction(500e6, 1.5e6, 1.0e6, 1 hours);
        vm.startPrank(bob);
        usdc.approve(address(t), 1_000e6);
        vm.expectRevert(SuffixTreasury.SeniorCapExceeded.selector);
        t.takeDutch(200e6, 1.5e6);                       // would push external to 1200 > cap
        // exactly to the cap is fine
        t.takeDutch(100e6, 1.5e6);
        vm.stopPrank();
        assertEq(t.externalSeniorSupply(), 1_100e6);
    }
}
