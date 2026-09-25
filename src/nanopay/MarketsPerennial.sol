// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";
import {NanoLedger} from "./NanoLedger.sol";
import {BuilderRegistry} from "../perennial/BuilderRegistry.sol";
import {BuilderFund} from "../perennial/BuilderFund.sol";
import {BinaryMarket} from "./BinaryMarket.sol";

/// @title MarketsPerennial. Builder-milestone prediction markets whose fees pay
///        the builder they are about.
/// @notice A BinaryMarket (trading, settlement, void and claims live there) whose
///         markets are each tagged to a `builderId`.
///
///         Fees: the 1% trading fee on every buy and sell splits 30% to whoever
///         opened the market (paid now), 20% to the bonded agent (escrowed until
///         the market settles) and 50% to the builder the market is about
///         (BUILDER_SHARE_BPS, the rounding remainder): paid now into the
///         BuilderFund (`FUND`) and credited as that builder's income for the
///         current epoch; the fund taxes it progressively per epoch (the tax
///         feeds the SeasonPool) when the builder claims.
///
///         Void: the escrow goes to the challenger who got the agent's reading
///         ruled Invalid, else to the SeasonPool (through the fund), as does a
///         settled market's rounding dust.
///
///         Oracle vetting: only governor-approved agents may settle, and the
///         feed must name a governor-approved resolver that is not the agent.
contract MarketsPerennial is BinaryMarket {
    /// @notice The builder leg of each trading fee (the rounding remainder).
    uint256 public constant BUILDER_SHARE_BPS = 5000;

    BuilderRegistry public immutable BUILDERS;
    /// @notice The BuilderFund: receives the builder leg (credited per builder
    /// and epoch) and forwards void escrows and dust to the SeasonPool. Immutable.
    BuilderFund public immutable FUND;

    struct Market {
        bytes32 feedId;
        address agent;
        int256 threshold;
        Comparator comparator;
        uint256 expiry;
        address creator;
        uint256 builderId;
        uint256 yesReserve;
        uint256 noReserve;
        Phase phase;
        bool yesWon;
        uint256 createdAt;
    }

    mapping(bytes32 => uint256) internal _builderIdOf;

    /// @notice Governor allowlist of bonded agents a market may settle on.
    mapping(address => bool) public approvedAgent;

    event MarketCreated(
        bytes32 indexed marketId,
        uint256 indexed builderId,
        address indexed creator,
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry
    );
    /// @notice Every trade: creator paid, builder credited, agent escrowed.
    event FeesPaid(bytes32 indexed marketId, uint256 creatorFee, uint256 builderFee, uint256 agentFee);
    /// @notice At void: the agent escrow went to the challenger, else to the
    /// SeasonPool (`seasonPoolAmount`). `creatorFee` is always 0 (kept for the
    /// event's ABI shape).
    event VoidFeesPaid(
        bytes32 indexed marketId,
        uint256 creatorFee,
        uint256 seasonPoolAmount,
        uint256 challengerReward,
        address challenger
    );
    event AgentApprovalSet(address indexed agent, bool approved);

    error BuilderInactive();
    error AgentNotApproved();
    error FundMismatch();

    constructor(
        NanoLedger ledger_,
        Registry registry_,
        Attestation attestation_,
        BuilderRegistry builders_,
        address admin,
        BuilderFund fund_,
        uint256 settlementWindow_,
        uint256 resolutionGrace_
    ) BinaryMarket(ledger_, registry_, attestation_, admin, settlementWindow_, resolutionGrace_) {
        if (address(builders_) == address(0) || address(fund_) == address(0)) revert ZeroAddress();
        // The fund must pay on the same ledger and the same builder ids.
        if (address(fund_.LEDGER()) != address(ledger_) || address(fund_.BUILDERS()) != address(builders_)) {
            revert FundMismatch();
        }
        BUILDERS = builders_;
        FUND = fund_;
    }

    function createMarket(
        uint256 builderId,
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    ) external nonReentrant returns (bytes32 marketId) {
        if (!BUILDERS.isActiveBuilderId(builderId)) revert BuilderInactive();
        marketId = _open(feedId, agent, threshold, comparator, expiry, liquidity);
        _builderIdOf[marketId] = builderId;
        emit MarketCreated(marketId, builderId, msg.sender, feedId, agent, threshold, comparator, expiry);
    }

    // ───────────────────────────── hooks ─────────────────────────────

    function _payFeeLegs(bytes32 marketId, uint256 creatorFee, uint256 builderFee, uint256 agentFee)
        internal
        override
    {
        if (builderFee > 0) {
            _pay(address(FUND), builderFee);
            FUND.credit(_builderIdOf[marketId], builderFee);
        }
        emit FeesPaid(marketId, creatorFee, builderFee, agentFee);
    }

    function _voidEscrow(bytes32 marketId, uint256 escrow, address challenger) internal override {
        if (challenger != address(0)) {
            _pay(challenger, escrow);
            emit VoidFeesPaid(marketId, 0, 0, escrow, challenger);
        } else {
            _toSeasonPool(escrow);
            emit VoidFeesPaid(marketId, 0, escrow, 0, address(0));
        }
    }

    function _sweepDust(uint256 amount) internal override {
        _toSeasonPool(amount);
    }

    function _toSeasonPool(uint256 amount) internal {
        if (amount == 0) return;
        _pay(address(FUND), amount);
        FUND.creditSeason(amount);
    }

    /// @dev Perennial settles only on vetted agents, on top of the resolver rules.
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
    /// allowlist: the feed exists, the agent is approved, and the feed's resolver
    /// is approved. (createMarket additionally needs the agent registered and
    /// active on the feed, a settleable dispute window, and an active builder.)
    function isApprovedFeed(bytes32 feedId, address agent) external view returns (bool) {
        Registry.Feed memory f = REGISTRY.getFeed(feedId);
        return f.exists && approvedAgent[agent] && approvedResolver[f.resolver] && f.resolver != agent;
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
            builderId: _builderIdOf[marketId],
            yesReserve: c.yesReserve,
            noReserve: c.noReserve,
            phase: c.phase,
            yesWon: c.yesWon,
            createdAt: c.createdAt
        });
    }
}
