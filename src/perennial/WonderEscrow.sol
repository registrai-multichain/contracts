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
/// builder, and RELEASE_DELAY has passed without the Safe (GOVERNOR) cancelling:
/// the amount becomes that builder's BuilderFund income for the current epoch
/// (taxed as usual when claimed). Credits after a release go straight to the
/// fund. Unclaimed escrow is swept to the season pool EXPIRY after its first
/// credit. Never the treasury.
///
/// credit never calls out except to the ledger (and the fund once released),
/// so trading never fails because of this contract's vault.
contract WonderEscrow is AccessControl, ReentrancyGuard {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MARKETS_ROLE = keccak256("MARKETS_ROLE");
    bytes32 public constant RELEASER_ROLE = keccak256("RELEASER_ROLE");
    bytes32 public constant YIELD_ROLE = keccak256("YIELD_ROLE");

    uint256 public constant RELEASE_DELAY = 7 days;

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

    mapping(bytes32 => uint256) public escrowOf;
    mapping(bytes32 => uint64) public firstCreditAt;
    mapping(bytes32 => uint256) public releasedTo;
    mapping(bytes32 => Release) public pendingRelease;
    /// @notice Escrow owed to all sources (ledger balance + deployed principal cover it).
    uint256 public totalEscrow;
    /// @notice Principal currently in the yield vault (book value); 0 without a vault.
    uint256 public deployedPrincipal;

    event EscrowCredited(bytes32 indexed key, uint256 amount);
    event ReleaseQueued(bytes32 indexed key, uint256 indexed builderId, uint256 projectId, uint64 readyAt);
    event ReleaseCancelled(bytes32 indexed key);
    event Released(bytes32 indexed key, uint256 indexed builderId, uint256 amount);
    event Swept(bytes32 indexed key, uint256 amount);

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
    error Illiquid();

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
        if (LEDGER.balanceOf(address(this)) + deployedPrincipal < totalEscrow) revert Unfunded();
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

    function cancelRelease(bytes32 key) external onlyRole(GOVERNOR_ROLE) {
        if (pendingRelease[key].readyAt == 0) revert NotReady();
        delete pendingRelease[key];
        emit ReleaseCancelled(key);
    }

    /// @notice Anyone, after the delay. Re-checks the project and builder.
    function executeRelease(bytes32 key) external nonReentrant {
        Release memory r = pendingRelease[key];
        if (r.readyAt == 0 || block.timestamp < r.readyAt) revert NotReady();
        uint256 builderId = _checkProject(key, r.projectId);
        if (builderId != r.builderId) revert ProjectMismatch();
        uint256 amount = escrowOf[key];
        delete pendingRelease[key];
        releasedTo[key] = builderId;
        escrowOf[key] = 0;
        firstCreditAt[key] = 0;
        totalEscrow -= amount;
        if (amount > 0) {
            _ensureLiquid(amount);
            LEDGER.internalTransfer(address(FUND), amount);
            FUND.credit(builderId, amount);
        }
        emit Released(key, builderId, amount);
    }

    // ───────────────────────────── expiry ─────────────────────────────

    /// @notice Anyone: EXPIRY after a source's first unreleased credit, its
    /// escrow goes to the season pool and the clock resets.
    function sweep(bytes32 key) external nonReentrant {
        if (releasedTo[key] != 0) revert AlreadyReleased();
        if (pendingRelease[key].readyAt != 0) revert ReleasePending();
        uint64 first = firstCreditAt[key];
        if (first == 0) revert NothingToSweep();
        if (block.timestamp < uint256(first) + EXPIRY) revert NotExpired();
        uint256 amount = escrowOf[key];
        escrowOf[key] = 0;
        firstCreditAt[key] = 0;
        totalEscrow -= amount;
        if (amount > 0) {
            _ensureLiquid(amount);
            LEDGER.internalTransfer(address(FUND), amount);
            FUND.creditSeason(amount);
        }
        emit Swept(key, amount);
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

    /// @dev Make at least `amount` sit in the ledger account.
    function _ensureLiquid(uint256 amount) internal view {
        if (LEDGER.balanceOf(address(this)) < amount) revert Illiquid();
    }
}
