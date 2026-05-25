// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRegistraiPoints {
    function awardFlat(address user, uint256 amount, bytes32 reason) external;
    function awardTrade(address user, uint256 usdcAmount) external;
    function slashPoints(address user, uint256 amount) external;
}
