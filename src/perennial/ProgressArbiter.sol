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

    uint256 public challengeWindow;
    uint256 public stakePerProposal;
    uint256 public maxWeightPerProposal;

    enum State {
        None,
        Proposed,
        Challenged,
        ResolvedValid,
        ResolvedInvalid,
        Finalized
    }

    struct Entry {
        address builder;
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

    event BondDeposited(address indexed proposer, uint256 amount);
    event BondWithdrawn(address indexed proposer, uint256 amount);
    event ProgressProposed(uint256 indexed id, address indexed builder, uint256 weight, uint256 maturesAt);
    event ProgressChallenged(uint256 indexed id, address indexed challenger);
    event ProgressResolved(uint256 indexed id, bool valid);
    event ProgressFinalized(uint256 indexed id, address indexed builder, uint256 weight);
    event ParamsSet(uint256 challengeWindow, uint256 stakePerProposal);

    error ZeroAddress();
    error BadState();
    error WindowOpen();
    error WindowClosed();
    error InsufficientBond();
    error BuilderInactive();
    error UnauthorizedCaretaker();
    error InvalidWeight();
    error InvalidParams();

    constructor(
        NanoLedger ledger_,
        ProgressPool pool_,
        BuilderRegistry builders_,
        CaretakerRegistry caretakers_,
        address admin,
        uint256 challengeWindow_,
        uint256 stakePerProposal_,
        uint256 maxWeightPerProposal_
    ) {
        if (
            address(ledger_) == address(0) || address(pool_) == address(0) || address(builders_) == address(0)
                || address(caretakers_) == address(0) || admin == address(0)
        ) revert ZeroAddress();
        if (maxWeightPerProposal_ == 0) revert InvalidWeight();
        if (challengeWindow_ == 0 || stakePerProposal_ == 0) revert InvalidParams();
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

    function propose(address builder, uint256 weight) external onlyRole(PROPOSER_ROLE) returns (uint256 id) {
        if (builder == address(0)) revert ZeroAddress();
        if (weight == 0 || weight > maxWeightPerProposal) revert InvalidWeight();
        uint256 builderId = BUILDERS.builderIdOf(builder);
        if (builderId == 0 || !BUILDERS.isActiveBuilderId(builderId)) revert BuilderInactive();
        if (!CARETAKERS.isCaretaker(builderId, msg.sender)) revert UnauthorizedCaretaker();
        if (availableBond(msg.sender) < stakePerProposal) revert InsufficientBond();
        uint256 stake = stakePerProposal;
        lockedBond[msg.sender] += stake;
        id = entries.length;
        uint256 m = block.timestamp + challengeWindow;
        entries.push(
            Entry({
                builder: builder,
                weight: weight,
                proposer: msg.sender,
                maturesAt: m,
                challenger: address(0),
                stake: stake,
                state: State.Proposed
            })
        );
        emit ProgressProposed(id, builder, weight, m);
    }

    function challenge(uint256 id) external {
        Entry storage e = entries[id];
        if (e.state != State.Proposed) revert BadState();
        if (block.timestamp >= e.maturesAt) revert WindowClosed();
        LEDGER.transferFromInternal(msg.sender, address(this), e.stake);
        e.challenger = msg.sender;
        e.state = State.Challenged;
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
        POOL.addProgress(e.builder, e.weight);
        emit ProgressFinalized(id, e.builder, e.weight);
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
