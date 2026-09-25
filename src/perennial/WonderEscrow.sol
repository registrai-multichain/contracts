// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
/// Idle escrow earns yield in one ERC-4626 vault (a curated Morpho USDC vault on
/// mainnet): the keeper (YIELD_ROLE) deploys and recalls within the Safe's cap
/// and liquid floor, releases and sweeps recall what they need, and `harvest`
/// sends anything above what is owed to the season pool. A vault loss pauses
/// deposits; it never reduces a team's escrow (the Safe tops up).
///
/// credit never calls out except to the ledger (and the fund once released),
/// so trading never fails because of the vault.
contract WonderEscrow is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MARKETS_ROLE = keccak256("MARKETS_ROLE");
    bytes32 public constant RELEASER_ROLE = keccak256("RELEASER_ROLE");
    bytes32 public constant YIELD_ROLE = keccak256("YIELD_ROLE");

    uint256 public constant RELEASE_DELAY = 7 days;
    /// @notice Shortfall below this is vault rounding, not a loss (0.01 USDC).
    uint256 public constant LOSS_DUST = 1e4;

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

    IERC4626 public vault;
    uint256 public cap;
    uint256 public minLiquid;
    bool public yieldPaused;

    event EscrowCredited(bytes32 indexed key, uint256 amount);
    event ReleaseQueued(bytes32 indexed key, uint256 indexed builderId, uint256 projectId, uint64 readyAt);
    event ReleaseCancelled(bytes32 indexed key);
    event Released(bytes32 indexed key, uint256 indexed builderId, uint256 amount);
    event Swept(bytes32 indexed key, uint256 amount);
    event VaultSet(address vault);
    event CapSet(uint256 cap);
    event MinLiquidSet(uint256 minLiquid);
    event YieldPausedSet(bool paused);
    event Deployed(uint256 assets);
    event Recalled(uint256 assets);
    event Harvested(uint256 toSeason);
    event LossDetected(uint256 shortfall);

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
    error VaultNotSet();
    error VaultInUse();
    error WrongAsset();
    error YieldPausedError();
    error OverCap();
    error BelowMinLiquid();

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

    // ───────────────────────────── yield (GOVERNOR) ─────────────────────────────

    /// @notice Point at an ERC-4626 vault over the ledger's USDC (or none), only
    /// while this contract holds no shares of the current one.
    function setVault(IERC4626 vault_) external onlyRole(GOVERNOR_ROLE) {
        if (address(vault) != address(0) && vault.balanceOf(address(this)) != 0) revert VaultInUse();
        if (address(vault_) != address(0) && vault_.asset() != address(LEDGER.USDC())) revert WrongAsset();
        vault = vault_;
        emit VaultSet(address(vault_));
    }

    function setCap(uint256 cap_) external onlyRole(GOVERNOR_ROLE) {
        cap = cap_;
        emit CapSet(cap_);
    }

    function setMinLiquid(uint256 minLiquid_) external onlyRole(GOVERNOR_ROLE) {
        minLiquid = minLiquid_;
        emit MinLiquidSet(minLiquid_);
    }

    function setYieldPaused(bool paused) external onlyRole(GOVERNOR_ROLE) {
        yieldPaused = paused;
        emit YieldPausedSet(paused);
    }

    // ───────────────────────────── yield (keeper) ─────────────────────────────

    function deploy(uint256 assets) external onlyRole(YIELD_ROLE) nonReentrant {
        if (address(vault) == address(0)) revert VaultNotSet();
        if (yieldPaused) revert YieldPausedError();
        if (deployedPrincipal + assets > cap) revert OverCap();
        uint256 bal = LEDGER.balanceOf(address(this));
        if (assets > bal || bal - assets < minLiquid) revert BelowMinLiquid();
        LEDGER.withdraw(assets);
        IERC20 usdc = LEDGER.USDC();
        usdc.forceApprove(address(vault), assets);
        vault.deposit(assets, address(this));
        deployedPrincipal += assets;
        emit Deployed(assets);
    }

    function recall(uint256 assets) external onlyRole(YIELD_ROLE) nonReentrant {
        _recall(assets);
    }

    /// @notice Anyone. What the ledger account and the vault hold above what the
    /// escrow owes (vault yield, donations) goes to the season pool. A shortfall
    /// beyond LOSS_DUST pauses deposits; the Safe tops up.
    /// Solvency: `ledger + deployedPrincipal >= totalEscrow` holds on every path
    /// (credit checks it; deploy/recall move value 1:1 between the two; release
    /// and sweep lower totalEscrow by what leaves), and the yield skim below only
    /// withdraws what the vault holds above principal.
    function harvest() external nonReentrant returns (uint256 toSeason) {
        uint256 assets = vaultAssets();
        uint256 bal = LEDGER.balanceOf(address(this));
        uint256 total = bal + assets;
        if (total <= totalEscrow) {
            uint256 shortfall = totalEscrow - total;
            if (shortfall > LOSS_DUST) {
                yieldPaused = true;
                emit LossDetected(shortfall);
            }
            return 0;
        }
        toSeason = total - totalEscrow;
        uint256 gain = assets > deployedPrincipal ? assets - deployedPrincipal : 0;
        if (gain > toSeason) gain = toSeason;
        if (gain > 0) {
            vault.withdraw(gain, address(this), address(this));
            IERC20 usdc = LEDGER.USDC();
            usdc.forceApprove(address(LEDGER), gain);
            LEDGER.deposit(gain);
        }
        // Only when principal already paid a release/sweep's share from the
        // ledger: top the ledger up from principal (keeps book == vault).
        uint256 liquid = LEDGER.balanceOf(address(this));
        if (liquid < toSeason) _recall(toSeason - liquid);
        LEDGER.internalTransfer(address(FUND), toSeason);
        FUND.creditSeason(toSeason);
        emit Harvested(toSeason);
    }

    function vaultAssets() public view returns (uint256) {
        if (address(vault) == address(0)) return 0;
        return vault.convertToAssets(vault.balanceOf(address(this)));
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

    /// @dev Make at least `amount` sit in the ledger account, recalling the
    /// shortfall from the vault. Reverts (and the caller retries later) when the
    /// vault cannot pay.
    function _ensureLiquid(uint256 amount) internal {
        uint256 bal = LEDGER.balanceOf(address(this));
        if (bal >= amount) return;
        if (address(vault) == address(0)) revert Illiquid();
        _recall(amount - bal);
    }

    function _recall(uint256 assets) internal {
        if (address(vault) == address(0)) revert VaultNotSet();
        vault.withdraw(assets, address(this), address(this));
        IERC20 usdc = LEDGER.USDC();
        usdc.forceApprove(address(LEDGER), assets);
        LEDGER.deposit(assets);
        deployedPrincipal = assets >= deployedPrincipal ? 0 : deployedPrincipal - assets;
        emit Recalled(assets);
    }
}
