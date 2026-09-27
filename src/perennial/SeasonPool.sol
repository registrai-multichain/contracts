// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {NanoLedger} from "../nanopay/NanoLedger.sol";
import {BuilderRegistry} from "./BuilderRegistry.sol";
import {CaretakerRegistry} from "./CaretakerRegistry.sol";

/// @title SeasonPool. The shared pool of the Perennial markets.
/// @notice Holds a NanoLedger balance fed by the BuilderFund (FUNDER_ROLE): the
/// progressive tax on builder income, frozen income swept from deactivated
/// builders, and the agent escrow of voided markets nobody successfully
/// challenged. The Safe (GOVERNOR) publishes seasons as merkle roots over
/// (seasonId, builderId, amount); builders, or anyone for them, claim with a
/// proof, paid to `CaretakerRegistry.payoutOf(builderId)`.
///
/// On-chain limits a root cannot bypass: a season allocates at most the
/// unallocated balance; one claim per (season, builder); a single claim may not
/// exceed CAP_BPS (20%) of the season total; claims stop at the deadline, after
/// which the Safe may `reclaim` the unclaimed rest back to the unallocated
/// balance; an inactive builder cannot claim.
///
/// Accounting: `unallocated` (free to publish) + `reserved` (published, not yet
/// claimed or reclaimed) never exceeds the pool's ledger balance.
contract SeasonPool is AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");

    /// @notice A single builder's claim may not exceed 20% of the season total.
    uint256 public constant CAP_BPS = 2000;
    /// @notice A season's claim deadline is at most this far ahead (audit 2026-09-27 I-3:
    /// a typo would otherwise lock its allocation for ever).
    uint256 public constant MAX_SEASON_LENGTH = 365 days;
    uint256 public constant BPS = 10_000;

    NanoLedger public immutable LEDGER;
    BuilderRegistry public immutable BUILDERS;
    CaretakerRegistry public immutable CARETAKERS;

    struct Season {
        bytes32 root;
        uint256 total;
        uint256 claimedAmount;
        uint64 deadline; // 0 = unknown season
        bool reclaimed;
    }

    /// @notice Published seasons by id.
    mapping(uint256 => Season) public seasons;
    /// @notice seasonId => builderId => claimed.
    mapping(uint256 => mapping(uint256 => bool)) public claimed;
    /// @notice Funded and not yet allocated to a season.
    uint256 public unallocated;
    /// @notice Allocated to published seasons and not yet claimed or reclaimed.
    uint256 public reserved;

    event Funded(address indexed funder, uint256 amount, uint256 unallocated);
    event Synced(uint256 amount, uint256 unallocated);
    event SeasonPublished(uint256 indexed seasonId, bytes32 root, uint256 total, uint64 deadline);
    event SeasonClaimed(uint256 indexed seasonId, uint256 indexed builderId, uint256 amount, address payout);
    event SeasonReclaimed(uint256 indexed seasonId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error Unfunded();
    error SeasonExists();
    error UnknownSeason();
    error BadSeason();
    error BadDeadline();
    error InsufficientUnallocated();
    error SeasonClosed();
    error SeasonOpen();
    error AlreadyClaimed();
    error AlreadyReclaimed();
    error AboveCap();
    error ExceedsSeason();
    error InvalidProof();
    error BuilderInactive();
    error NothingToSync();

    constructor(NanoLedger ledger_, BuilderRegistry builders_, CaretakerRegistry caretakers_, address admin) {
        if (
            address(ledger_) == address(0) || address(builders_) == address(0) || address(caretakers_) == address(0)
                || admin == address(0)
        ) revert ZeroAddress();
        LEDGER = ledger_;
        BUILDERS = builders_;
        CARETAKERS = caretakers_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ───────────────────────────── funding ─────────────────────────────

    /// @notice Account `amount` the funder has already moved to this contract's
    /// ledger account. Reverts if the balance does not cover it.
    function fund(uint256 amount) external onlyRole(FUNDER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        unallocated += amount;
        if (LEDGER.balanceOf(address(this)) < unallocated + reserved) revert Unfunded();
        emit Funded(msg.sender, amount, unallocated);
    }

    /// @notice Permissionless: account a ledger balance sent here directly (a
    /// donation or a sponsor top-up) as unallocated. Only the surplus over what
    /// is already accounted moves.
    function sync() external returns (uint256 amount) {
        uint256 bal = LEDGER.balanceOf(address(this));
        uint256 accounted = unallocated + reserved;
        if (bal <= accounted) revert NothingToSync();
        amount = bal - accounted;
        unallocated += amount;
        emit Synced(amount, unallocated);
    }

    // ───────────────────────────── seasons ─────────────────────────────

    /// @notice Publish a season: a merkle root over leaves
    /// keccak256(bytes.concat(keccak256(abi.encode(seasonId, builderId, amount)))),
    /// allocating `total` from the unallocated balance until `deadline`.
    function publishSeason(uint256 seasonId, bytes32 root, uint256 total, uint64 deadline)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        if (seasons[seasonId].deadline != 0) revert SeasonExists();
        if (root == bytes32(0) || total == 0) revert BadSeason();
        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_SEASON_LENGTH) revert BadDeadline();
        if (total > unallocated) revert InsufficientUnallocated();
        unallocated -= total;
        reserved += total;
        seasons[seasonId] = Season({root: root, total: total, claimedAmount: 0, deadline: deadline, reclaimed: false});
        emit SeasonPublished(seasonId, root, total, deadline);
    }

    /// @notice Claim a builder's season reward (anyone may call; the reward
    /// lands on the builder's payout). Returns the amount paid.
    function claim(uint256 seasonId, uint256 builderId, uint256 amount, bytes32[] calldata proof)
        external
        returns (uint256)
    {
        Season storage s = seasons[seasonId];
        if (s.deadline == 0) revert UnknownSeason();
        if (block.timestamp > s.deadline) revert SeasonClosed();
        if (claimed[seasonId][builderId]) revert AlreadyClaimed();
        if (amount == 0) revert ZeroAmount();
        if (amount > (s.total * CAP_BPS) / BPS) revert AboveCap();
        if (!BUILDERS.isActiveBuilderId(builderId)) revert BuilderInactive();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(seasonId, builderId, amount))));
        if (!MerkleProof.verifyCalldata(proof, s.root, leaf)) revert InvalidProof();
        // A root that over-allocates cannot pay out more than the season total.
        if (s.claimedAmount + amount > s.total) revert ExceedsSeason();

        address payout = CARETAKERS.payoutOf(builderId);
        if (payout == address(0)) revert BuilderInactive();
        claimed[seasonId][builderId] = true;
        s.claimedAmount += amount;
        reserved -= amount;
        LEDGER.internalTransfer(payout, amount);
        emit SeasonClaimed(seasonId, builderId, amount, payout);
        return amount;
    }

    /// @notice After the deadline, return a season's unclaimed rest to the
    /// unallocated balance (for a later season).
    function reclaim(uint256 seasonId) external onlyRole(GOVERNOR_ROLE) returns (uint256 rest) {
        Season storage s = seasons[seasonId];
        if (s.deadline == 0) revert UnknownSeason();
        if (block.timestamp <= s.deadline) revert SeasonOpen();
        if (s.reclaimed) revert AlreadyReclaimed();
        s.reclaimed = true;
        rest = s.total - s.claimedAmount;
        reserved -= rest;
        unallocated += rest;
        emit SeasonReclaimed(seasonId, rest);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @notice The leaf a season's tree must contain for (builderId, amount).
    function leafOf(uint256 seasonId, uint256 builderId, uint256 amount) external pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(seasonId, builderId, amount))));
    }

    /// @notice The largest amount one builder may claim from a season.
    function capOf(uint256 seasonId) external view returns (uint256) {
        return (seasons[seasonId].total * CAP_BPS) / BPS;
    }
}
