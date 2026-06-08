// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SuffixSenior} from "./SuffixSenior.sol";
import {SuffixJunior} from "./SuffixJunior.sol";

/// @title SuffixTreasury — cash-floored, two-tranche treasury (Suffix Pool MVP)
/// @notice Implements the v2 design's core invariant on-chain, with NO domains
///         yet (pure USDC): a SENIOR token ($ai) with a hard, cash-backed
///         buyback floor, and a JUNIOR token ($aiLP) that is the residual /
///         first-loss / upside claim.
///
/// WATERFALL (the whole point):
///   seniorClaim = seniorSupply × floorPar         ← senior's hard claim (HardNAV)
///   juniorEquity = max(0, totalUSDC − seniorClaim) ← junior absorbs losses FIRST
///   seniorFloorPrice = k × floorPar  (k = 0.9)     ← buyback floor, < par by design
///
/// A loss reduces totalUSDC → it eats juniorEquity before it can ever touch the
/// senior claim. The senior floor is impaired only once juniorEquity hits 0.
///
/// ANTI-LUNA (non-negotiable, spec §3.2): there is NO function that mints junior
/// to defend the senior. The floor is paid from the USDC reserve only; if the
/// reserve cannot cover a redemption, it REVERTS (insolvency surfaced) — it is
/// never papered over by diluting the junior into a falling market.
///
/// The floor RATCHETS only from REALIZED revenue (recordRevenue) — never from
/// unrealized marks. Domains, the `.ai` index, and the AMM band-MM/keeper are
/// later slices; this contract is the floor/tranche core, fully simulatable.
contract SuffixTreasury is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant K_FLOOR_BPS = 9_000; // floor = 0.9 × par
    uint256 public constant PAR0 = 1e6;          // 1.00 USDC, 6dp
    uint256 public constant UNIT = 1e6;          // 6dp scaling for token math

    IERC20 public immutable USDC;
    SuffixSenior public immutable senior;
    SuffixJunior public immutable junior;
    address public immutable owner; // keeper/governance in MVP (revenue/loss admin)

    /// @notice Internal USDC accounting (donation-proof; never reads balanceOf).
    uint256 public totalUSDC;
    /// @notice Hard backing per senior token, USDC 6dp. Starts at par; ratchets
    /// up from realized revenue only.
    uint256 public floorPar = PAR0;
    /// @notice Minimum junior cushion (bps of senior claim) that redeemJunior
    /// may not strip below — stops a voluntary buffer-strip that would leave the
    /// senior protected only by the k-gap (review FIX-2). Owner-set at launch
    /// (0 = off, MVP default). Does not block redemptions when the cushion is
    /// already below it from losses being reduced further is prevented; junior
    /// is locked under stress until the buffer recovers.
    uint256 public minCushionBps;

    event SeniorSeeded(address indexed to, uint256 usdcIn, uint256 minted);
    event JuniorSeeded(address indexed to, uint256 usdcIn, uint256 minted);
    event SeniorRedeemedAtFloor(address indexed from, uint256 seniorBurned, uint256 usdcOut);
    event JuniorRedeemed(address indexed from, uint256 juniorBurned, uint256 usdcOut);
    event RevenueRecorded(uint256 usdcIn, uint256 seniorRatchetBps, uint256 newFloorPar);
    event LossApplied(uint256 usdcOut, uint256 juniorEquityAfter, bool seniorSolvent);

    error ZeroAmount();
    error NotOwner();
    error InsufficientReserve();
    error OrphanedResidual();
    error BufferLocked();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IERC20 usdc_, address owner_) {
        USDC = usdc_;
        owner = owner_;
        senior = new SuffixSenior(address(this));
        junior = new SuffixJunior(address(this));
    }

    // ─────────────────────────── Views ───────────────────────────

    /// @notice Senior's hard claim = the HardNAV that backs the floor.
    function seniorClaimUSDC() public view returns (uint256) {
        return (senior.totalSupply() * floorPar) / UNIT;
    }

    /// @notice Buyback floor price, USDC 6dp per senior token.
    function seniorFloorPrice() public view returns (uint256) {
        return (K_FLOOR_BPS * floorPar) / BPS;
    }

    /// @notice Residual equity that junior holders own — and that absorbs losses
    /// before the senior claim. Floored at 0 (junior can be fully wiped).
    function juniorEquityUSDC() public view returns (uint256) {
        uint256 claim = seniorClaimUSDC();
        return totalUSDC > claim ? totalUSDC - claim : 0;
    }

    /// @notice Junior NAV per token, USDC 6dp. Par when no junior exists yet.
    function juniorNAVPerToken() public view returns (uint256) {
        uint256 js = junior.totalSupply();
        if (js == 0) return PAR0;
        return (juniorEquityUSDC() * UNIT) / js;
    }

    /// @notice Junior cushion as a fraction of the senior claim, in bps.
    /// type(uint256).max when there is no senior claim yet.
    function cushionBps() external view returns (uint256) {
        uint256 claim = seniorClaimUSDC();
        if (claim == 0) return type(uint256).max;
        return (juniorEquityUSDC() * BPS) / claim;
    }

    /// @notice True while the reserve fully backs the senior claim.
    function seniorSolvent() public view returns (bool) {
        return totalUSDC >= seniorClaimUSDC();
    }

    // ─────────────────────────── Seeding ───────────────────────────

    /// @notice Buy senior at par (floorPar). Floor to exit at is k×par — the
    /// (1−k) gap + junior cushion is the senior's protection.
    function seedSenior(uint256 usdcAmount) external nonReentrant returns (uint256 minted) {
        if (usdcAmount == 0) revert ZeroAmount();
        minted = (usdcAmount * UNIT) / floorPar;
        if (minted == 0) revert ZeroAmount();
        totalUSDC += usdcAmount;
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        senior.mint(msg.sender, minted);
        emit SeniorSeeded(msg.sender, usdcAmount, minted);
    }

    /// @notice Buy junior at current junior NAV/token (the residual-equity price).
    /// @dev FIX-1 (review CRITICAL): when junior supply is 0, juniorNAVPerToken()
    /// reports PAR0 even if residual equity is positive (the k-gap left by senior
    /// sell-at-floor, or the non-ratcheted slice of recordRevenue). Seeding then
    /// would let the first buyer capture that orphaned residual for ~free. Refuse
    /// until the residual is swept to the floor (sweepResidualToFloor). Invariant:
    /// junior supply transitioning to 0 must leave juniorEquityUSDC() == 0.
    function seedJunior(uint256 usdcAmount) external nonReentrant returns (uint256 minted) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (junior.totalSupply() == 0 && juniorEquityUSDC() > 0) revert OrphanedResidual();
        minted = (usdcAmount * UNIT) / juniorNAVPerToken();
        if (minted == 0) revert ZeroAmount();
        totalUSDC += usdcAmount;
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        junior.mint(msg.sender, minted);
        emit JuniorSeeded(msg.sender, usdcAmount, minted);
    }

    /// @notice Sweep ownerless residual equity (junior supply == 0) into the
    /// senior floor — the k-gap surplus strengthens the floor rather than being
    /// captured by the next junior buyer. Permissionless (it only benefits the
    /// senior / the system; no griefing surface). Clears the FIX-1 block.
    function sweepResidualToFloor() external nonReentrant {
        if (junior.totalSupply() != 0) revert OrphanedResidual();
        uint256 resid = juniorEquityUSDC();
        uint256 ss = senior.totalSupply();
        if (resid == 0 || ss == 0) revert ZeroAmount();
        floorPar += (resid * UNIT) / ss;
        emit RevenueRecorded(0, BPS, floorPar);
    }

    // ─────────────────────────── Redemptions ───────────────────────

    /// @notice Sell senior back to the treasury at the buyback floor (k×par).
    /// Paid from reserve only; reverts if the reserve cannot cover it — the
    /// junior is NEVER minted to make this whole (anti-LUNA).
    function redeemSeniorAtFloor(uint256 seniorAmount) external nonReentrant returns (uint256 usdcOut) {
        if (seniorAmount == 0) revert ZeroAmount();
        usdcOut = (seniorAmount * seniorFloorPrice()) / UNIT;
        if (usdcOut > totalUSDC) revert InsufficientReserve();
        totalUSDC -= usdcOut;
        senior.burn(msg.sender, seniorAmount); // reverts if balance/allowance insufficient
        USDC.safeTransfer(msg.sender, usdcOut);
        emit SeniorRedeemedAtFloor(msg.sender, seniorAmount, usdcOut);
    }

    /// @notice Redeem junior for its residual NAV (can be below what was paid in
    /// — that is the first-loss risk junior holders took).
    /// @dev FIX-2 (review HIGH): a withdrawal may not strip the junior cushion
    /// below `minCushionBps` of the senior claim. Without this, all junior could
    /// exit in good times and leave the senior protected only by the k-gap — the
    /// first-loss buffer the design rests on would be freely withdrawable. The
    /// guard makes the buffer sticky: junior is locked while the cushion is at /
    /// below the floor (i.e. exactly under the stress when it must protect
    /// senior). minCushionBps = 0 (MVP default) ⇒ no restriction.
    function redeemJunior(uint256 juniorAmount) external nonReentrant returns (uint256 usdcOut) {
        if (juniorAmount == 0) revert ZeroAmount();
        usdcOut = (juniorAmount * juniorNAVPerToken()) / UNIT;
        if (usdcOut > totalUSDC) revert InsufficientReserve();
        if (minCushionBps > 0) {
            uint256 claim = seniorClaimUSDC();
            if (claim > 0) {
                uint256 newTotal = totalUSDC - usdcOut;
                uint256 newEquity = newTotal > claim ? newTotal - claim : 0;
                if ((newEquity * BPS) / claim < minCushionBps) revert BufferLocked();
            }
        }
        totalUSDC -= usdcOut;
        junior.burn(msg.sender, juniorAmount);
        if (usdcOut > 0) USDC.safeTransfer(msg.sender, usdcOut);
        emit JuniorRedeemed(msg.sender, juniorAmount, usdcOut);
    }

    /// @notice Set the minimum junior cushion (bps of senior claim) that
    /// redeemJunior may not strip below. Launch sets this > 0 to lock the
    /// protocol-owned first-loss buffer (review FIX-2).
    function setMinCushion(uint256 bps) external onlyOwner {
        if (bps > BPS) revert ZeroAmount();
        minCushionBps = bps;
    }

    // ─────────────────── Realized revenue / loss (keeper) ───────────

    /// @notice Book REALIZED revenue (MM spread, POL fees, yield, realized
    /// domain gains). `seniorRatchetBps` of it ratchets the senior floor up
    /// (floorPar); the rest accrues to junior equity. Unrealized marks NEVER
    /// enter here.
    function recordRevenue(uint256 usdcAmount, uint256 seniorRatchetBps) external onlyOwner nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        if (seniorRatchetBps > BPS) revert ZeroAmount();
        totalUSDC += usdcAmount;
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 ss = senior.totalSupply();
        if (ss > 0 && seniorRatchetBps > 0) {
            uint256 ratchetUsdc = (usdcAmount * seniorRatchetBps) / BPS;
            floorPar += (ratchetUsdc * UNIT) / ss;
        }
        emit RevenueRecorded(usdcAmount, seniorRatchetBps, floorPar);
    }

    /// @notice Realize a treasury loss (bad domain write-off, MM loss). Models
    /// value leaving the treasury; junior equity absorbs it first by
    /// construction. MVP/simulation surface (in production, losses arise from
    /// the asset side, not an admin call).
    function applyLoss(uint256 usdcAmount) external onlyOwner nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 out = usdcAmount > totalUSDC ? totalUSDC : usdcAmount;
        totalUSDC -= out;
        USDC.safeTransfer(owner, out);
        emit LossApplied(out, juniorEquityUSDC(), seniorSolvent());
    }
}
