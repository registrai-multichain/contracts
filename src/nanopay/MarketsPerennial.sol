// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";
import {NanoLedger} from "./NanoLedger.sol";
import {BuilderRegistry} from "../perennial/BuilderRegistry.sol";
import {BuilderFund} from "../perennial/BuilderFund.sol";
import {BinaryMarket} from "./BinaryMarket.sol";
import {VerifiedBuilderBadge} from "../perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../perennial/WonderEscrow.sol";
import {SourceKey} from "../perennial/SourceKey.sol";

/// @title MarketsPerennial. Builder-milestone prediction markets whose fees pay
///        the builder they are about.
/// @notice A BinaryMarket (trading, settlement, void and claims live there) whose
///         markets each have a subject: a verified builder (`createMarket`, the
///         builder must hold a live VerifiedBuilderBadge) or a nominated, not yet
///         claimed project source (`createWonderMarket`, a "wonder market").
///
///         Fees: the 1% trading fee on every buy and sell splits 30% to whoever
///         opened the market (paid now), 20% to the bonded agent (escrowed until
///         the market settles) and 50% to the market's subject (BUILDER_SHARE_BPS,
///         the rounding remainder), paid now. The builder leg goes to the subject
///         only when the operator (FEED_ROLE) had bound the market's feed to that
///         subject when the market was created: a builder market's to the
///         BuilderFund (`FUND`, that builder's income for the current epoch, taxed
///         progressively when claimed), a wonder market's to the WonderEscrow
///         (`ESCROW`, held for the project's team). Any other market's builder leg
///         goes to the SeasonPool.
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
    /// @notice Builder markets need a live badge from this contract.
    VerifiedBuilderBadge public immutable BADGE;
    /// @notice Holds the builder leg of bound wonder markets for the project's team.
    WonderEscrow public immutable ESCROW;

    /// @notice Binds feeds to subjects (the operator).
    bytes32 public constant FEED_ROLE = keccak256("FEED_ROLE");
    /// @notice Nominates sources for wonder markets (the Safe and the onboarder).
    bytes32 public constant NOMINATOR_ROLE = keccak256("NOMINATOR_ROLE");

    enum SubjectKind {
        None,
        Builder,
        Wonder
    }

    /// @notice What a market (or a feed binding) is about: a builder id, or a
    /// source key (SourceKey.keyOf) for a wonder market.
    struct Subject {
        SubjectKind kind;
        uint256 builderId;
        bytes32 sourceKey;
    }

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
    /// @notice Source keys open for new wonder markets.
    mapping(bytes32 => bool) public nominated;
    mapping(bytes32 => Subject) internal _feedSubject;
    mapping(bytes32 => Subject) internal _subjectOf; // marketId => subject
    mapping(bytes32 => bool) internal _bound; // marketId => feed bound to its subject at creation

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
    event Nominated(bytes32 indexed key, string source, bool on);
    event FeedSubjectSet(bytes32 indexed feedId, SubjectKind kind, uint256 builderId, bytes32 sourceKey);
    event WonderMarketCreated(
        bytes32 indexed marketId,
        bytes32 indexed sourceKey,
        address indexed creator,
        string source,
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry
    );
    /// @notice At creation: whether the market's feed was bound to its subject.
    event MarketBound(bytes32 indexed marketId, bool bound);

    error BuilderInactive();
    error AgentNotApproved();
    error FundMismatch();
    error BadgeNotLive();
    error NotNominated();

    constructor(
        NanoLedger ledger_,
        Registry registry_,
        Attestation attestation_,
        BuilderRegistry builders_,
        address admin,
        BuilderFund fund_,
        uint256 settlementWindow_,
        uint256 resolutionGrace_,
        VerifiedBuilderBadge badge_,
        WonderEscrow escrow_
    ) BinaryMarket(ledger_, registry_, attestation_, admin, settlementWindow_, resolutionGrace_) {
        if (address(builders_) == address(0) || address(fund_) == address(0)) revert ZeroAddress();
        // The fund must pay on the same ledger and the same builder ids.
        if (address(fund_.LEDGER()) != address(ledger_) || address(fund_.BUILDERS()) != address(builders_)) {
            revert FundMismatch();
        }
        if (address(badge_) == address(0) || address(escrow_) == address(0)) revert ZeroAddress();
        if (address(badge_.BUILDERS()) != address(builders_) || address(escrow_.FUND()) != address(fund_)) {
            revert FundMismatch();
        }
        BUILDERS = builders_;
        FUND = fund_;
        BADGE = badge_;
        ESCROW = escrow_;
        _grantRole(FEED_ROLE, admin);
        _grantRole(NOMINATOR_ROLE, admin);
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
        uint256 serial = BADGE.serialOf(builderId);
        if (serial == 0 || BADGE.isLapsed(serial)) revert BadgeNotLive();
        marketId = _open(feedId, agent, threshold, comparator, expiry, liquidity);
        _builderIdOf[marketId] = builderId;
        bool bound = _bind(marketId, feedId, Subject(SubjectKind.Builder, builderId, bytes32(0)));
        emit MarketCreated(marketId, builderId, msg.sender, feedId, agent, threshold, comparator, expiry);
        emit MarketBound(marketId, bound);
    }

    /// @notice A market about a nominated project that has not claimed a builder
    /// yet. `source` is canonical (`github:owner/repo` or `domain:host`).
    function createWonderMarket(
        string calldata source,
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    ) external nonReentrant returns (bytes32 marketId) {
        bytes32 key = SourceKey.keyOf(source);
        if (!nominated[key]) revert NotNominated();
        marketId = _open(feedId, agent, threshold, comparator, expiry, liquidity);
        bool bound = _bind(marketId, feedId, Subject(SubjectKind.Wonder, 0, key));
        emit WonderMarketCreated(marketId, key, msg.sender, source, feedId, agent, threshold, comparator, expiry);
        emit MarketBound(marketId, bound);
    }

    /// @dev Record the market's subject and freeze whether its feed is bound to it.
    function _bind(bytes32 marketId, bytes32 feedId, Subject memory s) internal returns (bool bound) {
        _subjectOf[marketId] = s;
        Subject storage f = _feedSubject[feedId];
        bound = f.kind != SubjectKind.None && f.kind == s.kind && f.builderId == s.builderId
            && f.sourceKey == s.sourceKey;
        _bound[marketId] = bound;
    }

    // ───────────────────────────── hooks ─────────────────────────────

    function _payFeeLegs(bytes32 marketId, uint256 creatorFee, uint256 builderFee, uint256 agentFee)
        internal
        override
    {
        if (builderFee > 0) {
            if (!_bound[marketId]) {
                _toSeasonPool(builderFee);
            } else if (_subjectOf[marketId].kind == SubjectKind.Wonder) {
                _pay(address(ESCROW), builderFee);
                ESCROW.credit(_subjectOf[marketId].sourceKey, builderFee);
            } else {
                _pay(address(FUND), builderFee);
                FUND.credit(_builderIdOf[marketId], builderFee);
            }
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

    // ───────────────────────── subjects (roles) ─────────────────────────

    /// @notice Open (or close) `source` for new wonder markets. Closing never
    /// touches existing markets or the escrow. Only invited sources are
    /// nominated; a team that opts out is un-nominated.
    function nominate(string calldata source, bool on) external onlyRole(NOMINATOR_ROLE) {
        bytes32 key = SourceKey.keyOf(source);
        nominated[key] = on;
        emit Nominated(key, source, on);
    }

    /// @notice Bind `feedId` to a subject (kind None unbinds). Applies to markets
    /// created afterwards; existing markets keep what they were created with.
    function setFeedSubject(bytes32 feedId, Subject calldata s) external onlyRole(FEED_ROLE) {
        _feedSubject[feedId] = s;
        emit FeedSubjectSet(feedId, s.kind, s.builderId, s.sourceKey);
    }

    // ───────────────────────────── views ─────────────────────────────

    function feedSubjectOf(bytes32 feedId) external view returns (Subject memory) {
        return _feedSubject[feedId];
    }

    /// @notice The market's subject, and whether its builder leg goes to it
    /// (true) or to the SeasonPool (false).
    function subjectOf(bytes32 marketId) external view returns (Subject memory s, bool bound) {
        return (_subjectOf[marketId], _bound[marketId]);
    }

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
