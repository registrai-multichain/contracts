// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MedianRule} from "../../src/rules/MedianRule.sol";

contract MedianRuleTest is Test {
    MedianRule rule;

    function setUp() public {
        rule = new MedianRule();
    }

    function _ints(int256[1] memory a) internal pure returns (int256[] memory r) {
        r = new int256[](1);
        r[0] = a[0];
    }

    function test_singleton() public view {
        int256[] memory r = new int256[](1);
        r[0] = 42;
        assertEq(rule.submit(r), 42);
    }

    function test_odd_sorted() public view {
        int256[] memory r = new int256[](5);
        r[0] = 1; r[1] = 2; r[2] = 3; r[3] = 4; r[4] = 5;
        assertEq(rule.submit(r), 3);
    }

    function test_odd_unsorted() public view {
        int256[] memory r = new int256[](5);
        r[0] = 5; r[1] = 1; r[2] = 4; r[3] = 2; r[4] = 3;
        assertEq(rule.submit(r), 3);
    }

    function test_even_lowerMiddle() public view {
        // [1,2,3,4] — both 2 and 3 are middle; rule returns lower (2).
        int256[] memory r = new int256[](4);
        r[0] = 4; r[1] = 1; r[2] = 3; r[3] = 2;
        assertEq(rule.submit(r), 2);
    }

    function test_negativeValues() public view {
        int256[] memory r = new int256[](5);
        r[0] = -10; r[1] = -5; r[2] = 0; r[3] = 5; r[4] = 10;
        assertEq(rule.submit(r), 0);
    }

    function test_duplicates() public view {
        int256[] memory r = new int256[](5);
        r[0] = 100; r[1] = 100; r[2] = 200; r[3] = 100; r[4] = 100;
        assertEq(rule.submit(r), 100);
    }

    function test_empty_reverts() public {
        int256[] memory r = new int256[](0);
        vm.expectRevert(MedianRule.EmptyInput.selector);
        rule.submit(r);
    }

    function test_oversize_reverts() public {
        int256[] memory r = new int256[](129);
        vm.expectRevert(MedianRule.InputTooLarge.selector);
        rule.submit(r);
    }

    function test_maxSize_works() public view {
        int256[] memory r = new int256[](128);
        for (uint256 i = 0; i < 128; ++i) r[i] = int256(i);
        // 128 is even; lower middle of [0..127] is r[63] = 63.
        assertEq(rule.submit(r), 63);
    }

    function testFuzz_invariant_outputIsInInput(int256[] calldata raw) public view {
        // Bound to MAX_INPUT and skip empty.
        vm.assume(raw.length >= 1 && raw.length <= 128);
        int256 m = rule.submit(raw);
        bool found = false;
        for (uint256 i = 0; i < raw.length; ++i) {
            if (raw[i] == m) { found = true; break; }
        }
        assertTrue(found);
    }
}
