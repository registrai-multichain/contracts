// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
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
contract SuffixTreasury is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Param-setting / sensitive ops. In production this role is held by
    /// a TimelockController (delayed, governed) — NOT an EOA.
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    /// @notice Operational ops (booking revenue, compounding). Can be a hot
    /// keeper key; cannot change risk parameters.
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant BPS = 10_000;
    uint256 public constant K_FLOOR_BPS = 9_000; // floor = 0.9 × par
    uint256 public constant PAR0 = 1e6;          // 1.00 USDC, 6dp
    uint256 public constant UNIT = 1e6;          // 6dp scaling for token math
    uint256 public constant SWAP_FEE_BPS = 30;   // 0.30% protocol-owned-liquidity fee → revenue
    uint256 public constant M_FROTH_BPS = 14_000; // froth band top = 1.4 × senior FV (floorPar)
    uint256 public constant KEEPER_REWARD_BPS = 50; // 0.5% of a harvest paid to the caller

    IERC20 public immutable USDC;
    SuffixSenior public immutable senior;
    SuffixJunior public immutable junior;

    /// @notice Internal USDC accounting (donation-proof; never reads balanceOf).
    uint256 public totalUSDC;
    /// @notice Hard backing per senior token, USDC 6dp. Starts at par; ratchets
    /// up from realized revenue only.
    uint256 public floorPar = PAR0;
    /// @notice Max EXTERNAL senior supply (the bounded launch float of the
    /// hybrid supply model). 0 = uncapped. seedSenior reverts past it. The
    /// elastic leg is junior; senior is governed/bounded. GOVERNOR-set.
    uint256 public seniorCap;
    // ── Protocol-owned AMM ("the suffix pool"): a 100%-POL constant-product
    // $ai/USDC market embedded in the treasury. Public trades pay SWAP_FEE_BPS,
    // which banks as REALIZED revenue (feesBankUsdc) and is skimmed into the
    // floor ratchet. Pool-held senior (poolAi) is treasury-owned and EXCLUDED
    // from the senior claim. The pool price is kept near the floor by
    // arbitrage against redeemSeniorAtFloor (buy cheap from pool → redeem at
    // floor), so no deterministic, front-runnable keeper order is needed to
    // defend it. (Froth-harvest / keeper-auction MM is a later slice.)
    uint256 public poolAi;
    uint256 public poolUsdc;
    /// @notice Realized swap fees awaiting skim into the floor (USDC 6dp).
    uint256 public feesBankUsdc;

    /// @notice Minimum junior cushion (bps of senior claim) that redeemJunior
    /// may not strip below — stops a voluntary buffer-strip that would leave the
    /// senior protected only by the k-gap (review FIX-2). Owner-set at launch
    /// (0 = off, MVP default). Does not block redemptions when the cushion is
    /// already below it from losses being reduced further is prevented; junior
    /// is locked under stress until the buffer recovers.
    uint256 public minCushionBps;

    /// @notice Competitive Dutch-auction MM (the anti-LVR upside harvester): a
    /// block of newly-minted senior offered at a declining price. Takers compete
    /// on timing (earlier = dearer); proceeds above par are revenue. Auction
    /// inventory is treasury-owned and excluded from the senior claim until sold.
    struct Auction {
        uint256 ai;         // senior remaining in the auction
        uint256 startPrice; // USDC 6dp per $ai at t0
        uint256 floorPrice; // USDC 6dp per $ai at/after end (≥ floorPar)
        uint64 start;
        uint64 duration;
        bool active;
    }
    Auction public auction;

    event SeniorSeeded(address indexed to, uint256 usdcIn, uint256 minted);
    event JuniorSeeded(address indexed to, uint256 usdcIn, uint256 minted);
    event SeniorRedeemedAtFloor(address indexed from, uint256 seniorBurned, uint256 usdcOut);
    event JuniorRedeemed(address indexed from, uint256 juniorBurned, uint256 usdcOut);
    event RevenueRecorded(uint256 usdcIn, uint256 seniorRatchetBps, uint256 newFloorPar);
    event LossApplied(uint256 usdcOut, uint256 juniorEquityAfter, bool seniorSolvent);
    event PolProvisioned(uint256 usdcIn, uint256 aiMinted, uint256 spotPrice);
    event AiBought(address indexed buyer, uint256 usdcIn, uint256 aiOut, uint256 fee);
    event AiSold(address indexed seller, uint256 aiIn, uint256 usdcOut, uint256 fee);
    event RevenueSkimmed(uint256 fees, uint256 seniorRatchetBps, uint256 newFloorPar);
    event FrothHarvested(address indexed keeper, uint256 skimmed, uint256 keeperReward, uint256 priceAfter);
    event FeesCompounded(uint256 usdcIn, uint256 aiMinted);
    event AuctionOpened(uint256 ai, uint256 startPrice, uint256 floorPrice, uint64 duration);
    event AuctionTaken(address indexed taker, uint256 ai, uint256 price, uint256 cost, uint256 premium);
    event AuctionClosed(uint256 unsoldBurned);

    error ZeroAmount();
    error InsufficientReserve();
    error OrphanedResidual();
    error BufferLocked();
    error SlippageExceeded();
    error PoolEmpty();
    error NotInFrothBand();
    error SeniorCapExceeded();
    error AuctionActive();
    error NoAuction();
    error BadAuctionParams();

    /// @param admin gets DEFAULT_ADMIN + GOVERNOR + KEEPER. In production, grant
    /// GOVERNOR_ROLE to a TimelockController and renounce the EOA's governor/admin
    /// roles (see DeploySuffix). KEEPER may stay a hot key.
    /// @param name_ human name of the suffix, e.g. "Suffix AI".
    /// @param symbol_ senior ticker, e.g. "ai" (junior becomes "<symbol>LP").
    ///        Each suffix ($ai, $xyz, $fun, …) is its own deployment.
    constructor(IERC20 usdc_, address admin, string memory name_, string memory symbol_) {
        USDC = usdc_;
        senior = new SuffixSenior(address(this), string.concat(name_, " (senior)"), symbol_);
        junior = new SuffixJunior(address(this), string.concat(name_, " (junior)"), string.concat(symbol_, "LP"));
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
    }

    // ─────────────────────────── Views ───────────────────────────

    /// @notice Senior held externally (not in the protocol-owned pool, not held
    /// as live auction inventory) — the only senior that is a real claim on the
    /// floor. Pool + auction senior are treasury-owned.
    function externalSeniorSupply() public view returns (uint256) {
        uint256 held = poolAi + (auction.active ? auction.ai : 0);
        uint256 ts = senior.totalSupply();
        return ts > held ? ts - held : 0;
    }

    /// @notice Senior's hard claim = the HardNAV that backs the floor. Excludes
    /// pool-held (treasury-owned) senior, which is not a liability to itself.
    function seniorClaimUSDC() public view returns (uint256) {
        return (externalSeniorSupply() * floorPar) / UNIT;
    }

    /// @notice Spot price of $ai in USDC (6dp) on the protocol-owned pool.
    function aiSpotPrice() public view returns (uint256) {
        return poolAi == 0 ? 0 : (poolUsdc * UNIT) / poolAi;
    }

    /// @notice Top of the meme/froth band — the price above which harvest acts.
    function frothPriceUSDC() public view returns (uint256) {
        return (M_FROTH_BPS * floorPar) / BPS;
    }

    /// @notice Pool USDC sitting ABOVE the froth band (the harvestable premium),
    /// i.e. how much could be skimmed to bring the pool price down to m×FV.
    function harvestablePremiumUSDC() public view returns (uint256) {
        if (poolAi == 0) return 0;
        uint256 target = (poolAi * frothPriceUSDC()) / UNIT; // poolUsdc at price = m×FV
        return poolUsdc > target ? poolUsdc - target : 0;
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
        // Bounded senior float (hybrid supply model): external senior may not
        // exceed seniorCap. 0 = uncapped. Pool-held senior is excluded.
        if (seniorCap != 0 && externalSeniorSupply() + minted > seniorCap) {
            revert SeniorCapExceeded();
        }
        totalUSDC += usdcAmount;
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        senior.mint(msg.sender, minted);
        emit SeniorSeeded(msg.sender, usdcAmount, minted);
    }

    /// @notice Set the bounded senior float cap (GOVERNOR / timelock). 0 = off.
    function setSeniorCap(uint256 cap) external onlyRole(GOVERNOR_ROLE) {
        seniorCap = cap;
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
        uint256 ss = externalSeniorSupply();
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
    function setMinCushion(uint256 bps) external onlyRole(GOVERNOR_ROLE) {
        if (bps > BPS) revert ZeroAmount();
        minCushionBps = bps;
    }

    // ─────────────────── Realized revenue / loss (keeper) ───────────

    /// @notice Book REALIZED revenue (MM spread, POL fees, yield, realized
    /// domain gains). `seniorRatchetBps` of it ratchets the senior floor up
    /// (floorPar); the rest accrues to junior equity. Unrealized marks NEVER
    /// enter here.
    function recordRevenue(uint256 usdcAmount, uint256 seniorRatchetBps) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        if (seniorRatchetBps > BPS) revert ZeroAmount();
        totalUSDC += usdcAmount;
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 ss = externalSeniorSupply();
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
    function applyLoss(uint256 usdcAmount) external onlyRole(GOVERNOR_ROLE) nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 out = usdcAmount > totalUSDC ? totalUSDC : usdcAmount;
        totalUSDC -= out;
        USDC.safeTransfer(msg.sender, out);
        emit LossApplied(out, juniorEquityUSDC(), seniorSolvent());
    }

    // ───────────────── Protocol-owned AMM (revenue engine) ─────────────────

    /// @notice Seed/extend the protocol-owned $ai/USDC pool. Mints `aiMint`
    /// senior INTO the pool (treasury-owned ⇒ excluded from the senior claim)
    /// and pairs it with `usdcAmount`. Sets/moves the spot price. POL is held by
    /// the protocol from day one — no mercenary LPs. Kept separate from the
    /// floor reserve (totalUSDC): POL is a revenue source, not floor backing.
    function provisionPOL(uint256 usdcAmount, uint256 aiMint) external onlyRole(GOVERNOR_ROLE) nonReentrant {
        if (usdcAmount == 0 || aiMint == 0) revert ZeroAmount();
        poolAi += aiMint;
        poolUsdc += usdcAmount;
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);
        senior.mint(address(this), aiMint); // pool-held; excluded from claim
        emit PolProvisioned(usdcAmount, aiMint, aiSpotPrice());
    }

    /// @notice Buy $ai from the pool. Pays SWAP_FEE_BPS, which banks as realized
    /// revenue (feesBankUsdc). The $ai leaves the pool to the buyer and becomes
    /// an external claim. Constant-product on the post-fee input.
    function buyAi(uint256 usdcIn, uint256 minAiOut) external nonReentrant returns (uint256 aiOut) {
        if (usdcIn == 0) revert ZeroAmount();
        if (poolAi == 0 || poolUsdc == 0) revert PoolEmpty();
        uint256 fee = (usdcIn * SWAP_FEE_BPS) / BPS;
        uint256 net = usdcIn - fee;
        aiOut = (poolAi * net) / (poolUsdc + net);
        if (aiOut < minAiOut || aiOut == 0 || aiOut >= poolAi) revert SlippageExceeded();
        poolUsdc += net;
        poolAi -= aiOut;
        feesBankUsdc += fee;
        USDC.safeTransferFrom(msg.sender, address(this), usdcIn);
        senior.transfer(msg.sender, aiOut); // treasury(pool) → buyer
        emit AiBought(msg.sender, usdcIn, aiOut, fee);
    }

    /// @notice Sell $ai to the pool. Fee taken from the USDC out and banked as
    /// revenue. The $ai returns to the pool (claim drops). Seller must approve
    /// the treasury for `aiIn` first.
    function sellAi(uint256 aiIn, uint256 minUsdcOut) external nonReentrant returns (uint256 usdcOut) {
        if (aiIn == 0) revert ZeroAmount();
        if (poolAi == 0 || poolUsdc == 0) revert PoolEmpty();
        uint256 usdcGross = (poolUsdc * aiIn) / (poolAi + aiIn);
        if (usdcGross >= poolUsdc) revert SlippageExceeded();
        uint256 fee = (usdcGross * SWAP_FEE_BPS) / BPS;
        usdcOut = usdcGross - fee;
        if (usdcOut < minUsdcOut || usdcOut == 0) revert SlippageExceeded();
        poolAi += aiIn;
        poolUsdc -= usdcGross;
        feesBankUsdc += fee;
        senior.transferFrom(msg.sender, address(this), aiIn); // buyer → treasury(pool)
        USDC.safeTransfer(msg.sender, usdcOut);
        emit AiSold(msg.sender, aiIn, usdcOut, fee);
    }

    /// @notice Move banked swap fees into the floor reserve and ratchet the
    /// senior floor up by `seniorRatchetBps` of them (the rest grows junior
    /// equity). This is the revenue→floor transmission: degen churn → fees →
    /// a higher floor. Permissionless (it only adds value); keeper-callable.
    function skimRevenueToFloor(uint256 seniorRatchetBps) external nonReentrant {
        if (seniorRatchetBps > BPS) revert ZeroAmount();
        uint256 amt = feesBankUsdc;
        if (amt == 0) revert ZeroAmount();
        feesBankUsdc = 0;
        totalUSDC += amt; // fees were already in the contract; reclassify to reserve
        uint256 ss = externalSeniorSupply();
        if (ss > 0 && seniorRatchetBps > 0) {
            uint256 ratchetUsdc = (amt * seniorRatchetBps) / BPS;
            floorPar += (ratchetUsdc * UNIT) / ss;
        }
        emit RevenueSkimmed(amt, seniorRatchetBps, floorPar);
    }

    /// @notice Harvest froth: when the pool price is above the band top (m×FV),
    /// skim the pool's above-band USDC premium into realized revenue, bringing
    /// the price back down to m×FV (the meme keeps the whole band BELOW that).
    /// Permissionless + a small keeper reward, so it self-executes — and because
    /// it only extracts a premium that already exists in the pool (no public
    /// limit order is posted), there is nothing for an informed trader to
    /// front-run. (A competitive batch-auction MM is a later refinement.)
    /// The DOWNSIDE band is defended separately by arbitrage against
    /// redeemSeniorAtFloor — harvest is the UPSIDE half.
    function harvestFroth(uint256 maxSkim) external nonReentrant returns (uint256 skim) {
        if (poolAi == 0 || poolUsdc == 0) revert PoolEmpty();
        if (aiSpotPrice() <= frothPriceUSDC()) revert NotInFrothBand();
        uint256 premium = harvestablePremiumUSDC();
        skim = maxSkim == 0 || maxSkim > premium ? premium : maxSkim;
        if (skim == 0) revert NotInFrothBand();
        poolUsdc -= skim;
        uint256 reward = (skim * KEEPER_REWARD_BPS) / BPS;
        feesBankUsdc += skim - reward; // realized → skimmable to the floor
        if (reward > 0) USDC.safeTransfer(msg.sender, reward);
        emit FrothHarvested(msg.sender, skim, reward, aiSpotPrice());
    }

    /// @notice Compound banked fees back into the protocol-owned pool to DEEPEN
    /// liquidity (more depth → more future fee revenue), instead of skimming
    /// them to the floor. Mints matching $ai at the current price so the price
    /// is unchanged; the minted $ai is pool-held (excluded from the claim).
    /// Governance chooses the split between this and skimRevenueToFloor.
    function compoundFeesToPOL(uint256 amount) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (amount == 0 || amount > feesBankUsdc) revert ZeroAmount();
        if (poolAi == 0 || poolUsdc == 0) revert PoolEmpty();
        uint256 aiMint = (amount * poolAi) / poolUsdc; // keep price flat
        feesBankUsdc -= amount;
        poolUsdc += amount;
        poolAi += aiMint;
        senior.mint(address(this), aiMint);
        emit FeesCompounded(amount, aiMint);
    }

    // ───────────────── Competitive Dutch-auction MM ─────────────────

    /// @notice Current Dutch-auction clearing price (USDC 6dp per $ai), linearly
    /// declining startPrice → floorPrice over the window. 0 if none active.
    function dutchPrice() public view returns (uint256) {
        if (!auction.active) return 0;
        uint256 elapsed = block.timestamp - auction.start;
        if (elapsed >= auction.duration) return auction.floorPrice;
        uint256 drop = ((auction.startPrice - auction.floorPrice) * elapsed) / auction.duration;
        return auction.startPrice - drop;
    }

    /// @notice Open a Dutch auction of `aiBlock` newly-minted senior, price
    /// declining startPrice → floorPrice over `duration`. floorPrice must be ≥
    /// floorPar so the protocol never sells senior below the claim it creates.
    /// GOVERNOR-gated (timelock). Inventory is excluded from the claim until sold.
    function openDutchAuction(uint256 aiBlock, uint256 startPrice, uint256 floorPrice, uint64 duration)
        external onlyRole(GOVERNOR_ROLE)
    {
        if (auction.active) revert AuctionActive();
        if (aiBlock == 0 || duration == 0) revert BadAuctionParams();
        if (floorPrice < floorPar || startPrice < floorPrice) revert BadAuctionParams();
        auction = Auction({
            ai: aiBlock, startPrice: startPrice, floorPrice: floorPrice,
            start: uint64(block.timestamp), duration: duration, active: true
        });
        senior.mint(address(this), aiBlock); // held as auction inventory (excluded from claim)
        emit AuctionOpened(aiBlock, startPrice, floorPrice, duration);
    }

    /// @notice Take up to `aiWant` from the live auction at the current price
    /// (revert if it exceeds `maxPrice` — slippage). The par-value portion backs
    /// the new senior claim; the premium above par is realized revenue. Competes
    /// purely on timing (earlier = dearer), so there is no front-running edge.
    function takeDutch(uint256 aiWant, uint256 maxPrice) external nonReentrant returns (uint256 aiOut) {
        if (!auction.active) revert NoAuction();
        uint256 price = dutchPrice();
        if (price > maxPrice) revert SlippageExceeded();
        aiOut = aiWant > auction.ai ? auction.ai : aiWant;
        if (aiOut == 0) revert ZeroAmount();
        if (seniorCap != 0 && externalSeniorSupply() + aiOut > seniorCap) revert SeniorCapExceeded();

        uint256 cost = (aiOut * price) / UNIT;
        uint256 parPortion = (aiOut * floorPar) / UNIT;
        uint256 premium = cost > parPortion ? cost - parPortion : 0;

        auction.ai -= aiOut;
        if (auction.ai == 0) auction.active = false;
        totalUSDC += parPortion;       // backs the newly-external senior claim
        feesBankUsdc += premium;       // above-par proceeds → realized revenue

        USDC.safeTransferFrom(msg.sender, address(this), cost);
        senior.transfer(msg.sender, aiOut); // inventory → taker (now external)
        emit AuctionTaken(msg.sender, aiOut, price, cost, premium);
    }

    /// @notice Close the auction and burn any unsold inventory. GOVERNOR-gated.
    function closeDutchAuction() external onlyRole(GOVERNOR_ROLE) {
        if (!auction.active) revert NoAuction();
        uint256 unsold = auction.ai;
        auction.active = false;
        auction.ai = 0;
        if (unsold > 0) senior.burn(address(this), unsold);
        emit AuctionClosed(unsold);
    }
}
