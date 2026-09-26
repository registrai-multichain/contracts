// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// A 6-decimal USDC that, like Circle's, can blocklist an address: any transfer to or from
/// it reverts. Used to prove a blocklisted Safe can't stop the buyback (audit L-5).
contract BlocklistUSDC is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blocklist USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blocklisted");
        super._update(from, to, value);
    }
}
