// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Attestation} from "./Attestation.sol";
import {IBTCPriceOracle} from "./CirqueLending.sol";

/// @title AttestedBTCOracle
/// @notice Adapter that exposes Registrai's bonded-agent attestation layer
/// as an `IBTCPriceOracle` for CirqueLending consumption.
///
/// Dogfood story: Registrai's lending product reads BTC prices from
/// Registrai's own oracle protocol. The agent that attests the price has
/// posted a slashable USDC bond on Registry v2; anyone who spots a bad
/// attestation can dispute it within the feed's dispute window and slash
/// the agent.
///
/// Reads return the most recent non-pending, non-invalidated attestation.
/// This includes both `None` (no dispute opened) and `ResolvedValid`
/// (dispute resolved in agent's favor). It explicitly excludes `Pending`
/// (open dispute, could flip) and `ResolvedInvalid` (bad data).
///
/// The Attestation.AttestationData.timestamp is returned as `updatedAt`,
/// so CirqueLending's `MAX_ORACLE_STALENESS` check operates on the actual
/// time the price was witnessed (not the time the dispute window closed).
contract AttestedBTCOracle is IBTCPriceOracle {
    Attestation public immutable ATTESTATION;
    bytes32 public immutable FEED_ID;
    address public immutable AGENT;

    /// @notice How deep to walk history when looking for a valid attestation.
    /// Bounds gas in pathological cases (long history of disputes). In
    /// normal operation the latest attestation is the answer in one step.
    uint256 public constant MAX_LOOKBACK = 16;

    error NoValidAttestation();
    error NegativePrice();

    constructor(Attestation attestation, bytes32 feedId, address agent) {
        ATTESTATION = attestation;
        FEED_ID = feedId;
        AGENT = agent;
    }

    /// @inheritdoc IBTCPriceOracle
    function getBTCPrice()
        external
        view
        returns (uint256 priceUSDC18, uint256 updatedAt)
    {
        uint256 len = ATTESTATION.historyLength(FEED_ID, AGENT);
        if (len == 0) revert NoValidAttestation();

        uint256 lookback = len > MAX_LOOKBACK ? MAX_LOOKBACK : len;
        for (uint256 i = 0; i < lookback; i++) {
            bytes32 id = ATTESTATION.historyAt(FEED_ID, AGENT, len - 1 - i);
            Attestation.AttestationData memory att =
                ATTESTATION.getAttestation(id);

            // Skip pending disputes (could flip to invalid) and resolved-invalid.
            // Accept None (default, never disputed) and ResolvedValid.
            if (
                att.status == Attestation.DisputeStatus.Pending ||
                att.status == Attestation.DisputeStatus.ResolvedInvalid
            ) {
                continue;
            }

            if (att.value <= 0) revert NegativePrice();
            return (uint256(att.value), att.timestamp);
        }
        revert NoValidAttestation();
    }
}
