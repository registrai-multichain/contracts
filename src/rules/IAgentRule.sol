// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentRule
/// @notice Pure-ish aggregation primitive for Registrai oracle agents.
///         A rule contract turns a list of raw inputs (e.g. scraped
///         listing prices, sampled rates, observed values) into the single
///         scalar the agent attests onchain. Once an agent is registered
///         against a rule contract, the Attestation contract enforces:
///
///           Attested.value == rule.submit(rawInputs)
///
///         The methodology hash, by convention, equals the rule contract's
///         bytecode hash — so the "what the agent does with raw data" is
///         verifiable bytecode, not a markdown document.
///
///         Implementations should be view (no state writes) and bounded in
///         gas — caller validates input length elsewhere; this interface
///         does not constrain it.
interface IAgentRule {
    function submit(int256[] calldata raw) external view returns (int256 value);
}
