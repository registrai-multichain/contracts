// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SuffixJunior ($aiLP) — the junior / first-loss / equity leg.
/// @notice Standard, unhooked ERC-20, 6 dp. Mint/burn restricted to the
///         Treasury. This is the RESIDUAL claim on treasury value above the
///         senior's hard claim: it absorbs losses FIRST (first-loss buffer) and
///         captures the upside (the leveraged/meme leg). It is pre-funded —
///         the Treasury NEVER mints it to defend the senior (the LUNA failure
///         mode is structurally impossible: no such function exists). Treated
///         as a security and ring-fenced at the offering layer (spec §11).
contract SuffixJunior is ERC20 {
    address public immutable treasury;

    error OnlyTreasury();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    constructor(address treasury_) ERC20("Suffix AI (junior)", "aiLP") {
        treasury = treasury_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyTreasury {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyTreasury {
        _burn(from, amount);
    }
}
