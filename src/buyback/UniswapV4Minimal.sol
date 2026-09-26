// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The slice of Uniswap v4 that RegiBuyback uses, vendored so the repo takes
///         no v4-core dependency. ABI-identical to v4-core: `Currency` and `IHooks`
///         are addresses, `BalanceDelta` is an int256 packing amount0 (high 128 bits)
///         and amount1 (low 128 bits). The fork test proves these match the deployed
///         PoolManager on Arc mainnet.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified; // < 0: exact input
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerMinimal {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

library V4Lib {
    /// @dev v4-core StateLibrary.POOLS_SLOT.
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    function poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /// @dev slot0's sqrtPriceX96 (low 160 bits of the pool's first slot).
    function sqrtPriceX96(IPoolManagerMinimal pm, bytes32 id) internal view returns (uint160) {
        return uint160(uint256(pm.extsload(keccak256(abi.encode(id, POOLS_SLOT)))));
    }

    function amount0(int256 delta) internal pure returns (int128) {
        return int128(delta >> 128);
    }

    function amount1(int256 delta) internal pure returns (int128) {
        return int128(delta);
    }
}
