// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {NanoLedger} from "../nanopay/NanoLedger.sol";
import {BuilderRegistry} from "./BuilderRegistry.sol";
import {CaretakerRegistry} from "./CaretakerRegistry.sol";

/// @title ProgressPool. The Perennial funding commons.
/// @notice Receives the commons leg of every Perennial market's trading fee
/// as a NanoLedger balance (MarketsPerennial internalTransfers it here), and
/// distributes it to builders by VERIFIED PROGRESS, never by who attracted the
/// betting. Attention fills the pool; progress draws it.
///
/// Model: progress weight is added per builder ID per epoch by PROGRESS_ROLE
/// (the ProgressArbiter, which maps verified milestones to a builder + tier
/// weight). Everything is keyed by builder id, not wallet: a builder's owner
/// can change (transfer / recovery) without touching its weight or claims, and
/// payouts always resolve through CaretakerRegistry.payoutOf at claim time.
/// `closeEpoch` snapshots the unallocated pool balance as that epoch's pot;
/// builders then `claim` a weight-proportional (linear) share. Linear keeps it
/// sybil-neutral until a unique-builder gate enables quadratic.
///
/// Protocol fee: Registrai takes PROTOCOL_FEE_BPS (1%) of every builder payout,
/// paid to the immutable PROTOCOL_TREASURY when the claim is made; it pays for
/// the caretaker that monitors builders' milestones. The builder's stream carries
/// the other 99%, and `claimable` reports that net amount.
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
    /// @notice Receives the protocol fee on every builder payout. Immutable.
    address public immutable PROTOCOL_TREASURY;

    /// @notice 1% of each builder payout, fixed in code.
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    uint256 public constant BPS = 10_000;

    uint256 public epochLength;
    uint256 public currentEpoch;
    uint256 public epochStart;

    mapping(uint256 => mapping(uint256 => uint256)) public progressWeight; // epoch => builderId => weight
    mapping(uint256 => uint256) public totalWeight; // epoch => total weight
    mapping(uint256 => uint256) public epochPot; // closed epoch => snapshotted pot
    mapping(uint256 => mapping(uint256 => bool)) public claimed; // epoch => builderId => claimed
    uint256 public unclaimedReserved; // pot reserved for closed epochs, not yet claimed
    uint256 public streamWindow; // seconds; salary cadence
    mapping(uint256 => mapping(uint256 => uint256)) public streamIdOf; // epoch => builderId => NanoLedger stream id

    event ProgressAdded(uint256 indexed epoch, uint256 indexed builderId, uint256 weight);
    event EpochClosed(uint256 indexed epoch, uint256 pot, uint256 totalWeight);
    event Claimed(uint256 indexed epoch, uint256 indexed builderId, uint256 amount);
    event EpochLengthSet(uint256 epochLength);
    event StreamWindowSet(uint256 streamWindow);
    event ClaimStreamed(
        uint256 indexed epoch, uint256 indexed builderId, uint256 streamId, uint256 amount, uint256 ratePerSec
    );
    event ProtocolFeePaid(uint256 indexed epoch, uint256 indexed builderId, uint256 fee);

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
        uint256 streamWindow_,
        address protocolTreasury_
    ) {
        if (
            address(ledger_) == address(0) || address(builders_) == address(0) || address(caretakers_) == address(0)
                || admin == address(0) || protocolTreasury_ == address(0)
        ) revert ZeroAddress();
        if (streamWindow_ == 0) revert ZeroWindow();
        LEDGER = ledger_;
        BUILDERS = builders_;
        CARETAKERS = caretakers_;
        PROTOCOL_TREASURY = protocolTreasury_;
        epochLength = epochLength_;
        streamWindow = streamWindow_;
        epochStart = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    /// @notice Credit a builder with verified progress for the current epoch.
    /// Called by the keeper that maps oracle-verified milestones to tier weight.
    function addProgress(uint256 builderId, uint256 weight) external onlyRole(PROGRESS_ROLE) {
        if (!BUILDERS.isActiveBuilderId(builderId)) revert BuilderInactive();
        progressWeight[currentEpoch][builderId] += weight;
        totalWeight[currentEpoch] += weight;
        emit ProgressAdded(currentEpoch, builderId, weight);
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
    /// caretaker) may call it; funds can only land on the builder's CURRENT
    /// payout (CaretakerRegistry.payoutOf, read at claim time).
    /// @return amount What the builder receives: its share of the pot minus the
    /// PROTOCOL_FEE_BPS protocol fee (which goes to PROTOCOL_TREASURY).
    function claimFor(uint256 epoch, uint256 builderId) public returns (uint256 amount) {
        if (epoch >= currentEpoch) revert EpochNotClosed();
        if (claimed[epoch][builderId]) revert AlreadyClaimed();
        uint256 w = progressWeight[epoch][builderId];
        if (w == 0) revert NoProgress();
        uint256 tw = totalWeight[epoch];
        // KNOWN (review L2, deliberately not fixed here): flooring each share
        // leaves up to (builders - 1) units of an epoch's pot reserved in
        // unclaimedReserved forever. Dust-sized; tracked for a later release.
        uint256 share = (epochPot[epoch] * w) / tw;
        claimed[epoch][builderId] = true;
        if (share > 0) {
            unclaimedReserved -= share;
            address payout = CARETAKERS.payoutOf(builderId);
            if (payout == address(0)) revert BuilderInactive();
            uint256 fee = (share * PROTOCOL_FEE_BPS) / BPS;
            amount = share - fee; // >= 1 whenever share >= 1
            if (fee > 0) {
                LEDGER.internalTransfer(PROTOCOL_TREASURY, fee);
                emit ProtocolFeePaid(epoch, builderId, fee);
            }
            // Integer rate: `cap` (== amount) always bounds the total, so no fund
            // loss and the pool can't be drained. Two rounding edges by design:
            // a share not divisible by the window vests slightly AFTER window end
            // (dust remainder trails the flat rate); a share smaller than the
            // window streams at the 1-unit/sec floor, i.e. vests in `amount`
            // seconds (near-instant) since a sub-unit/sec rate isn't expressible.
            uint256 rate = amount / streamWindow;
            if (rate == 0) rate = 1;
            uint256 id = LEDGER.openStream(payout, rate, amount);
            streamIdOf[epoch][builderId] = id;
            emit ClaimStreamed(epoch, builderId, id, amount, rate);
        }
        emit Claimed(epoch, builderId, amount);
    }

    /// @notice Builder owner pulls its builder's share (thin wrapper over
    /// claimFor for `builderIdOf(msg.sender)`; an unregistered caller has none).
    function claim(uint256 epoch) external returns (uint256 amount) {
        return claimFor(epoch, BUILDERS.builderIdOf(msg.sender));
    }

    // ── views ──
    function pendingPot() external view returns (uint256) {
        uint256 bal = LEDGER.balanceOf(address(this));
        return bal > unclaimedReserved ? bal - unclaimedReserved : 0;
    }

    function claimable(uint256 epoch, uint256 builderId) external view returns (uint256) {
        if (epoch >= currentEpoch || claimed[epoch][builderId]) return 0;
        uint256 tw = totalWeight[epoch];
        if (tw == 0) return 0;
        uint256 share = (epochPot[epoch] * progressWeight[epoch][builderId]) / tw;
        return share - (share * PROTOCOL_FEE_BPS) / BPS;
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
