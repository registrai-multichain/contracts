// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentRule} from "./IAgentRule.sol";

/// @title MedianRule
/// @notice Returns the median of the input array. For even-length input,
///         the lower of the two middle values is returned (no averaging,
///         to keep the result on the same lattice as the inputs).
///
///         Stateless — one deployed instance can back unlimited agents.
contract MedianRule is IAgentRule {
    error EmptyInput();
    error InputTooLarge();

    /// @dev O(n^2) insertion sort is fine for n ≤ 128 (gas comfortably
    /// under 1M). Larger windows aren't a useful aggregation target.
    uint256 public constant MAX_INPUT = 128;

    function submit(int256[] calldata raw) external pure override returns (int256) {
        uint256 n = raw.length;
        if (n == 0) revert EmptyInput();
        if (n > MAX_INPUT) revert InputTooLarge();

        int256[] memory a = new int256[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = raw[i];
        }
        _insertionSort(a);
        return a[n / 2 - (n % 2 == 0 ? 1 : 0)]; // lower-middle on even n, exact middle on odd n
    }

    function _insertionSort(int256[] memory a) internal pure {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; ++i) {
            int256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = key;
        }
    }
}
