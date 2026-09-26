// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INanoLedgerMinimal} from "./INanoLedgerMinimal.sol";

/// @title RegiFeeSplitter. The Registrai treasury address on mainnet.
/// @notice MarketsV4's TREASURY (fee leg, void escrow, dust arrive as NanoLedger
///         balance). distribute() withdraws that balance and splits ALL the USDC this
///         contract holds: BUYBACK_BPS (40%, immutable) to the buyback, the rest to the
///         Safe. Anyone may call it. The one mutable thing is where the 40% goes: the
///         Safe may repoint it, public for REPOINT_DELAY before it lands.
contract RegiFeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BUYBACK_BPS = 4000;
    uint256 public constant REPOINT_DELAY = 7 days;

    INanoLedgerMinimal public immutable LEDGER;
    IERC20 public immutable USDC;
    address public immutable SAFE;

    address public buyback;
    address public pendingBuyback;
    uint256 public pendingSince;

    event Distributed(uint256 toBuyback, uint256 toSafe);
    event BuybackProposed(address indexed next, uint256 activeAt);
    event BuybackChanged(address indexed previous, address indexed next);
    event BuybackProposalCancelled(address indexed next);

    error NotSafe();
    error ZeroAddress();
    error NoPending();
    error TooEarly(uint256 at);

    constructor(INanoLedgerMinimal ledger, IERC20 usdc, address safe, address buyback_) {
        if (address(ledger) == address(0) || address(usdc) == address(0) || safe == address(0) || buyback_ == address(0)) {
            revert ZeroAddress();
        }
        LEDGER = ledger;
        USDC = usdc;
        SAFE = safe;
        buyback = buyback_;
    }

    receive() external payable {}

    modifier onlySafe() {
        if (msg.sender != SAFE) revert NotSafe();
        _;
    }

    function distribute() external nonReentrant returns (uint256 toBuyback, uint256 toSafe) {
        uint256 onLedger = LEDGER.balanceOf(address(this));
        if (onLedger > 0) LEDGER.withdraw(onLedger);
        uint256 bal = USDC.balanceOf(address(this));
        if (bal == 0) return (0, 0);
        toBuyback = bal * BUYBACK_BPS / 10_000;
        toSafe = bal - toBuyback;
        if (toBuyback > 0) USDC.safeTransfer(buyback, toBuyback);
        USDC.safeTransfer(SAFE, toSafe);
        emit Distributed(toBuyback, toSafe);
    }

    function proposeBuyback(address next) external onlySafe {
        if (next == address(0)) revert ZeroAddress();
        pendingBuyback = next;
        pendingSince = block.timestamp;
        emit BuybackProposed(next, block.timestamp + REPOINT_DELAY);
    }

    function acceptBuyback() external onlySafe {
        address next = pendingBuyback;
        if (next == address(0)) revert NoPending();
        uint256 at = pendingSince + REPOINT_DELAY;
        if (block.timestamp < at) revert TooEarly(at);
        emit BuybackChanged(buyback, next);
        buyback = next;
        pendingBuyback = address(0);
        pendingSince = 0;
    }

    function cancelBuyback() external onlySafe {
        address next = pendingBuyback;
        if (next == address(0)) revert NoPending();
        pendingBuyback = address(0);
        pendingSince = 0;
        emit BuybackProposalCancelled(next);
    }
}
