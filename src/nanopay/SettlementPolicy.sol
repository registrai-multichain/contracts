// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";

/// @title SettlementPolicy. When an agent-settled market may resolve or void.
/// @notice Shared by every market that settles on a bonded agent's attestation.
///
/// A market settles on the FIRST non-invalidated attestation stamped in
/// [expiry, expiry + SETTLEMENT_WINDOW]. Trading closes at expiry, so the value
/// that decides the market is never public while anyone can still trade on it.
/// (Reading the latest attestation at or before expiry — the previous rule —
/// forced the agent to publish the answer while the market was open.)
///
/// Every market reaches a terminal state that anyone can trigger:
///
///   now < expiry                                 Open        still trading
///   valid attestation in window, finalized       Resolvable  -> resolve
///   window still open                            Waiting     agent may still attest
///   window closed, nothing in it                 Voidable    nothing can ever fill it:
///                                                            a later tx is stamped later
///   window closed, one found but not finalized   Waiting until the hard deadline
///                                                (a dispute may still decide it),
///                                                then Voidable
///
/// The hard deadline exists because Dispute has no timeout: a challenge that its
/// resolver never settles would otherwise hold a market open forever.
abstract contract SettlementPolicy {
    enum Settlement {
        Open,
        Waiting,
        Resolvable,
        Voidable
    }

    uint256 public constant MIN_SETTLEMENT_WINDOW = 1 hours;
    uint256 public constant MAX_SETTLEMENT_WINDOW = 7 days;
    uint256 public constant MIN_RESOLUTION_GRACE = 1 days;
    uint256 public constant MAX_RESOLUTION_GRACE = 30 days;

    /// @notice How long after expiry the agent has to attest the settling value.
    uint256 public immutable SETTLEMENT_WINDOW;
    /// @notice How long after the window a disputed reading may take to settle
    /// before the market is voided instead.
    uint256 public immutable RESOLUTION_GRACE;

    error BadSettlementParams();
    error FeedUnsettleable();
    error SettlementPending();
    error NotVoidable();

    constructor(uint256 settlementWindow_, uint256 resolutionGrace_) {
        if (
            settlementWindow_ < MIN_SETTLEMENT_WINDOW || settlementWindow_ > MAX_SETTLEMENT_WINDOW
                || resolutionGrace_ < MIN_RESOLUTION_GRACE || resolutionGrace_ > MAX_RESOLUTION_GRACE
        ) revert BadSettlementParams();
        SETTLEMENT_WINDOW = settlementWindow_;
        RESOLUTION_GRACE = resolutionGrace_;
    }

    /// @dev Refuse, at creation, a feed whose markets could not reach a terminal
    /// state honestly. An attestation landing at the very end of the window
    /// finalizes one dispute window later; if that is not before the hard
    /// deadline, an honest agent could be voided out of its own fee.
    function _requireSettleableFeed(Registry registry, bytes32 feedId) internal view {
        if (registry.getFeed(feedId).disputeWindow >= RESOLUTION_GRACE) revert FeedUnsettleable();
    }

    function _settlement(Attestation attestation, bytes32 feedId, address agent, uint256 expiry)
        internal
        view
        returns (Settlement state, int256 value)
    {
        if (block.timestamp < expiry) return (Settlement.Open, 0);
        uint256 close = expiry + SETTLEMENT_WINDOW;
        (bool found, int256 v,, bool finalized) = attestation.firstInWindow(feedId, agent, expiry, close);
        if (found && finalized) return (Settlement.Resolvable, v);
        if (block.timestamp <= close) return (Settlement.Waiting, 0);
        if (!found) return (Settlement.Voidable, 0);
        if (block.timestamp > close + RESOLUTION_GRACE) return (Settlement.Voidable, 0);
        return (Settlement.Waiting, 0);
    }
}
