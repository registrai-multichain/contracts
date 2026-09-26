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
///         Sessions (one-signature trading): an owner lets a delegate key, e.g.
///         a key the app keeps in the browser, trade for it until an expiry and
///         within a spend cap: buyFor / sellFor / redeemFor move the OWNER's
///         ledger balance and positions, never the delegate's. Positions,
///         proceeds and payouts stay the owner's. A delegate sells only in
///         markets it bought into for that owner, so a leaked delegate key can at
///         worst trade the capped amount badly until the session expires or is
///         revoked; the owner's other positions are out of its reach. The owner
///         still approves this contract on the ledger (the ledger allowance caps
///         the delegate as well).
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

    /// @notice Longest session an owner can grant.
    uint256 public constant MAX_SESSION = 7 days;

    struct Session {
        /// Collateral the delegate may still spend on buys for the owner.
        uint128 spendLeft;
        /// The delegate may act for the owner while block.timestamp < expiry.
        uint64 expiry;
    }

    /// @notice owner => delegate => session.
    mapping(address => mapping(address => Session)) public sessions;

    /// @notice owner => delegate => market => the delegate bought into it for the
    /// owner (only there may it sell for the owner).
    mapping(address => mapping(address => mapping(bytes32 => bool))) public sessionMarket;

    event AgentApprovalSet(address indexed agent, bool approved);
    event MarketCreated(bytes32 indexed marketId, address indexed creator, bytes32 indexed feedId, address agent, int256 threshold, Comparator comparator, uint256 expiry, uint256 liquidity);
    event FeesPaid(bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 agentFee);
    event VoidFeesPaid(
        bytes32 indexed marketId, uint256 creatorFee, uint256 commonsFee, uint256 challengerReward, address challenger
    );

    event SessionSet(address indexed owner, address indexed delegate, uint256 spendCap, uint256 expiry);

    error AgentNotApproved();
    error SessionInvalid();
    error SessionSpendExceeded();
    error SessionMarketNotAllowed();
    error GasForwardFailed();

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

    // ─────────────────────────── sessions ───────────────────────────

    /// @notice Let `delegate` trade for you until `expiry` (at most MAX_SESSION
    /// ahead), spending at most `spendCap` of your ledger balance on buys. Replaces
    /// any session with that delegate. Native value sent along is forwarded to the
    /// delegate as its gas money (on Arc, gas is USDC).
    function setSession(address delegate, uint128 spendCap, uint64 expiry) external payable nonReentrant {
        if (delegate == address(0) || delegate == msg.sender) revert ZeroAddress();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_SESSION) revert SessionInvalid();
        sessions[msg.sender][delegate] = Session({spendLeft: spendCap, expiry: expiry});
        emit SessionSet(msg.sender, delegate, spendCap, expiry);
        if (msg.value > 0) {
            (bool ok,) = payable(delegate).call{value: msg.value}("");
            if (!ok) revert GasForwardFailed();
        }
    }

    /// @notice End a delegate's session now.
    function revokeSession(address delegate) external {
        delete sessions[msg.sender][delegate];
        emit SessionSet(msg.sender, delegate, 0, 0);
    }

    /// @notice `buy` for `owner`, as its session delegate: the owner's ledger
    /// balance pays (within the session's spend cap) and the shares are the owner's.
    function buyFor(
        address owner,
        bytes32 marketId,
        Outcome outcome,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant returns (uint256) {
        Session storage s = _session(owner);
        if (collateralIn > s.spendLeft) revert SessionSpendExceeded();
        s.spendLeft -= uint128(collateralIn);
        sessionMarket[owner][msg.sender][marketId] = true;
        return _buy(owner, marketId, outcome, collateralIn, minSharesOut, deadline);
    }

    /// @notice `sell` for `owner`, as its session delegate, in a market the
    /// delegate bought into for the owner: the owner's shares go in, the proceeds
    /// go to the owner's ledger balance.
    function sellFor(
        address owner,
        bytes32 marketId,
        Outcome outcome,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 deadline
    ) external nonReentrant returns (uint256) {
        _session(owner);
        if (!sessionMarket[owner][msg.sender][marketId]) revert SessionMarketNotAllowed();
        return _sell(owner, marketId, outcome, sharesIn, minCollateralOut, deadline);
    }

    /// @notice `redeem` for `owner`, as its session delegate: the payout goes to
    /// the owner's ledger balance.
    function redeemFor(address owner, bytes32 marketId) external nonReentrant returns (uint256) {
        _session(owner);
        return _redeem(owner, marketId);
    }

    function _session(address owner) internal view returns (Session storage s) {
        s = sessions[owner][msg.sender];
        if (block.timestamp >= s.expiry) revert SessionInvalid();
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

    /// @notice Common markets expire on a 5-minute grid: the 5-minute price rounds
    /// (our price agent attests every boundary within seconds) and any longer market
    /// on a 5-minute boundary.
    function EXPIRY_GRID() public pure override returns (uint256) {
        return 5 minutes;
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
