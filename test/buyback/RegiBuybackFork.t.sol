// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, IPoolManagerMinimal, V4Lib} from "../../src/buyback/UniswapV4Minimal.sol";

/// Runs only on a fork of Arc mainnet:
///   forge test --match-path test/buyback/RegiBuybackFork.t.sol --fork-url arc_mainnet -vv
contract RegiBuybackForkTest is Test {
    IPoolManagerMinimal constant PM = IPoolManagerMinimal(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IERC20 constant USDC = IERC20(0x3600000000000000000000000000000000000000);
    address constant REGI = 0x93D5b8c53ee763C2c4522bF0d958ce51Af4360ae;
    address constant HOOKS = 0x779A7F22480db20eD3Ed2BB7950B207Ce71Ae044;
    bytes32 constant POOL_ID = 0x0530f18eb32d732cc8b067bbd0b2ba7e5d807d4f5cf4f7d74429f2a78d3120c8;

    function setUp() public {
        if (block.chainid != 5042) vm.skip(true);
    }

    function key() internal pure returns (PoolKey memory) {
        return PoolKey(address(USDC), REGI, 10_000, 200, HOOKS);
    }

    function testFork_poolKeyHashesToThePoolAndSlot0IsReadable() public view {
        assertEq(V4Lib.poolId(key()), POOL_ID, "pool key");
        uint160 p = V4Lib.sqrtPriceX96(PM, POOL_ID);
        assertGt(p, 0, "slot0 empty: POOLS_SLOT or pool id wrong");
    }

    /// The spike: can a test address hold Arc USDC on a fork? Native USDC and the
    /// ERC-20 at 0x3600 are one balance on Arc; the ERC-20 may read it through a
    /// chain precompile a local fork cannot run.
    function testFork_aTestAddressCanHoldUsdc() public {
        address who = makeAddr("funded");
        vm.deal(who, 300 ether); // 300 USDC in 18-decimal native units
        uint256 viaNative = USDC.balanceOf(who);
        emit log_named_uint("USDC.balanceOf after vm.deal(300e18)", viaNative);
        if (viaNative < 300e6) {
            deal(address(USDC), who, 300e6); // stdStorage: works only if the ERC-20 keeps its own balances
        }
        assertGe(USDC.balanceOf(who), 300e6, "cannot fund USDC on a fork");
    }
}
