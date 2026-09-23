// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";

/// @title OracleStake. Tiered pooled stake with per-oracle floor.
/// @notice Lets a creator stake USDC once and stand up multiple oracle feeds
///         (tier quota), instead of a developer shipping a package. OracleStake
///         is the on-chain feed creator AND bonded agent of record for every
///         feed it stands up, so attestation flows through it (a hard
///         chokepoint) and a single staked deposit funds many feeds. Architecture
///         C-SILOED (see docs/.../2026-06-15-oracle-stake-tiers.md): each feed
///         gets its OWN real per-(feedId, OracleStake) Registry bond, so a slash
///         of one feed is isolated by Registry and CANNOT under-back the others
///         (the suffix shared-buffer failure mode is structurally impossible at
///         the bond layer). ZERO changes to the deployed Registry/Attestation/
///         Dispute/Markets. Feeds stay market-consumable: markets pass
///         agent = address(this).
///
/// ACCOUNTING MODEL (corrected vs the spec's stated invariant):
///   depositOf[d]  = gross USDC d entrusted (free in this contract + posted as
///                   Registry bonds). bondedOf + strandedOf = the portion that
///                   physically left to the Registry.
///   freeOf(d)     = depositOf - bondedOf - strandedOf = USDC still here for d.
///   SOLVENCY INVARIANT: accountedDeposits - accountedBonded <= USDC.balanceOf,
///   i.e. the free USDC owed to all deployers is actually present (bonded USDC
///   lives in the Registry, not here). Asserted by the fuzz invariant in tests.
///
/// Accountability: the staker is the beneficial owner (ownerOf), but OracleStake
/// is the slashable agent of record. Disputes are forced to a NEUTRAL resolver
/// (never the deployer, which would be a self-resolution/confiscation attack).
/// GOVERNOR_ROLE must be a TimelockController in production.
contract OracleStake is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint256 public constant BPS = 10_000;

    IERC20 public immutable USDC;
    Registry public immutable REGISTRY;
    Attestation public immutable ATTESTATION;

    // ── governance-set params ──
    uint256 public floorConst;        // per-oracle floor constant (>= REGISTRY.MIN_BOND)
    address public neutralResolver;   // forced resolver for every feed; never the deployer
    uint256 public slashPenaltyBps;   // extra penalty on a dead-feed transition (anti self-slash)
    address public feeSink;           // destination for penalties + skimmed donations/fees
    uint256 public maxDeploysPerEpoch; // 0 = off
    uint256 public epochLength;

    struct Tier { uint256 minStake; uint256 maxOracles; }
    Tier[] public tiers;              // ascending by minStake; headroom-checked

    // ── per-deployer ledger ──
    mapping(address => uint256) public depositOf;   // gross stake
    mapping(address => uint256) public bondedOf;    // USDC in live Registry bonds
    mapping(address => uint256) public strandedOf;  // USDC in dead-feed Registry stubs
    mapping(address => uint256) public activeOf;    // count of live feeds
    mapping(address => address) public delegateOf;
    mapping(address => uint256) internal _windowStart;
    mapping(address => uint256) internal _deploysThisEpoch;

    // ── per-feed bookkeeping ──
    mapping(bytes32 => address) public ownerOf;     // feedId => beneficial deployer
    mapping(bytes32 => uint256) public lastReserved; // feedId => our last-known Registry bond (single source of truth)
    mapping(bytes32 => bool) public feedDead;
    mapping(bytes32 => bool) public feedExited;

    // ── live-feed enumeration (swap-pop) ──
    mapping(address => bytes32[]) internal _liveFeeds;
    mapping(bytes32 => uint256) internal _liveIdxPlus1;

    // ── global accounting ──
    uint256 public accountedDeposits;  // sum of depositOf
    uint256 public accountedBonded;    // sum of bondedOf + strandedOf (USDC we have in the Registry)

    event Staked(address indexed deployer, uint256 amount, uint256 newDeposit);
    event Withdrawn(address indexed deployer, uint256 amount, uint256 newDeposit);
    event FeedDeployed(address indexed deployer, bytes32 indexed feedId, uint256 perOracleFloor, address ruleContract);
    event Attested(address indexed deployer, bytes32 indexed feedId, bytes32 attestationId);
    event SlashReconciled(address indexed deployer, bytes32 indexed feedId, uint256 loss, uint256 penalty, bool dead, uint256 newDeposit);
    event FeedExited(address indexed deployer, bytes32 indexed feedId, uint256 returned);
    event FeesSkimmed(uint256 amount, address to);
    event TierTableSet();
    event ParamSet(bytes32 indexed what, uint256 value, address addr);
    event DelegateSet(address indexed deployer, address delegate);

    error ZeroAmount();
    error QuotaExceeded();
    error FloorBreach();
    error FeedUnderBacked();
    error NotOwnerOrDelegate();
    error NotOwner();
    error FeedIsDead();
    error NotLiveFeed();
    error WrongAttestPath();
    error BadTierTable();
    error DeployRateLimited();
    error CooldownOrWindowOpen();
    error BadParam();

    constructor(
        IERC20 usdc_,
        Registry registry_,
        Attestation attestation_,
        address admin,
        address neutralResolver_,
        address feeSink_
    ) {
        if (neutralResolver_ == address(0) || feeSink_ == address(0)) revert BadParam();
        USDC = usdc_;
        REGISTRY = registry_;
        ATTESTATION = attestation_;
        floorConst = 20e6; // >= REGISTRY.MIN_BOND (10e6)
        neutralResolver = neutralResolver_;
        feeSink = feeSink_;
        slashPenaltyBps = 5_000; // 50% of the feed's reserved bond on a self-killed feed
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
    }

    // ───────────────────────────── Views ─────────────────────────────

    function quotaOf(address d) public view returns (uint256 quota) {
        uint256 dep = depositOf[d];
        for (uint256 i = 0; i < tiers.length; i++) {
            if (dep >= tiers[i].minStake) quota = tiers[i].maxOracles;
        }
    }

    /// @notice Free USDC headroom for d (depositOf minus what is in the Registry).
    function freeOf(address d) public view returns (uint256) {
        uint256 used = bondedOf[d] + strandedOf[d];
        return depositOf[d] > used ? depositOf[d] - used : 0;
    }

    function perOracleFloorFor(bytes32 feedId) public view returns (uint256) {
        uint256 mb = REGISTRY.getFeed(feedId).minBond;
        return floorConst > mb ? floorConst : mb;
    }

    function liveFeeds(address d) external view returns (bytes32[] memory) {
        return _liveFeeds[d];
    }

    function agentForFeed(bytes32) external view returns (address) {
        return address(this); // integrators pass this as the market's agent
    }

    function tierCount() external view returns (uint256) {
        return tiers.length;
    }

    // ──────────────────────────── Stake ──────────────────────────────

    function stake(uint256 amount) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        depositOf[msg.sender] += amount;
        accountedDeposits += amount;
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, depositOf[msg.sender]);
    }

    /// @notice Alias for stake; UX nicety after a slash.
    function topUp(uint256 amount) external {
        stake(amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _syncAll(msg.sender);
        // can only pull FREE USDC; bonded/stranded sit in the Registry.
        if (amount > freeOf(msg.sender)) revert FloorBreach();
        depositOf[msg.sender] -= amount;
        accountedDeposits -= amount;
        USDC.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, depositOf[msg.sender]);
    }

    // ──────────────────────────── Deploy ─────────────────────────────

    function deployFeed(
        string calldata description,
        bytes32 methHash,
        uint256 minBond,
        uint256 disputeWindow
    ) external returns (bytes32 feedId) {
        return _deploy(description, methHash, minBond, disputeWindow, address(0));
    }

    function deployFeedWithRule(
        string calldata description,
        bytes32 methHash,
        uint256 minBond,
        uint256 disputeWindow,
        address ruleContract
    ) external returns (bytes32 feedId) {
        if (ruleContract == address(0)) revert BadParam();
        return _deploy(description, methHash, minBond, disputeWindow, ruleContract);
    }

    function _deploy(
        string calldata description,
        bytes32 methHash,
        uint256 minBond,
        uint256 disputeWindow,
        address ruleContract
    ) internal nonReentrant returns (bytes32 feedId) {
        address d = msg.sender;
        _syncAll(d);
        _rateLimit(d);
        uint256 floor = floorConst > minBond ? floorConst : minBond;
        if (activeOf[d] + 1 > quotaOf(d)) revert QuotaExceeded();
        if (freeOf(d) < floor) revert FloorBreach();

        feedId = REGISTRY.createFeed(description, methHash, minBond, disputeWindow, neutralResolver);
        USDC.forceApprove(address(REGISTRY), floor);
        if (ruleContract == address(0)) {
            REGISTRY.registerAgent(feedId, methHash, floor);
        } else {
            REGISTRY.registerAgentWithRule(feedId, methHash, floor, ruleContract);
        }
        ownerOf[feedId] = d;
        lastReserved[feedId] = floor;
        bondedOf[d] += floor;
        accountedBonded += floor;
        activeOf[d] += 1;
        _addLiveFeed(d, feedId);
        emit FeedDeployed(d, feedId, floor, ruleContract);
    }

    // ──────────────────────────── Attest ─────────────────────────────

    function attest(bytes32 feedId, int256 value, bytes32 inputHash)
        external nonReentrant returns (bytes32)
    {
        _attestGate(feedId);
        if (REGISTRY.ruleOf(feedId, address(this)) != address(0)) revert WrongAttestPath();
        bytes32 id = ATTESTATION.attest(feedId, value, inputHash);
        emit Attested(ownerOf[feedId], feedId, id);
        return id;
    }

    function attestWithRule(bytes32 feedId, int256[] calldata rawInputs)
        external nonReentrant returns (bytes32)
    {
        _attestGate(feedId);
        if (REGISTRY.ruleOf(feedId, address(this)) == address(0)) revert WrongAttestPath();
        bytes32 id = ATTESTATION.attestWithRule(feedId, rawInputs);
        emit Attested(ownerOf[feedId], feedId, id);
        return id;
    }

    function _attestGate(bytes32 feedId) internal {
        address owner = ownerOf[feedId];
        if (owner == address(0)) revert NotLiveFeed();
        if (msg.sender != owner && msg.sender != delegateOf[owner]) revert NotOwnerOrDelegate();
        _syncFeed(feedId);
        if (feedDead[feedId]) revert FeedIsDead();
        // Per-feed gate only: a sibling slash NEVER freezes this feed (each feed
        // is independently bonded in C-SILOED). This fires while THIS feed's bond
        // is locked in an open dispute (available = bond - locked < minBond), so
        // the agent cannot post new attestations while its stake is contested.
        if (_feedUnderBacked(feedId)) revert FeedUnderBacked();
    }

    // ─────────────────── Slash reconciliation (pull) ─────────────────

    /// @notice Reconcile a feed's Registry bond into our ledger. Permissionless
    /// and idempotent; also auto-called by deploy/withdraw/attest/exit so the
    /// quota/free-floor math never acts on stale slash state (there is no
    /// Registry push callback, so we pull).
    function syncFeed(bytes32 feedId) public {
        _syncFeed(feedId);
    }

    function _syncFeed(bytes32 feedId) internal {
        if (feedExited[feedId] || feedDead[feedId]) return;
        address d = ownerOf[feedId];
        if (d == address(0)) return;

        Registry.Agent memory a = REGISTRY.getAgent(feedId, address(this));
        uint256 prevReserved = lastReserved[feedId];
        uint256 curBond = a.bond;

        // SINGLE-SOURCE reconcile: the only USDC that left is prevReserved - curBond.
        if (curBond < prevReserved) {
            uint256 actualLoss = prevReserved - curBond;
            depositOf[d] -= actualLoss;
            accountedDeposits -= actualLoss;
            bondedOf[d] -= actualLoss;
            accountedBonded -= actualLoss;
            lastReserved[feedId] = curBond;
        }

        Registry.Feed memory f = REGISTRY.getFeed(feedId);
        bool dead = a.slashed || curBond < f.minBond;
        if (dead) {
            // move the remaining curBond from live "bonded" into "stranded"
            // (still our USDC in the Registry; accountedBonded unchanged).
            bondedOf[d] -= curBond;
            strandedOf[d] += curBond;
            activeOf[d] -= 1;
            feedDead[feedId] = true;
            _removeLiveFeed(d, feedId);

            // self-slash penalty: make deploy-then-self-slash a real net loss
            // even with a colluding challenger. Drawn from the deployer's free
            // USDC, routed to feeSink (never re-credited to any deposit).
            uint256 penalty = (prevReserved * slashPenaltyBps) / BPS;
            uint256 free = freeOf(d);
            if (penalty > free) penalty = free;
            if (penalty > 0) {
                depositOf[d] -= penalty;
                accountedDeposits -= penalty;
                USDC.safeTransfer(feeSink, penalty);
            }
            emit SlashReconciled(d, feedId, prevReserved - curBond, penalty, true, depositOf[d]);
        } else if (curBond < prevReserved) {
            emit SlashReconciled(d, feedId, prevReserved - curBond, 0, false, depositOf[d]);
        }
    }

    // ──────────────────── Per-feed top up / exit ─────────────────────

    /// @notice Top up a live feed's Registry bond with FRESH USDC (not from the
    /// pooled deposit), to recover a feed that was partially slashed below its
    /// minBond-driven under-backed threshold. OWNER ONLY: a delegate is an
    /// attestation relay, not a capital controller, and the credited ledger is
    /// msg.sender's, so only the owner may add to their own bond.
    function topUpFeed(bytes32 feedId, uint256 amount) external nonReentrant {
        if (msg.sender != ownerOf[feedId]) revert NotOwner();
        _syncFeed(feedId);
        if (feedDead[feedId]) revert FeedIsDead();
        if (amount == 0) revert ZeroAmount();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        USDC.forceApprove(address(REGISTRY), amount);
        REGISTRY.topUpBond(feedId, amount);
        bondedOf[msg.sender] += amount;
        accountedBonded += amount;
        depositOf[msg.sender] += amount; // gross deposit grows with the fresh bond
        accountedDeposits += amount;
        lastReserved[feedId] += amount;
    }

    /// @notice Reclaim a feed's Registry bond back into the pool. Gated by the
    /// Registry withdraw cooldown (native revert) AND by any still-open dispute
    /// window, so a challenger always faces a fully-bonded agent. OWNER ONLY:
    /// tearing down a feed is a structural action reserved to the deployer, not
    /// the attestation delegate.
    function exitFeed(bytes32 feedId) external nonReentrant {
        address d = ownerOf[feedId];
        if (msg.sender != d) revert NotOwner();
        _syncFeed(feedId);
        if (feedExited[feedId]) revert NotLiveFeed();
        if (_hasOpenDisputeWindow(feedId)) revert CooldownOrWindowOpen();

        uint256 returned = REGISTRY.getAgent(feedId, address(this)).bond; // withdrawBond transfers exactly this
        REGISTRY.withdrawBond(feedId); // reverts natively on cooldown / locked bond
        bool wasLive = !feedDead[feedId];
        if (wasLive) {
            bondedOf[d] -= returned;
            activeOf[d] -= 1;
            _removeLiveFeed(d, feedId);
        } else {
            strandedOf[d] -= returned;
        }
        accountedBonded -= returned;
        // returned USDC is now back in this contract; it remains part of depositOf
        // (gross), so no depositOf change. freeOf rises because bonded/stranded fell.
        lastReserved[feedId] = 0;
        feedExited[feedId] = true;
        emit FeedExited(d, feedId, returned);
    }

    // ───────────────────────────── Fees ──────────────────────────────

    /// @notice Skim USDC NOT attributable to any deployer's free balance (the
    /// Markets agentFee push, donations). The only place balanceOf is read for
    /// value, and it can ONLY route OUT to feeSink, never into a deposit.
    function skimFees() external nonReentrant {
        uint256 bal = USDC.balanceOf(address(this));
        uint256 owedFree = accountedDeposits - accountedBonded; // free USDC owed to deployers
        uint256 claimable = bal > owedFree ? bal - owedFree : 0;
        if (claimable == 0) revert ZeroAmount();
        USDC.safeTransfer(feeSink, claimable);
        emit FeesSkimmed(claimable, feeSink);
    }

    // ─────────────────────────── Delegation ──────────────────────────

    function setDelegate(address delegate) external {
        delegateOf[msg.sender] = delegate;
        emit DelegateSet(msg.sender, delegate);
    }

    // ──────────────────────────── Governor ───────────────────────────

    function setTiers(Tier[] calldata t) external onlyRole(GOVERNOR_ROLE) {
        if (t.length == 0) revert BadTierTable();
        delete tiers;
        uint256 prevMin = 0;
        for (uint256 i = 0; i < t.length; i++) {
            // ascending minStake, positive quota, and HEADROOM: a deployer at a
            // tier's minStake must hold strictly more than maxOracles*floorConst
            // so one slash cannot instantly demote them to a hard floor breach.
            if (t[i].maxOracles == 0) revert BadTierTable();
            if (i > 0 && t[i].minStake <= prevMin) revert BadTierTable();
            if (t[i].minStake <= t[i].maxOracles * floorConst) revert BadTierTable();
            tiers.push(t[i]);
            prevMin = t[i].minStake;
        }
        emit TierTableSet();
    }

    function setFloorConst(uint256 v) external onlyRole(GOVERNOR_ROLE) {
        if (v < REGISTRY.MIN_BOND()) revert BadParam();
        floorConst = v;
        emit ParamSet("floorConst", v, address(0));
    }

    function setNeutralResolver(address r) external onlyRole(GOVERNOR_ROLE) {
        if (r == address(0)) revert BadParam();
        neutralResolver = r;
        emit ParamSet("neutralResolver", 0, r);
    }

    function setSlashPenaltyBps(uint256 bps) external onlyRole(GOVERNOR_ROLE) {
        if (bps > BPS) revert BadParam();
        slashPenaltyBps = bps;
        emit ParamSet("slashPenaltyBps", bps, address(0));
    }

    function setDeployRateLimit(uint256 maxPerEpoch, uint256 epochLen) external onlyRole(GOVERNOR_ROLE) {
        maxDeploysPerEpoch = maxPerEpoch;
        epochLength = epochLen;
        emit ParamSet("deployRateLimit", maxPerEpoch, address(0));
    }

    function setFeeSink(address s) external onlyRole(GOVERNOR_ROLE) {
        if (s == address(0)) revert BadParam();
        feeSink = s;
        emit ParamSet("feeSink", 0, s);
    }

    // ──────────────────────────── Internals ──────────────────────────

    function _feedUnderBacked(bytes32 feedId) internal view returns (bool) {
        Registry.Agent memory a = REGISTRY.getAgent(feedId, address(this));
        uint256 available = a.bond > a.lockedBond ? a.bond - a.lockedBond : 0;
        return available < REGISTRY.getFeed(feedId).minBond;
    }

    function _hasOpenDisputeWindow(bytes32 feedId) internal view returns (bool) {
        Registry.Agent memory a = REGISTRY.getAgent(feedId, address(this));
        if (a.lastAttestationAt == 0) return false;
        uint256 dw = REGISTRY.getFeed(feedId).disputeWindow;
        return block.timestamp < a.lastAttestationAt + dw;
    }

    function _syncAll(address d) internal {
        bytes32[] memory snapshot = _liveFeeds[d]; // copy; _syncFeed may mutate storage list
        for (uint256 i = 0; i < snapshot.length; i++) {
            _syncFeed(snapshot[i]);
        }
    }

    function _rateLimit(address d) internal {
        if (maxDeploysPerEpoch == 0) return;
        if (block.timestamp >= _windowStart[d] + epochLength) {
            _windowStart[d] = block.timestamp;
            _deploysThisEpoch[d] = 0;
        }
        if (_deploysThisEpoch[d] + 1 > maxDeploysPerEpoch) revert DeployRateLimited();
        _deploysThisEpoch[d] += 1;
    }

    function _addLiveFeed(address d, bytes32 feedId) internal {
        _liveFeeds[d].push(feedId);
        _liveIdxPlus1[feedId] = _liveFeeds[d].length;
    }

    function _removeLiveFeed(address d, bytes32 feedId) internal {
        uint256 idxPlus1 = _liveIdxPlus1[feedId];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        bytes32[] storage arr = _liveFeeds[d];
        uint256 lastIdx = arr.length - 1;
        if (idx != lastIdx) {
            bytes32 last = arr[lastIdx];
            arr[idx] = last;
            _liveIdxPlus1[last] = idx + 1;
        }
        arr.pop();
        _liveIdxPlus1[feedId] = 0;
    }
}
