// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, IUnlockCallback, V4Lib} from "../../../src/buyback/UniswapV4Minimal.sol";

/// TESTNET REHEARSAL ONLY. A stand-in for REGI on Arc testnet (REGI and its pool exist only
/// on mainnet). Anyone can mint: it is worthless by design.
contract RehearsalREGI is ERC20 {
    constructor() ERC20("Registrai Rehearsal", "tREGI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface IPoolManagerLiquidity {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
}

/// TESTNET REHEARSAL ONLY. Adds liquidity to a v4 pool and pays what the PoolManager says
/// is owed, with the same sync / transfer / settle pattern RegiBuyback uses.
contract RehearsalLiquidity is IUnlockCallback {
    IPoolManagerLiquidity public immutable PM;

    constructor(IPoolManagerLiquidity pm) {
        PM = pm;
    }

    function add(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidity) external {
        PM.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "pm only");
        (PoolKey memory key, int24 lo, int24 hi, int256 liq) = abi.decode(data, (PoolKey, int24, int24, int256));
        (int256 delta,) = PM.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, liq, bytes32(0)), "");
        _pay(key.currency0, V4Lib.amount0(delta));
        _pay(key.currency1, V4Lib.amount1(delta));
        return "";
    }

    function _pay(address currency, int128 d) internal {
        if (d >= 0) return;
        PM.sync(currency);
        require(IERC20(currency).transfer(address(PM), uint256(uint128(-d))), "pay");
        PM.settle();
    }
}
