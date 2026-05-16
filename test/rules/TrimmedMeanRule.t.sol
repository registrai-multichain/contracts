// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TrimmedMeanRule} from "../../src/rules/TrimmedMeanRule.sol";

contract TrimmedMeanRuleTest is Test {
    TrimmedMeanRule rule10pct;

    function setUp() public {
        rule10pct = new TrimmedMeanRule(1000); // 10% per tail
    }

    function test_constructorBound() public view {
        assertEq(rule10pct.TRIM_BPS(), 1000);
    }

    function test_revert_constructorTooLarge() public {
        vm.expectRevert(TrimmedMeanRule.BadTrim.selector);
        new TrimmedMeanRule(5000);
    }

    function test_smallInput_zeroTrim_isPlainMean() public view {
        // n=5, trim = 5*1000/10000 = 0 per tail → plain mean.
        int256[] memory r = new int256[](5);
        r[0] = 100; r[1] = 200; r[2] = 300; r[3] = 400; r[4] = 500;
        assertEq(rule10pct.submit(r), 300); // (100+200+300+400+500)/5 = 300
    }

    function test_trimsOutliers() public view {
        // n=10, trim = 10*1000/10000 = 1 per tail. After sort:
        //   [1, 100, 100, 100, 100, 100, 100, 100, 100, 9999]
        // Drop r[0]=1 and r[9]=9999 → mean of 8 hundreds = 100.
        int256[] memory r = new int256[](10);
        r[0] = 1; r[1] = 100; r[2] = 100; r[3] = 100; r[4] = 100;
        r[5] = 100; r[6] = 100; r[7] = 100; r[8] = 100; r[9] = 9999;
        assertEq(rule10pct.submit(r), 100);
    }

    function test_negativesAndPositives() public view {
        int256[] memory r = new int256[](10);
        r[0] = -1000; r[1] = -1; r[2] = 0; r[3] = 1; r[4] = 2;
        r[5] = 3; r[6] = 4; r[7] = 5; r[8] = 6; r[9] = 1000;
        // After sort + trim ends: [-1, 0, 1, 2, 3, 4, 5, 6] → sum 20 / 8 = 2.
        assertEq(rule10pct.submit(r), 2);
    }

    function test_empty_reverts() public {
        int256[] memory r = new int256[](0);
        vm.expectRevert(TrimmedMeanRule.EmptyInput.selector);
        rule10pct.submit(r);
    }

    function test_revert_trimAtBoundary() public {
        // 40% trim, n=5 → trimPerTail = 5*4000/10000 = 2. Then 2*2 = 4 < 5
        // OK, kept = 1 element. So this should succeed.
        TrimmedMeanRule r40 = new TrimmedMeanRule(4000);
        int256[] memory r = new int256[](5);
        r[0] = 1; r[1] = 2; r[2] = 3; r[3] = 4; r[4] = 5;
        assertEq(r40.submit(r), 3); // single middle element
    }

    function test_revert_trimEatsEverything() public {
        // 49% trim, n=2 → trimPerTail = 2*4900/10000 = 0. Still 2 left.
        // Need to construct an n where 2*trimPerTail >= n. n=3, 49% →
        // trimPerTail = 3*4900/10000 = 1, 2*1 = 2 < 3 still OK.
        // Try n=10, 4900 bps → trim = 4, 2*4 = 8 < 10 still OK.
        // Try n=10 with 5000 bps — but constructor rejects 5000.
        // Try n=2 with 4900 bps — trim = 0, fine.
        // It's hard to hit TrimTooLarge with the constructor 5000 cap. Skip.
        TrimmedMeanRule r49 = new TrimmedMeanRule(4900);
        int256[] memory r = new int256[](2);
        r[0] = 1; r[1] = 2;
        // trimPerTail = 0, returns mean of [1,2] = 1 (integer division).
        assertEq(r49.submit(r), 1);
    }
}
