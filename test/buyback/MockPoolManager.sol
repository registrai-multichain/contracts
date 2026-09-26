// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, SwapParams, IUnlockCallback, V4Lib} from "../../src/buyback/UniswapV4Minimal.sol";

contract MockREGI is ERC20 {
    constructor() ERC20("Registrai", "REGI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// A PoolManager that behaves like v4 for one exact-input zeroForOne swap:
/// unlock -> callback -> swap returns a caller-side BalanceDelta -> sync/settle pays
/// currency0 -> take mints currency1 out. It asserts every delta is settled, as v4 does.
/// A 1% "hook cut" comes off the REGI output, like the Argus hook.
contract MockPoolManager {
    IERC20 public immutable usdc;
    MockREGI public immutable regi;

    uint160 public sqrtPrice = uint160(1 << 96);
    uint256 public fillBps = 10_000; // share of the requested input the pool fills
    uint256 public regiPerUsdc = 8_000e12; // REGI (18 dp) per 1 USDC unit (6 dp): 8,000 REGI per USDC
    uint256 public constant HOOK_CUT_BPS = 100;
    bool public revertSwap;

    SwapParams internal _last;
    bytes32 public lastPoolId;
    bool public unlocked;
    uint256 internal synced;
    uint256 internal owed0;
    uint256 internal owed1;

    constructor(IERC20 usdc_, MockREGI regi_) {
        usdc = usdc_;
        regi = regi_;
    }

    function setSqrtPrice(uint160 p) external { sqrtPrice = p; }
    function setFillBps(uint256 b) external { fillBps = b; }
    function setRevertSwap(bool r) external { revertSwap = r; }
    function setRegiPerUsdc(uint256 r) external { regiPerUsdc = r; }
    function lastParams() external view returns (SwapParams memory) { return _last; }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(owed0 == 0 && owed1 == 0, "CurrencyNotSettled");
        unlocked = false;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256) {
        require(unlocked, "ManagerLocked");
        if (revertSwap) revert("pool: swap failed");
        lastPoolId = V4Lib.poolId(key);
        _last = params;
        require(params.zeroForOne && params.amountSpecified < 0, "mock: exact-in zeroForOne only");
        uint256 inAmt = uint256(-params.amountSpecified) * fillBps / 10_000;
        uint256 out = inAmt * regiPerUsdc;
        out -= out * HOOK_CUT_BPS / 10_000;
        owed0 += inAmt;
        owed1 += out;
        return (int256(-int128(int256(inAmt))) << 128) | int256(uint256(uint128(out)));
    }

    function sync(address currency) external {
        require(currency == address(usdc), "mock: sync usdc only");
        synced = usdc.balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = usdc.balanceOf(address(this)) - synced;
        owed0 -= paid;
    }

    function take(address currency, address to, uint256 amount) external {
        require(currency == address(regi), "mock: take regi only");
        owed1 -= amount;
        regi.mint(to, amount);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        // Answers only the slot0 of the pool the test configured; anything else reads 0.
        return slot == _slot0Slot ? bytes32(uint256(sqrtPrice)) : bytes32(0);
    }

    bytes32 internal _slot0Slot;

    function setPool(PoolKey memory key) external {
        _slot0Slot = keccak256(abi.encode(V4Lib.poolId(key), V4Lib.POOLS_SLOT));
    }
}
