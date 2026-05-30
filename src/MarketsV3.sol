// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Markets} from "./Markets.sol";
import {Attestation} from "./Attestation.sol";
import {Registry} from "./Registry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MarketsV3
/// @notice Markets v2 + a minimal share-transfer primitive so YES/NO positions
///         can be used as collateral by other protocols (e.g. CirqueBetLending,
///         which lends against a held prediction-market position).
///
/// v2 markets are non-transferable (`yesBalance`/`noBalance` are pure
/// `[marketId][msg.sender]` ledgers). v3 adds an ERC-20-allowance-style
/// operator model: a holder approves an operator once, the operator then
/// pulls shares into itself as collateral. Everything else — pricing,
/// fees, resolution, redeem, LP — is inherited unchanged from Markets.
///
/// This is a SIBLING deployment, not a migration. The 12 live v2 markets
/// keep running on the v2 Markets contract; bet-collateral lending operates
/// against markets created on v3.
contract MarketsV3 is Markets {
    /// @notice holder => operator => approved. An approved operator can move
    /// the holder's YES/NO shares via transferSharesFrom (collateral pull).
    mapping(address => mapping(address => bool)) public shareOperatorApproved;

    event ShareOperatorSet(address indexed holder, address indexed operator, bool approved);
    event SharesTransferred(
        bytes32 indexed marketId,
        Outcome outcome,
        address indexed from,
        address indexed to,
        uint256 amount
    );

    error NotShareOperator();
    error InsufficientShareBalance();
    error SelfTransfer();

    constructor(
        Attestation attestation_,
        Registry registry_,
        IERC20 usdc_,
        address treasury_
    ) Markets(attestation_, registry_, usdc_, treasury_) {}

    /// @notice Approve (or revoke) an operator to move your YES/NO shares.
    /// Mirrors ERC-20 approve semantics: a single standing approval, not
    /// per-amount. Revoke by passing `approved=false`.
    ///
    /// ⚠️ SCOPE: this approval is UNLIMITED and ALL-MARKETS — an approved
    /// operator can move any amount of any of your YES/NO balances across
    /// every market, until you revoke. Only approve contracts you trust as
    /// custodians (e.g. an audited lending contract). A future revision may
    /// add per-market / per-amount scoped allowances.
    function setShareOperator(address operator, bool approved) external {
        shareOperatorApproved[msg.sender][operator] = approved;
        emit ShareOperatorSet(msg.sender, operator, approved);
    }

    /// @notice Move `amount` of `from`'s shares for (marketId, outcome) to `to`.
    /// Caller must be `from` itself OR an operator `from` approved. Used by a
    /// lending contract to pull a borrower's position in as collateral, and
    /// to push it back on repay.
    ///
    /// Pure ledger move — does not touch reserves, fees, or market lifecycle,
    /// so it's valid in any market phase (a resolved winning position is still
    /// transferable, then redeemable by the new holder).
    function transferSharesFrom(
        bytes32 marketId,
        Outcome outcome,
        address from,
        address to,
        uint256 amount
    ) external nonReentrant {
        if (msg.sender != from && !shareOperatorApproved[from][msg.sender]) {
            revert NotShareOperator();
        }
        if (to == from) revert SelfTransfer();
        if (amount == 0) revert AmountTooLow();
        if (_markets[marketId].createdAt == 0) revert MarketMissing();

        if (outcome == Outcome.Yes) {
            if (yesBalance[marketId][from] < amount) revert InsufficientShareBalance();
            yesBalance[marketId][from] -= amount;
            yesBalance[marketId][to] += amount;
        } else {
            if (noBalance[marketId][from] < amount) revert InsufficientShareBalance();
            noBalance[marketId][from] -= amount;
            noBalance[marketId][to] += amount;
        }

        emit SharesTransferred(marketId, outcome, from, to, amount);
    }
}
