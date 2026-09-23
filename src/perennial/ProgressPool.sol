// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {NanoLedger} from "../nanopay/NanoLedger.sol";
import {BuilderRegistry} from "./BuilderRegistry.sol";
import {CaretakerRegistry} from "./CaretakerRegistry.sol";

/// @title ProgressPool. The Perennial funding commons.
/// @notice Receives the treasury (commons) leg of every Perennial market's fee
/// as a NanoLedger balance (MarketsPerennial internalTransfers it here), and
/// distributes it to builders by VERIFIED PROGRESS, never by who attracted the
/// betting. Attention fills the pool; progress draws it.
///
/// Model: progress weight is added per builder per epoch by a PROGRESS_ROLE
/// keeper (which maps oracle-verified milestones to a builder + tier weight).
/// `closeEpoch` snapshots the unallocated pool balance as that epoch's pot;
/// builders then `claim` a weight-proportional (linear) share. Linear keeps it
/// sybil-neutral until a unique-builder gate enables quadratic.
///
/// Solvency: ProgressPool only pays out of its own ledger balance via
/// internalTransfer; `unclaimedReserved` tracks pot already earmarked to closed
/// epochs, so `balanceOf(this) >= unclaimedReserved` always holds and new pots
/// only reserve the unreserved remainder.
contract ProgressPool is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant PROGRESS_ROLE = keccak256("PROGRESS_ROLE");

    NanoLedger public immutable LEDGER;
    BuilderRegistry public immutable BUILDERS;
    CaretakerRegistry public immutable CARETAKERS;

    uint256 public epochLength;
    uint256 public currentEpoch;
    uint256 public epochStart;

    mapping(uint256 => mapping(address => uint256)) public progressWeight; // epoch => builder => weight
    mapping(uint256 => uint256) public totalWeight; // epoch => total weight
    mapping(uint256 => uint256) public epochPot; // closed epoch => snapshotted pot
    mapping(uint256 => mapping(address => bool)) public claimed; // epoch => builder => claimed
    uint256 public unclaimedReserved; // pot reserved for closed epochs, not yet claimed
    uint256 public streamWindow; // seconds; salary cadence
    mapping(uint256 => mapping(address => uint256)) public streamIdOf; // epoch => builder => NanoLedger stream id

    event ProgressAdded(uint256 indexed epoch, address indexed builder, uint256 weight);
    event EpochClosed(uint256 indexed epoch, uint256 pot, uint256 totalWeight);
    event Claimed(uint256 indexed epoch, address indexed builder, uint256 amount);
    event EpochLengthSet(uint256 epochLength);
    event StreamWindowSet(uint256 streamWindow);
    event ClaimStreamed(
        uint256 indexed epoch, address indexed builder, uint256 streamId, uint256 amount, uint256 ratePerSec
    );

    error EpochNotOver();
    error EpochNotClosed();
    error AlreadyClaimed();
    error NoProgress();
    error ZeroAddress();
    error ZeroWindow();
    error BuilderInactive();

    constructor(
        NanoLedger ledger_,
        BuilderRegistry builders_,
        CaretakerRegistry caretakers_,
        address admin,
        uint256 epochLength_,
        uint256 streamWindow_
    ) {
        if (
            address(ledger_) == address(0) || address(builders_) == address(0) || address(caretakers_) == address(0)
                || admin == address(0)
        ) revert ZeroAddress();
        if (streamWindow_ == 0) revert ZeroWindow();
        LEDGER = ledger_;
        BUILDERS = builders_;
        CARETAKERS = caretakers_;
        epochLength = epochLength_;
        streamWindow = streamWindow_;
        epochStart = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    /// @notice Credit a builder with verified progress for the current epoch.
    /// Called by the keeper that maps oracle-verified milestones to tier weight.
    function addProgress(address builder, uint256 weight) external onlyRole(PROGRESS_ROLE) {
        if (builder == address(0)) revert ZeroAddress();
        if (!BUILDERS.isActiveBuilder(builder)) revert BuilderInactive();
        progressWeight[currentEpoch][builder] += weight;
        totalWeight[currentEpoch] += weight;
        emit ProgressAdded(currentEpoch, builder, weight);
    }

    /// @notice Snapshot the current epoch's pot (the unallocated pool balance)
    /// and advance. Permissionless once the epoch duration has elapsed. If no
    /// progress was recorded, funds simply roll into the next epoch.
    function closeEpoch() external {
        if (block.timestamp < epochStart + epochLength) revert EpochNotOver();
        uint256 cur = currentEpoch;
        uint256 bal = LEDGER.balanceOf(address(this));
        uint256 newPot = bal > unclaimedReserved ? bal - unclaimedReserved : 0;
        if (totalWeight[cur] > 0 && newPot > 0) {
            epochPot[cur] = newPot;
            unclaimedReserved += newPot;
        }
        emit EpochClosed(cur, epochPot[cur], totalWeight[cur]);
        currentEpoch = cur + 1;
        epochStart = block.timestamp;
    }

    /// @notice Permissionless: crank a builder's claim. Credits the BUILDER, not
    /// the caller. The amount is deterministic, so anyone (including the builder's
    /// caretaker) may call it; funds can only land on the named builder.
    function claimFor(uint256 epoch, address builder) public returns (uint256 amount) {
        if (epoch >= currentEpoch) revert EpochNotClosed();
        if (claimed[epoch][builder]) revert AlreadyClaimed();
        uint256 w = progressWeight[epoch][builder];
        if (w == 0) revert NoProgress();
        uint256 tw = totalWeight[epoch];
        amount = (epochPot[epoch] * w) / tw;
        claimed[epoch][builder] = true;
        if (amount > 0) {
            unclaimedReserved -= amount;
            // Integer rate: `cap` (== amount) always bounds the total, so no fund
            // loss and the pool can't be drained. Two rounding edges by design:
            // a share not divisible by the window vests slightly AFTER window end
            // (dust remainder trails the flat rate); a share smaller than the
            // window streams at the 1-unit/sec floor, i.e. vests in `amount`
            // seconds (near-instant) since a sub-unit/sec rate isn't expressible.
            uint256 rate = amount / streamWindow;
            if (rate == 0) rate = 1;
            uint256 builderId = BUILDERS.builderIdOf(builder);
            address payout = CARETAKERS.payoutOf(builderId);
            if (payout == address(0)) revert BuilderInactive();
            uint256 id = LEDGER.openStream(payout, rate, amount);
            streamIdOf[epoch][builder] = id;
            emit ClaimStreamed(epoch, builder, id, amount, rate);
        }
        emit Claimed(epoch, builder, amount);
    }

    /// @notice Builder pulls their own share (thin wrapper over claimFor).
    function claim(uint256 epoch) external returns (uint256 amount) {
        return claimFor(epoch, msg.sender);
    }

    // ── views ──
    function pendingPot() external view returns (uint256) {
        uint256 bal = LEDGER.balanceOf(address(this));
        return bal > unclaimedReserved ? bal - unclaimedReserved : 0;
    }

    function claimable(uint256 epoch, address builder) external view returns (uint256) {
        if (epoch >= currentEpoch || claimed[epoch][builder]) return 0;
        uint256 tw = totalWeight[epoch];
        if (tw == 0) return 0;
        return (epochPot[epoch] * progressWeight[epoch][builder]) / tw;
    }

    // ── governor ──
    function setEpochLength(uint256 epochLength_) external onlyRole(GOVERNOR_ROLE) {
        epochLength = epochLength_;
        emit EpochLengthSet(epochLength_);
    }

    function setStreamWindow(uint256 w) external onlyRole(GOVERNOR_ROLE) {
        if (w == 0) revert ZeroWindow();
        streamWindow = w;
        emit StreamWindowSet(w);
    }
}
