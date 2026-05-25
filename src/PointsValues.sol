// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared point award amounts. Imported by RegistraiPoints and all caller
///         contracts so a season rebalance only requires changing this file.
library PointsValues {
    // --- Flat award amounts ---
    uint256 internal constant POINTS_REGISTER            = 1_000;
    uint256 internal constant POINTS_REGISTER_RULE_BONUS =    25;
    uint256 internal constant POINTS_ATTEST              =    50;
    uint256 internal constant POINTS_ATTEST_RULE_BONUS   =    25;
    uint256 internal constant POINTS_CREATE_MARKET       =   200;
    uint256 internal constant POINTS_RESOLVE             =    25;

    // --- Slash amount ---
    uint256 internal constant POINTS_SLASH_PENALTY = 300;

    // --- Trade award config ---
    // 10 pts per USDC (6-decimal), capped at DAILY_TRADE_CAP per wallet per UTC day.
    uint256 internal constant PTS_PER_USDC    = 10;
    uint256 internal constant DAILY_TRADE_CAP = 500;

    // --- Safety cap on awardFlat ---
    uint256 internal constant MAX_FLAT_AWARD = 10_000;
}
