// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentRule} from "./IAgentRule.sol";

/// @title TrimmedMeanRule
/// @notice Sorts inputs, drops `trimBps / 10000` of the values from each
///         tail, and returns the integer mean of the remaining middle.
///         Standard robust estimator — same shape as the off-chain
///         `trimByPercentile` helper in the agent SDK, but verifiable
///         bytecode.
///
///         Constructor binds the trim fraction at deploy time. To use a
///         different trim, deploy another instance and register agents
///         against that one — agents get the immutability guarantee for
///         free.
///
///         Example: TrimmedMeanRule(1000) = 10% trim from each tail.
contract TrimmedMeanRule is IAgentRule {
    error EmptyInput();
    error InputTooLarge();
    error TrimTooLarge();
    error BadTrim();

    uint256 public constant MAX_INPUT = 128;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Basis points trimmed from each tail.
    uint16 public immutable TRIM_BPS;

    constructor(uint16 trimBps_) {
        // Trim ≥ 5000 bps from each tail would discard everything.
        if (trimBps_ >= 5000) revert BadTrim();
        TRIM_BPS = trimBps_;
    }

    function submit(int256[] calldata raw) external view override returns (int256) {
        uint256 n = raw.length;
        if (n == 0) revert EmptyInput();
        if (n > MAX_INPUT) revert InputTooLarge();

        uint256 trimPerTail = (n * TRIM_BPS) / BPS_DENOMINATOR;
        if (2 * trimPerTail >= n) revert TrimTooLarge();

        int256[] memory a = new int256[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = raw[i];
        }
        _insertionSort(a);

        uint256 lo = trimPerTail;
        uint256 hi = n - trimPerTail;
        int256 sum = 0;
        for (uint256 i = lo; i < hi; ++i) {
            sum += a[i];
        }
        return sum / int256(hi - lo);
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
