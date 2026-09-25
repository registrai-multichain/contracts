// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";
import {NanoLedger} from "./NanoLedger.sol";
import {BinaryMarket} from "./BinaryMarket.sol";

/// @title MarketsV4. Common binary prediction markets settled entirely on NanoLedger.
/// @notice A BinaryMarket (trading, settlement, void and claims live there).
///         Traders approve MarketsV4 on the ledger (approveSpender) before
///         trading. MarketsV4 needs no ledger role (it creates no fee pools).
///
///         Fees: the 1% trading fee on every buy and sell splits 30% to the
///         market creator and 50% to the Registrai TREASURY (the rounding
///         remainder), paid now, and 20% to the bonded agent, escrowed until the
///         market settles. On void the escrow goes to the successful challenger,
///         else to the treasury, as does a settled market's rounding dust.
///
///         Oracle vetting: only governor-approved agents may settle (as on
///         MarketsPerennial). A permissionless agent could skip its reading on a
///         market it trades and have it void (net-cost refunds): a free option.
///         The feed must also name a governor-approved resolver that is not the
///         agent.
contract MarketsV4 is BinaryMarket {
    /// @notice The treasury leg of each trading fee (the rounding remainder).
    uint256 public constant TREASURY_SHARE_BPS = 5000;

    /// @notice The Registrai treasury: receives the 50% leg. Immutable.
    address public immutable TREASURY;

    struct Market {
        bytes32 feedId;
        address agent;
        int256 threshold;
        Comparator comparator;
        uint256 expiry;
        address creator;
        uint256 yesReserve;
        uint256 noReserve;
        Phase phase;
        bool yesWon;
        uint256 createdAt;
    }

    /// @notice Governor allowlist of bonded agents a market may settle on.
    mapping(address => bool) public approvedAgent;

    event AgentApprovalSet(address indexed agent, bool approved);
    event MarketCreated(bytes32 indexed marketId, address indexed creator, bytes32 indexed feedId, address agent, int256 threshold, Comparator comparator, uint256 expiry, uint256 liquidity);
    event FeesPaid(bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 agentFee);
    event VoidFeesPaid(
        bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 challengerReward, address challenger
    );

    error AgentNotApproved();

    constructor(
        NanoLedger ledger_,
        Registry registry_,
        Attestation attestation_,
        address admin,
        address treasury_,
        uint256 settlementWindow_,
        uint256 resolutionGrace_
    ) BinaryMarket(ledger_, registry_, attestation_, admin, settlementWindow_, resolutionGrace_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        TREASURY = treasury_;
    }

    function createMarket(
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    ) external nonReentrant returns (bytes32 marketId) {
        marketId = _open(feedId, agent, threshold, comparator, expiry, liquidity);
        emit MarketCreated(marketId, msg.sender, feedId, agent, threshold, comparator, expiry, liquidity);
    }

    // ───────────────────────────── hooks ─────────────────────────────

    function _payFeeLegs(bytes32 marketId, uint256 creatorFee, uint256 treasuryFee, uint256 agentFee)
        internal
        override
    {
        _pay(TREASURY, treasuryFee);
        emit FeesPaid(marketId, creatorFee, treasuryFee, agentFee);
    }

    function _voidEscrow(bytes32 marketId, uint256 escrow, address challenger) internal override {
        if (challenger != address(0)) {
            _pay(challenger, escrow);
            emit VoidFeesPaid(marketId, 0, 0, escrow, challenger);
        } else {
            _pay(TREASURY, escrow);
            emit VoidFeesPaid(marketId, 0, escrow, 0, address(0));
        }
    }

    function _sweepDust(uint256 amount) internal override {
        _pay(TREASURY, amount);
    }

    /// @dev Common markets settle only on vetted agents, on top of the resolver rules.
    function _requireApprovedOracle(bytes32 feedId, address agent) internal view override {
        if (!approvedAgent[agent]) revert AgentNotApproved();
        super._requireApprovedOracle(feedId, agent);
    }

    // ──────────────────────────── governor ────────────────────────────

    function setApprovedAgent(address agent, bool approved) external onlyRole(GOVERNOR_ROLE) {
        if (agent == address(0)) revert ZeroAddress();
        approvedAgent[agent] = approved;
        emit AgentApprovalSet(agent, approved);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice True when a market on `feedId` settled by `agent` passes the oracle
    /// rules: the feed exists, the agent is approved and active on it, the feed's
    /// resolver is approved, and the agent is not its own resolver.
    /// (createMarket additionally needs a settleable dispute window.)
    function isApprovedFeed(bytes32 feedId, address agent) external view returns (bool) {
        Registry.Feed memory f = REGISTRY.getFeed(feedId);
        return f.exists && approvedAgent[agent] && REGISTRY.isActiveAgent(feedId, agent) && approvedResolver[f.resolver]
            && f.resolver != agent;
    }

    function getMarket(bytes32 marketId) external view returns (Market memory) {
        Core storage c = _markets[marketId];
        return Market({
            feedId: c.feedId,
            agent: c.agent,
            threshold: c.threshold,
            comparator: c.comparator,
            expiry: c.expiry,
            creator: c.creator,
            yesReserve: c.yesReserve,
            noReserve: c.noReserve,
            phase: c.phase,
            yesWon: c.yesWon,
            createdAt: c.createdAt
        });
    }
}
