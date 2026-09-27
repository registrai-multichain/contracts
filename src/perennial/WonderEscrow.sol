// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NanoLedger} from "../nanopay/NanoLedger.sol";
import {BuilderFund} from "./BuilderFund.sol";
import {BuilderRegistry} from "./BuilderRegistry.sol";
import {VerifiedBuilderBadge} from "./VerifiedBuilderBadge.sol";
import {SourceKey} from "./SourceKey.sol";

/// @title WonderEscrow. The builder leg of wonder markets, held for a project's team.
/// @notice MarketsPerennial (MARKETS_ROLE) moves the builder leg of a bound
/// wonder market into this contract's NanoLedger account and `credit`s it to
/// the market's source key. The team gets it once the operator (RELEASER_ROLE)
/// has seen the project's proof hold and queued a release to that project's
/// builder, and RELEASE_DELAY has passed without the Safe (GOVERNOR) cancelling.
/// Escrow is kept per BuilderFund epoch (up to MAX_BUCKETS per source; more merge
/// into the latest), and a release credits each amount to the epoch it was EARNED
/// in (ended epochs through the fund's creditLate), so it is taxed as if paid on
/// time (audit 2026-09-27). Credits after a release go straight to the fund.
/// Unclaimed escrow is swept EXPIRY after its first credit: 90% to the season
/// pool, 10% to the protocol treasury (owner, 2026-09-27).
///
/// The escrow sits in this contract's NanoLedger account and nowhere else (the
/// yield vault was cancelled, 2026-09-27): it leaves only by a release to the
/// verified team or a sweep, and no role can move it otherwise.
contract WonderEscrow is AccessControl, ReentrancyGuard {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MARKETS_ROLE = keccak256("MARKETS_ROLE");
    bytes32 public constant RELEASER_ROLE = keccak256("RELEASER_ROLE");

    uint256 public constant RELEASE_DELAY = 7 days;
    /// @notice The treasury's cut of swept (never claimed) escrow, to the fund's
    /// PROTOCOL_TREASURY; the rest goes to the season pool (owner, 2026-09-27).
    uint256 public constant SWEEP_TREASURY_BPS = 1000;
    /// @notice Per-epoch escrow buckets kept per source; later epochs merge into the last.
    uint256 public constant MAX_BUCKETS = 12;

    NanoLedger public immutable LEDGER;
    BuilderFund public immutable FUND;
    BuilderRegistry public immutable BUILDERS;
    VerifiedBuilderBadge public immutable BADGE;
    uint256 public immutable EXPIRY;

    struct Release {
        uint256 builderId;
        uint256 projectId;
        uint64 readyAt;
    }

    /// @notice A source's escrow earned in one BuilderFund epoch.
    struct Bucket {
        uint64 epoch;
        uint192 amount;
    }

    mapping(bytes32 => uint256) public escrowOf;
    mapping(bytes32 => Bucket[]) internal _buckets;
    /// @notice After a cancelled release nobody may sweep until this time (audit L-1).
    mapping(bytes32 => uint64) public sweepBlockedUntil;
    mapping(bytes32 => uint64) public firstCreditAt;
    mapping(bytes32 => uint256) public releasedTo;
    mapping(bytes32 => Release) public pendingRelease;
    /// @notice Escrow owed to all sources; the ledger account always covers it.
    uint256 public totalEscrow;

    event EscrowCredited(bytes32 indexed key, uint256 amount);
    event ReleaseQueued(bytes32 indexed key, uint256 indexed builderId, uint256 projectId, uint64 readyAt);
    event ReleaseCancelled(bytes32 indexed key);
    event Released(bytes32 indexed key, uint256 indexed builderId, uint256 amount);
    event Swept(bytes32 indexed key, uint256 toSeason, uint256 toTreasury);
    event Unreleased(bytes32 indexed key, uint256 indexed builderId);

    error ZeroAddress();
    error Mismatch();
    error Unfunded();
    error ProjectMismatch();
    error BuilderNotLive();
    error AlreadyReleased();
    error ReleasePending();
    error NotReady();
    error NotExpired();
    error NothingToSweep();
    error SweepBlocked();
    error NotAuthorized();
    error NoPendingRelease();
    error NotReleased();

    constructor(NanoLedger ledger_, BuilderFund fund_, VerifiedBuilderBadge badge_, address admin, uint256 expiry_) {
        if (
            address(ledger_) == address(0) || address(fund_) == address(0) || address(badge_) == address(0)
                || admin == address(0)
        ) revert ZeroAddress();
        if (address(fund_.LEDGER()) != address(ledger_) || address(badge_.BUILDERS()) != address(fund_.BUILDERS())) {
            revert Mismatch();
        }
        LEDGER = ledger_;
        FUND = fund_;
        BUILDERS = fund_.BUILDERS();
        BADGE = badge_;
        EXPIRY = expiry_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ───────────────────────────── credit ─────────────────────────────

    /// @notice Record `amount`, already moved to this contract's ledger account
    /// by the caller, for the source `key`. Once released, forward it to the fund.
    function credit(bytes32 key, uint256 amount) external onlyRole(MARKETS_ROLE) {
        if (amount == 0) return;
        uint256 builderId = releasedTo[key];
        if (builderId != 0) {
            LEDGER.internalTransfer(address(FUND), amount);
            FUND.credit(builderId, amount);
            return;
        }
        escrowOf[key] += amount;
        totalEscrow += amount;
        if (firstCreditAt[key] == 0) firstCreditAt[key] = uint64(block.timestamp);
        if (LEDGER.balanceOf(address(this)) < totalEscrow) revert Unfunded();
        _addToBucket(key, amount);
        emit EscrowCredited(key, amount);
    }

    // ───────────────────────────── release ─────────────────────────────

    /// @notice Start the RELEASE_DELAY clock for paying `source`'s escrow to the
    /// builder that owns `projectId` (an active project with this exact source,
    /// an active builder with a live badge).
    function queueRelease(string calldata source, uint256 projectId) external onlyRole(RELEASER_ROLE) {
        bytes32 key = SourceKey.keyOf(source);
        if (releasedTo[key] != 0) revert AlreadyReleased();
        if (pendingRelease[key].readyAt != 0) revert ReleasePending();
        uint256 builderId = _checkProject(key, projectId);
        uint64 readyAt = uint64(block.timestamp + RELEASE_DELAY);
        pendingRelease[key] = Release(builderId, projectId, readyAt);
        emit ReleaseQueued(key, builderId, projectId, readyAt);
    }

    /// @notice Stop a queued release. The Safe (GOVERNOR) — the squatter guard — or
    /// the operator (RELEASER), which may only withdraw a queue it no longer stands by
    /// (a cancel delays a payout, it never moves one).
    function cancelRelease(bytes32 key) external {
        if (!hasRole(GOVERNOR_ROLE, msg.sender) && !hasRole(RELEASER_ROLE, msg.sender)) revert NotAuthorized();
        if (pendingRelease[key].readyAt == 0) revert NoPendingRelease();
        delete pendingRelease[key];
        sweepBlockedUntil[key] = uint64(block.timestamp + RELEASE_DELAY);
        emit ReleaseCancelled(key);
    }

    /// @notice The Safe undoes a release that went to the wrong builder (a squatter
    /// that outlived the 7-day window): later credits wait in escrow again. What was
    /// already released is builder income in the BuilderFund (deactivating that
    /// builder freezes it for sweepFrozen). GOVERNOR only.
    function unrelease(bytes32 key) external onlyRole(GOVERNOR_ROLE) {
        uint256 builderId = releasedTo[key];
        if (builderId == 0) revert NotReleased();
        delete releasedTo[key];
        emit Unreleased(key, builderId);
    }

    /// @notice Anyone, after the delay. Re-checks the project and builder.
    function executeRelease(bytes32 key) external nonReentrant {
        Release memory r = pendingRelease[key];
        if (r.readyAt == 0 || block.timestamp < r.readyAt) revert NotReady();
        uint256 builderId = _checkProject(key, r.projectId);
        if (builderId != r.builderId) revert ProjectMismatch();
        uint256 amount = escrowOf[key];
        Bucket[] memory buckets = _buckets[key];
        delete pendingRelease[key];
        delete _buckets[key];
        releasedTo[key] = builderId;
        escrowOf[key] = 0;
        firstCreditAt[key] = 0;
        totalEscrow -= amount;
        if (amount > 0) {
            LEDGER.internalTransfer(address(FUND), amount);
            uint256 current = FUND.currentEpoch();
            for (uint256 i; i < buckets.length; i++) {
                Bucket memory b = buckets[i];
                if (b.epoch < current) FUND.creditLate(builderId, b.epoch, b.amount);
                else FUND.credit(builderId, b.amount);
            }
        }
        emit Released(key, builderId, amount);
    }

    // ───────────────────────────── expiry ─────────────────────────────

    /// @notice Anyone: EXPIRY after a source's first unreleased credit, its
    /// escrow goes 90% to the season pool and 10% (rounded down) to the fund's
    /// PROTOCOL_TREASURY, and the clock resets.
    function sweep(bytes32 key) external nonReentrant {
        if (releasedTo[key] != 0) revert AlreadyReleased();
        if (pendingRelease[key].readyAt != 0) revert ReleasePending();
        if (block.timestamp < sweepBlockedUntil[key]) revert SweepBlocked();
        uint64 first = firstCreditAt[key];
        if (first == 0) revert NothingToSweep();
        if (block.timestamp < uint256(first) + EXPIRY) revert NotExpired();
        uint256 amount = escrowOf[key];
        escrowOf[key] = 0;
        firstCreditAt[key] = 0;
        delete _buckets[key];
        totalEscrow -= amount;
        uint256 toTreasury = (amount * SWEEP_TREASURY_BPS) / 10_000;
        uint256 toSeason = amount - toTreasury;
        if (amount > 0) {
            if (toTreasury > 0) LEDGER.internalTransfer(FUND.PROTOCOL_TREASURY(), toTreasury);
            if (toSeason > 0) {
                LEDGER.internalTransfer(address(FUND), toSeason);
                FUND.creditSeason(toSeason);
            }
        }
        emit Swept(key, toSeason, toTreasury);
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// @dev The project exists, is active, its source hashes to `key`, and its
    /// builder is active with an issued badge that has not lapsed.
    function _checkProject(bytes32 key, uint256 projectId) internal view returns (uint256 builderId) {
        (uint256 bId, string memory src, bool active,) = BUILDERS.projects(projectId);
        if (bId == 0 || !active || keccak256(bytes(src)) != key) revert ProjectMismatch();
        if (!BUILDERS.isActiveBuilderId(bId)) revert BuilderNotLive();
        uint256 serial = BADGE.serialOf(bId);
        if (serial == 0 || BADGE.isLapsed(serial)) revert BuilderNotLive();
        return bId;
    }

    /// @dev Add `amount` to `key`'s bucket for the fund's current epoch: a new
    /// bucket while fewer than MAX_BUCKETS, else the latest one grows.
    function _addToBucket(bytes32 key, uint256 amount) internal {
        Bucket[] storage bs = _buckets[key];
        uint256 epoch = FUND.currentEpoch();
        uint256 n = bs.length;
        if (n > 0 && (bs[n - 1].epoch == epoch || n == MAX_BUCKETS)) {
            bs[n - 1].amount += uint192(amount);
        } else {
            bs.push(Bucket(uint64(epoch), uint192(amount)));
        }
    }

    // ───────────────────────────── views ─────────────────────────────

    function bucketCount(bytes32 key) external view returns (uint256) {
        return _buckets[key].length;
    }

    function bucketAt(bytes32 key, uint256 i) external view returns (uint64 epoch, uint192 amount) {
        Bucket memory b = _buckets[key][i];
        return (b.epoch, b.amount);
    }
}
