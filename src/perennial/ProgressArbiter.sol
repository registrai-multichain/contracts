// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {NanoLedger} from "../nanopay/NanoLedger.sol";
import {ProgressPool} from "./ProgressPool.sol";
import {BuilderRegistry} from "./BuilderRegistry.sol";
import {CaretakerRegistry} from "./CaretakerRegistry.sol";

/// @title ProgressArbiter. Bonded, challengeable progress. Weight can only reach
/// the ProgressPool through here: the caretaker PROPOSES weight backed by a bond,
/// anyone may CHALLENGE within a window, a neutral RESOLVER adjudicates and slashes
/// false progress, and FINALIZE credits the pool. Distribution stays optimistic;
/// the trusted addProgress seam is replaced by skin-in-the-game.
contract ProgressArbiter is AccessControl {
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    NanoLedger public immutable LEDGER;
    ProgressPool public immutable POOL;
    BuilderRegistry public immutable BUILDERS;
    CaretakerRegistry public immutable CARETAKERS;

    /// @notice How long a challenged entry may wait for the resolver before
    /// anyone can expire it (both stakes refunded, no weight credited). Fixed at
    /// deploy so an absent resolver can never lock stakes forever.
    uint256 public immutable RESOLVE_TIMEOUT;

    uint256 public challengeWindow;
    uint256 public stakePerProposal;
    uint256 public maxWeightPerProposal;

    enum State {
        None,
        Proposed,
        Challenged,
        ResolvedValid,
        ResolvedInvalid,
        Finalized,
        Closed, // builder went inactive: stakes returned, no weight credited
        Expired // challenge outlived RESOLVE_TIMEOUT: both stakes returned, no weight
    }

    struct Entry {
        uint256 builderId;
        uint256 weight;
        address proposer;
        uint256 maturesAt;
        address challenger;
        uint256 stake; // snapshot of stakePerProposal at propose time (robust to setParams)
        State state;
    }
    Entry[] public entries;
    mapping(address => uint256) public bondOf;
    mapping(address => uint256) public lockedBond;
    /// @notice When entry `id` was challenged (0 if never).
    mapping(uint256 => uint256) public challengedAt;

    event BondDeposited(address indexed proposer, uint256 amount);
    event BondWithdrawn(address indexed proposer, uint256 amount);
    event ProgressProposed(uint256 indexed id, uint256 indexed builderId, uint256 weight, uint256 maturesAt);
    event ProgressChallenged(uint256 indexed id, address indexed challenger);
    event ProgressResolved(uint256 indexed id, bool valid);
    event ProgressFinalized(uint256 indexed id, uint256 indexed builderId, uint256 weight);
    event ParamsSet(uint256 challengeWindow, uint256 stakePerProposal);
    event ProgressClosedInactive(uint256 indexed id, uint256 indexed builderId, bool challengerRefunded);
    event ChallengeExpired(uint256 indexed id, address indexed challenger);

    error ZeroAddress();
    error BadState();
    error WindowOpen();
    error WindowClosed();
    error InsufficientBond();
    error BuilderInactive();
    error UnauthorizedCaretaker();
    error InvalidWeight();
    error InvalidParams();
    error BuilderActive();
    error TimeoutNotReached();

    constructor(
        NanoLedger ledger_,
        ProgressPool pool_,
        BuilderRegistry builders_,
        CaretakerRegistry caretakers_,
        address admin,
        uint256 challengeWindow_,
        uint256 stakePerProposal_,
        uint256 maxWeightPerProposal_,
        uint256 resolveTimeout_
    ) {
        if (
            address(ledger_) == address(0) || address(pool_) == address(0) || address(builders_) == address(0)
                || address(caretakers_) == address(0) || admin == address(0)
        ) revert ZeroAddress();
        if (maxWeightPerProposal_ == 0) revert InvalidWeight();
        if (challengeWindow_ == 0 || stakePerProposal_ == 0 || resolveTimeout_ == 0) revert InvalidParams();
        RESOLVE_TIMEOUT = resolveTimeout_;
        LEDGER = ledger_;
        POOL = pool_;
        BUILDERS = builders_;
        CARETAKERS = caretakers_;
        challengeWindow = challengeWindow_;
        stakePerProposal = stakePerProposal_;
        maxWeightPerProposal = maxWeightPerProposal_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function depositBond(uint256 amount) external {
        LEDGER.transferFromInternal(msg.sender, address(this), amount);
        bondOf[msg.sender] += amount;
        emit BondDeposited(msg.sender, amount);
    }

    function withdrawBond(uint256 amount) external {
        if (amount > availableBond(msg.sender)) revert InsufficientBond();
        bondOf[msg.sender] -= amount;
        LEDGER.internalTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    function availableBond(address who) public view returns (uint256) {
        return bondOf[who] - lockedBond[who];
    }

    /// @notice Propose `weight` of progress for `builderId`. The caller must be
    /// that builder's caretaker and the builder must be active.
    function propose(uint256 builderId, uint256 weight) external onlyRole(PROPOSER_ROLE) returns (uint256 id) {
        if (weight == 0 || weight > maxWeightPerProposal) revert InvalidWeight();
        if (!BUILDERS.isActiveBuilderId(builderId)) revert BuilderInactive();
        if (!CARETAKERS.isCaretaker(builderId, msg.sender)) revert UnauthorizedCaretaker();
        if (availableBond(msg.sender) < stakePerProposal) revert InsufficientBond();
        uint256 stake = stakePerProposal;
        lockedBond[msg.sender] += stake;
        id = entries.length;
        uint256 m = block.timestamp + challengeWindow;
        entries.push(
            Entry({
                builderId: builderId,
                weight: weight,
                proposer: msg.sender,
                maturesAt: m,
                challenger: address(0),
                stake: stake,
                state: State.Proposed
            })
        );
        emit ProgressProposed(id, builderId, weight, m);
    }

    function challenge(uint256 id) external {
        Entry storage e = entries[id];
        if (e.state != State.Proposed) revert BadState();
        if (block.timestamp >= e.maturesAt) revert WindowClosed();
        LEDGER.transferFromInternal(msg.sender, address(this), e.stake);
        e.challenger = msg.sender;
        e.state = State.Challenged;
        challengedAt[id] = block.timestamp;
        emit ProgressChallenged(id, msg.sender);
    }

    function resolve(uint256 id, bool valid) external onlyRole(RESOLVER_ROLE) {
        Entry storage e = entries[id];
        if (e.state != State.Challenged) revert BadState();
        if (valid) {
            bondOf[e.proposer] += e.stake;
            e.state = State.ResolvedValid;
        } else {
            bondOf[e.proposer] -= e.stake;
            lockedBond[e.proposer] -= e.stake;
            LEDGER.internalTransfer(e.challenger, 2 * e.stake);
            e.state = State.ResolvedInvalid;
        }
        emit ProgressResolved(id, valid);
    }

    function finalize(uint256 id) external {
        Entry storage e = entries[id];
        if (e.state == State.Proposed) {
            if (block.timestamp < e.maturesAt) revert WindowOpen();
            lockedBond[e.proposer] -= e.stake;
        } else if (e.state == State.ResolvedValid) {
            lockedBond[e.proposer] -= e.stake;
        } else {
            revert BadState();
        }
        e.state = State.Finalized;
        POOL.addProgress(e.builderId, e.weight);
        emit ProgressFinalized(id, e.builderId, e.weight);
    }

    /// @notice Close an entry whose builder has been deactivated, so finalize
    /// (which credits the pool, and the pool refuses inactive builders) can never
    /// succeed. The proposer's stake is unlocked and no weight is credited.
    ///  - Proposed: permissionless once the challenge window has closed (a
    ///    challenger keeps the whole window to contest it first).
    ///  - ResolvedValid: permissionless (the challenger already lost its stake).
    ///  - Challenged: RESOLVER_ROLE only, refunding the challenger's stake too;
    ///    otherwise a proposer could dodge a pending slash. Without the resolver
    ///    the entry is closed by expireChallenge after RESOLVE_TIMEOUT.
    function closeInactive(uint256 id) external {
        Entry storage e = entries[id];
        if (BUILDERS.isActiveBuilderId(e.builderId)) revert BuilderActive();
        State st = e.state;
        if (st == State.Proposed) {
            if (block.timestamp < e.maturesAt) revert WindowOpen();
        } else if (st == State.Challenged) {
            _checkRole(RESOLVER_ROLE);
        } else if (st != State.ResolvedValid) {
            revert BadState();
        }
        lockedBond[e.proposer] -= e.stake;
        e.state = State.Closed;
        bool refund = st == State.Challenged;
        if (refund) LEDGER.internalTransfer(e.challenger, e.stake);
        emit ProgressClosedInactive(id, e.builderId, refund);
    }

    /// @notice Expire a challenge the resolver never ruled on. Permissionless once
    /// RESOLVE_TIMEOUT has passed since the challenge: the proposer's stake is
    /// unlocked, the challenger's stake is returned, no weight is credited.
    function expireChallenge(uint256 id) external {
        Entry storage e = entries[id];
        if (e.state != State.Challenged) revert BadState();
        if (block.timestamp < challengedAt[id] + RESOLVE_TIMEOUT) revert TimeoutNotReached();
        lockedBond[e.proposer] -= e.stake;
        e.state = State.Expired;
        LEDGER.internalTransfer(e.challenger, e.stake);
        emit ChallengeExpired(id, e.challenger);
    }

    function setParams(uint256 challengeWindow_, uint256 stakePerProposal_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (challengeWindow_ == 0 || stakePerProposal_ == 0) revert InvalidParams();
        challengeWindow = challengeWindow_;
        stakePerProposal = stakePerProposal_;
        emit ParamsSet(challengeWindow_, stakePerProposal_);
    }

    function setMaxWeightPerProposal(uint256 maxWeightPerProposal_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxWeightPerProposal_ == 0) revert InvalidWeight();
        maxWeightPerProposal = maxWeightPerProposal_;
    }

    function entryCount() external view returns (uint256) {
        return entries.length;
    }

    function getEntry(uint256 id) external view returns (Entry memory) {
        return entries[id];
    }
}
