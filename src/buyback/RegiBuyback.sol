// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey, SwapParams, IPoolManagerMinimal, IUnlockCallback, V4Lib} from "./UniswapV4Minimal.sol";
import {INanoLedgerMinimal} from "./INanoLedgerMinimal.sol";

/// @title RegiBuyback. Spends every USDC it holds on REGI and burns it.
/// @notice Anyone may fund it (ERC-20 transfer, native USDC send, or a NanoLedger
///         balance via sweepLedger) and anyone may press burnChunk. Once it holds
///         TRIGGER, a round of CHUNKS_PER_ROUND chunks of CHUNK opens, COOLDOWN apart.
///         Each chunk swaps exact-in USDC for REGI on the Uniswap v4 pool and takes
///         the REGI straight to DEAD. No owner, no roles, no withdraw, no upgrade:
///         USDC leaves only through a swap.
contract RegiBuyback is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant TRIGGER = 200e6;
    uint256 public constant CHUNK = 50e6;
    uint256 public constant CHUNKS_PER_ROUND = 4;
    uint256 public constant COOLDOWN = 10 minutes;
    uint256 public constant MAX_IMPACT_BPS = 200;
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    /// @dev sqrt(1 - MAX_IMPACT_BPS/10000) = sqrt(0.98) ≈ 0.98995: a zeroForOne buy may
    ///      move sqrtPriceX96 down by this factor at most, i.e. the price by ≤ 2%.
    uint256 internal constant SQRT_LIMIT_NUM = 98_995;
    uint256 internal constant SQRT_LIMIT_DEN = 100_000;

    IPoolManagerMinimal public immutable POOL_MANAGER;
    IERC20 public immutable USDC;
    address public immutable REGI;
    address public immutable HOOKS;
    uint24 public immutable FEE;
    int24 public immutable TICK_SPACING;
    INanoLedgerMinimal public immutable LEDGER;

    uint256 public round;
    uint256 public chunksLeft;
    uint256 public nextChunkAt;
    uint256 public totalUsdcSpent;
    uint256 public totalRegiBurned;
    uint256 public totalChunks;

    bool private _swapping;

    event RoundOpened(uint256 indexed round, uint256 balance);
    event Burned(uint256 indexed round, uint256 chunk, uint256 usdcIn, uint256 regiBurned, address indexed caller);
    event LedgerSwept(uint256 amount);

    error NotReady();
    error Cooldown(uint256 readyAt);
    error NotPoolManager();
    error UnexpectedCallback();
    error BadPair();
    error ZeroAddress();
    error NothingBought();
    error Overcharged();
    error SettlementMismatch();

    constructor(
        IPoolManagerMinimal pm,
        IERC20 usdc,
        address regi,
        address hooks,
        uint24 fee,
        int24 tickSpacing,
        INanoLedgerMinimal ledger
    ) {
        if (address(pm) == address(0) || address(usdc) == address(0) || regi == address(0) || address(ledger) == address(0)) {
            revert ZeroAddress();
        }
        // The pool sorts its currencies: USDC must be currency0 so a buy is zeroForOne.
        if (address(usdc) >= regi) revert BadPair();
        POOL_MANAGER = pm;
        USDC = usdc;
        REGI = regi;
        HOOKS = hooks;
        FEE = fee;
        TICK_SPACING = tickSpacing;
        LEDGER = ledger;
    }

    /// @notice Native USDC sends land here; on Arc they are the same balance as the ERC-20.
    receive() external payable {}

    function key() public view returns (PoolKey memory) {
        return PoolKey(address(USDC), REGI, FEE, TICK_SPACING, HOOKS);
    }

    function status()
        external
        view
        returns (
            uint256 balance,
            uint256 chunksLeft_,
            uint256 nextChunkAt_,
            bool ready,
            uint256 totalUsdcSpent_,
            uint256 totalRegiBurned_,
            uint256 totalChunks_
        )
    {
        balance = USDC.balanceOf(address(this));
        ready = block.timestamp >= nextChunkAt && balance > 0 && (chunksLeft > 0 || balance >= TRIGGER);
        return (balance, chunksLeft, nextChunkAt, ready, totalUsdcSpent, totalRegiBurned, totalChunks);
    }

    /// @notice Pull this contract's NanoLedger balance in as USDC. Anyone may call.
    function sweepLedger() external nonReentrant returns (uint256 amount) {
        amount = LEDGER.balanceOf(address(this));
        if (amount == 0) return 0;
        LEDGER.withdraw(amount);
        emit LedgerSwept(amount);
    }

    /// @notice Buy one chunk of REGI and burn it. Anyone may call.
    function burnChunk() external nonReentrant returns (uint256 usdcIn, uint256 regiBurned) {
        uint256 bal = USDC.balanceOf(address(this));
        if (chunksLeft == 0) {
            if (bal < TRIGGER) revert NotReady();
            round += 1;
            chunksLeft = CHUNKS_PER_ROUND;
            emit RoundOpened(round, bal);
        }
        if (block.timestamp < nextChunkAt) revert Cooldown(nextChunkAt);
        uint256 amount = bal < CHUNK ? bal : CHUNK;
        if (amount == 0) revert NotReady();

        // Effects before the swap (checks-effects-interactions); a revert below undoes them.
        uint256 chunk = CHUNKS_PER_ROUND - chunksLeft + 1;
        chunksLeft -= 1;
        nextChunkAt = block.timestamp + COOLDOWN;

        _swapping = true;
        (usdcIn, regiBurned) = abi.decode(POOL_MANAGER.unlock(abi.encode(amount)), (uint256, uint256));
        _swapping = false;
        if (regiBurned == 0) revert NothingBought();

        totalUsdcSpent += usdcIn;
        totalRegiBurned += regiBurned;
        totalChunks += 1;
        emit Burned(round, chunk, usdcIn, regiBurned, msg.sender);
    }

    /// @dev The swap's price limit: at most MAX_IMPACT_BPS below the current price, never
    ///      at or below v4's MIN_SQRT_PRICE (a zeroForOne swap needs limit > MIN_SQRT_PRICE).
    function _priceLimit(uint160 current) internal pure returns (uint160 limit) {
        limit = uint160(uint256(current) * SQRT_LIMIT_NUM / SQRT_LIMIT_DEN);
        if (limit <= MIN_SQRT_PRICE) limit = MIN_SQRT_PRICE + 1;
    }

    /// @dev The PoolManager calls back inside burnChunk's unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (!_swapping) revert UnexpectedCallback();
        uint256 amount = abi.decode(data, (uint256));
        PoolKey memory k = key();
        uint160 limit = _priceLimit(V4Lib.sqrtPriceX96(POOL_MANAGER, V4Lib.poolId(k)));
        int256 delta = POOL_MANAGER.swap(k, SwapParams(true, -int256(amount), limit), "");
        int128 a0 = V4Lib.amount0(delta);
        int128 a1 = V4Lib.amount1(delta);
        // Caller-side delta: USDC owed is negative, REGI received (after the hook's cut)
        // positive. At the limit the swap fills part of the chunk; pay only that.
        uint256 usdcIn = a0 < 0 ? uint256(uint128(-a0)) : 0;
        uint256 regiOut = a1 > 0 ? uint256(uint128(a1)) : 0;
        // Exact-in never owes more than asked; only a hook with beforeSwapReturnsDelta could,
        // and this pool's hook has none. Refuse rather than rely on that.
        if (usdcIn > amount) revert Overcharged();
        if (usdcIn > 0) {
            POOL_MANAGER.sync(address(USDC));
            USDC.safeTransfer(address(POOL_MANAGER), usdcIn);
            if (POOL_MANAGER.settle() != usdcIn) revert SettlementMismatch();
        }
        if (regiOut > 0) POOL_MANAGER.take(REGI, DEAD, regiOut);
        return abi.encode(usdcIn, regiOut);
    }
}
