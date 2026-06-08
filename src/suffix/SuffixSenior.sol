// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SuffixSenior ($ai) — the senior, cash-floored leg of the Suffix Pool.
/// @notice Standard, unhooked ERC-20 (no transfer tax — see spec §3.6). 6 dp to
///         settle 1:1 with USDC. Mint/burn is restricted to the Treasury, which
///         is the sole issuer/buyback agent. This token carries a buyback FLOOR
///         (k × floorPar, defended by the treasury reserve + junior buffer) but
///         NO redemption right beyond the treasury's policy — it is the "boring"
///         leg a holder buys for the floor, not the upside.
contract SuffixSenior is ERC20 {
    address public immutable treasury;

    error OnlyTreasury();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    constructor(address treasury_) ERC20("Suffix AI (senior)", "ai") {
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
