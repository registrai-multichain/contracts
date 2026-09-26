// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The two NanoLedger calls the buyback and the splitter make.
interface INanoLedgerMinimal {
    function balanceOf(address account) external view returns (uint256);
    function withdraw(uint256 amount) external;
}
