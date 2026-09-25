// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// ERC-4626 test vault: `accrue` adds yield, `lose` burns assets, `setFrozen`
/// makes withdrawals revert (illiquid / paused venue), `setBroken` makes every
/// asset read and withdrawal revert.
contract MockVault is ERC4626 {
    bool public frozen;
    bool public broken;

    constructor(IERC20 usdc) ERC20("Mock Vault USDC", "mvUSDC") ERC4626(usdc) {}

    function accrue(uint256 amount) external {
        IMintable(asset()).mint(address(this), amount);
    }

    function lose(uint256 amount) external {
        IERC20(asset()).transfer(address(0xdead), amount);
    }

    function setFrozen(bool f) external {
        frozen = f;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function totalAssets() public view override returns (uint256) {
        require(!broken, "broken");
        return super.totalAssets();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        require(!frozen && !broken, "frozen");
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}

/// Like a Morpho / MetaMorpho USDC vault: 18-decimal shares over 6-decimal
/// USDC (decimals offset 12), so exact-asset withdrawals leave share dust.
contract OffsetMockVault is MockVault {
    constructor(IERC20 usdc) MockVault(usdc) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }
}
