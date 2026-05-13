// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Attestation} from "./Attestation.sol";
import {Registry} from "./Registry.sol";

/// @title Markets
/// @notice Binary prediction markets resolved by Registrai attestations.
/// @dev One market per (feedId, agent, threshold, comparator, expiry, creator, nonce).
///      Trading uses a constant-product market maker over YES/NO shares,
///      with the well-known Polymarket-style "buy via complete-set mint,
///      sell via complete-set burn" formulation.
contract Markets {
    using SafeERC20 for IERC20;

    enum Comparator {
        GreaterThan,
        GreaterOrEqual,
        LessThan,
        LessOrEqual
    }

    enum Phase {
        Trading,
        Resolved
    }

    enum Outcome {
        Yes,
        No
    }

    struct Market {
        // Parameters
        bytes32 feedId;
        address agent;
        int256 threshold;
        Comparator comparator;
        uint256 expiry;
        address creator;
        // AMM reserves (in "shares", same scale as USDC for binary markets)
        uint256 yesReserve;
        uint256 noReserve;
        // Lifecycle
        Phase phase;
        bool yesWon;
        uint256 createdAt;
    }

    Attestation public immutable ATTESTATION;
    Registry public immutable REGISTRY;
    IERC20 public immutable USDC;
    /// @notice Where the protocol's share of trading fees accrues.
    address public immutable TREASURY;

    uint256 public constant MIN_LIQUIDITY = 5e6; // 5 USDC — testnet floor

    // Trading fee economics. 0.70% total per trade, split:
    //   creator 40 bps · agent 20 bps · treasury 10 bps
    // The oracle layer remains free (no Registry fees). Fees only on Markets.
    uint256 public constant FEE_BPS_CREATOR = 40;
    uint256 public constant FEE_BPS_AGENT = 20;
    uint256 public constant FEE_BPS_TREASURY = 10;
    uint256 public constant FEE_BPS_TOTAL = FEE_BPS_CREATOR + FEE_BPS_AGENT + FEE_BPS_TREASURY;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    mapping(bytes32 => Market) internal _markets;
    /// @notice marketId → user → share balance per outcome.
    mapping(bytes32 => mapping(address => uint256)) public yesBalance;
    mapping(bytes32 => mapping(address => uint256)) public noBalance;
    /// @notice incrementing nonce per creator so the same params can be re-used.
    mapping(address => uint256) public createdBy;
    /// @notice Cumulative fee earnings per recipient — useful for dashboards.
    mapping(address => uint256) public feeEarnings;

    event MarketCreated(
        bytes32 indexed marketId,
        address indexed creator,
        bytes32 indexed feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    );
    event Bought(
        bytes32 indexed marketId,
        address indexed buyer,
        Outcome outcome,
        uint256 collateralIn,
        uint256 sharesOut
    );
    event Sold(
        bytes32 indexed marketId,
        address indexed seller,
        Outcome outcome,
        uint256 sharesIn,
        uint256 collateralOut
    );
    event Resolved(bytes32 indexed marketId, bool yesWon, int256 attestedValue);
    event Redeemed(bytes32 indexed marketId, address indexed user, uint256 collateral);
    event FeesPaid(
        bytes32 indexed marketId,
        uint256 grossCollateral,
        uint256 creatorFee,
        uint256 agentFee,
        uint256 treasuryFee
    );

    error MarketExists();
    error MarketMissing();
    error MarketExpired();
    error MarketNotExpired();
    error AlreadyResolved();
    error NotTrading();
    error NotResolved();
    error BadExpiry();
    error LiquidityTooLow();
    error InsufficientShares();
    error SlippageExceeded();
    error AttestationNotFound();
    error AttestationNotFinalized();
    error AgentNotRegistered();
    error BadTreasury();

    constructor(Attestation attestation_, Registry registry_, IERC20 usdc, address treasury_) {
        if (treasury_ == address(0)) revert BadTreasury();
        ATTESTATION = attestation_;
        REGISTRY = registry_;
        USDC = usdc;
        TREASURY = treasury_;
    }

    // --- Market lifecycle ---

    /// @notice Create a new prediction market.
    /// @param feedId the Registrai feed id
    /// @param agent the agent address whose attestations resolve this market
    /// @param threshold value compared against the attested value at expiry
    /// @param comparator comparison operator (e.g. > threshold)
    /// @param expiry unix timestamp at which the market resolves
    /// @param liquidity initial USDC seeded by the creator (sets starting odds at 50/50)
    function createMarket(
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    ) external returns (bytes32 marketId) {
        if (expiry <= block.timestamp) revert BadExpiry();
        if (liquidity < MIN_LIQUIDITY) revert LiquidityTooLow();
        // A market is only resolvable if its agent is actively bonded on the feed.
        // Without this, anyone could lock USDC in markets that no one will ever
        // attest to. (audit M9)
        if (!REGISTRY.isActiveAgent(feedId, agent)) revert AgentNotRegistered();

        uint256 nonce = createdBy[msg.sender]++;
        marketId = keccak256(
            abi.encode(msg.sender, nonce, feedId, agent, threshold, comparator, expiry)
        );
        if (_markets[marketId].createdAt != 0) revert MarketExists();

        USDC.safeTransferFrom(msg.sender, address(this), liquidity);

        // Seeding `liquidity` USDC mints `liquidity` complete sets, all held
        // by the pool initially. Pool starts at 50/50 odds.
        _markets[marketId] = Market({
            feedId: feedId,
            agent: agent,
            threshold: threshold,
            comparator: comparator,
            expiry: expiry,
            creator: msg.sender,
            yesReserve: liquidity,
            noReserve: liquidity,
            phase: Phase.Trading,
            yesWon: false,
            createdAt: block.timestamp
        });

        emit MarketCreated(marketId, msg.sender, feedId, agent, threshold, comparator, expiry, liquidity);
    }

    // --- Trading ---

    /// @notice Buy YES or NO shares with USDC. Reverts if shares received are below minSharesOut.
    function buy(bytes32 marketId, Outcome outcome, uint256 collateralIn, uint256 minSharesOut)
        external
        returns (uint256 sharesOut)
    {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert NotTrading();
        if (block.timestamp >= m.expiry) revert MarketExpired();
        if (collateralIn == 0) revert LiquidityTooLow();

        USDC.safeTransferFrom(msg.sender, address(this), collateralIn);

        // Skim the trading fee BEFORE the AMM math so the pool only receives
        // the effective amount. Fees flow to the creator (curates), the agent
        // (provides the data), and the protocol treasury (sustains ops).
        uint256 effectiveIn = _payFees(marketId, m, collateralIn);

        // Mint complete sets on `effectiveIn`: both reserves grow by that
        // amount. Then send the user the bought outcome maintaining x*y=k.
        uint256 yesAfterMint = m.yesReserve + effectiveIn;
        uint256 noAfterMint = m.noReserve + effectiveIn;
        uint256 k = m.yesReserve * m.noReserve;

        if (outcome == Outcome.Yes) {
            sharesOut = yesAfterMint - Math.ceilDiv(k, noAfterMint);
            m.yesReserve = yesAfterMint - sharesOut;
            m.noReserve = noAfterMint;
            yesBalance[marketId][msg.sender] += sharesOut;
        } else {
            sharesOut = noAfterMint - Math.ceilDiv(k, yesAfterMint);
            m.noReserve = noAfterMint - sharesOut;
            m.yesReserve = yesAfterMint;
            noBalance[marketId][msg.sender] += sharesOut;
        }

        if (sharesOut < minSharesOut) revert SlippageExceeded();
        emit Bought(marketId, msg.sender, outcome, collateralIn, sharesOut);
    }

    /// @notice Sell YES or NO shares back to the pool for USDC.
    /// @dev Solves the constant-product invariant for collateralOut given sharesIn.
    function sell(bytes32 marketId, Outcome outcome, uint256 sharesIn, uint256 minCollateralOut)
        external
        returns (uint256 collateralOut)
    {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert NotTrading();
        if (block.timestamp >= m.expiry) revert MarketExpired();
        if (sharesIn == 0) revert LiquidityTooLow();

        // Burn user's shares.
        if (outcome == Outcome.Yes) {
            if (yesBalance[marketId][msg.sender] < sharesIn) revert InsufficientShares();
            yesBalance[marketId][msg.sender] -= sharesIn;
        } else {
            if (noBalance[marketId][msg.sender] < sharesIn) revert InsufficientShares();
            noBalance[marketId][msg.sender] -= sharesIn;
        }

        // Solve (yesPostSell - cOut)(noPostSell - cOut) = k
        // where yesPostSell, noPostSell are the reserves with the user's
        // shares added in. After we extract cOut USDC, the pool burns cOut
        // complete sets (removing cOut from BOTH reserves).
        uint256 yesPostSell;
        uint256 noPostSell;
        if (outcome == Outcome.Yes) {
            yesPostSell = m.yesReserve + sharesIn;
            noPostSell = m.noReserve;
        } else {
            yesPostSell = m.yesReserve;
            noPostSell = m.noReserve + sharesIn;
        }
        uint256 k = m.yesReserve * m.noReserve;
        // r^2 - (a+b)r + (ab - k) = 0  ⇒  r = ((a+b) - sqrt((a+b)^2 - 4(ab-k))) / 2
        uint256 a = yesPostSell;
        uint256 b = noPostSell;
        uint256 sumAB = a + b;
        uint256 prodAB = a * b;
        // prodAB ≥ k always (we just added shares), and the smaller root is the
        // physically meaningful one (positive collateral, ≤ min reserve).
        uint256 disc = sumAB * sumAB - 4 * (prodAB - k);
        uint256 grossOut = (sumAB - Math.sqrt(disc)) / 2;

        // Fee is taken from the gross collateral on exit, same shape as buy.
        uint256 fee = (grossOut * FEE_BPS_TOTAL) / BPS_DENOMINATOR;
        collateralOut = grossOut - fee;

        if (collateralOut < minCollateralOut) revert SlippageExceeded();

        // Pool burns `grossOut` complete sets — both reserves shrink by gross.
        m.yesReserve = yesPostSell - grossOut;
        m.noReserve = noPostSell - grossOut;

        // Pay fees from the burned collateral, send rest to seller.
        _distributeFees(marketId, m, grossOut, fee);

        USDC.safeTransfer(msg.sender, collateralOut);
        emit Sold(marketId, msg.sender, outcome, sharesIn, collateralOut);
    }

    // --- Fees ---

    /// @dev Splits `grossIn` into the trading fee + the effective amount that
    ///      enters the pool. Pays fees out in this same call.
    function _payFees(bytes32 marketId, Market storage m, uint256 grossIn)
        internal
        returns (uint256 effectiveIn)
    {
        uint256 fee = (grossIn * FEE_BPS_TOTAL) / BPS_DENOMINATOR;
        effectiveIn = grossIn - fee;
        _distributeFees(marketId, m, grossIn, fee);
    }

    function _distributeFees(
        bytes32 marketId,
        Market storage m,
        uint256 grossCollateral,
        uint256 totalFee
    ) internal {
        if (totalFee == 0) return;
        uint256 creatorFee = (grossCollateral * FEE_BPS_CREATOR) / BPS_DENOMINATOR;
        uint256 agentFee = (grossCollateral * FEE_BPS_AGENT) / BPS_DENOMINATOR;
        // treasury gets the remainder so rounding never strands wei.
        uint256 treasuryFee = totalFee - creatorFee - agentFee;

        if (creatorFee > 0) {
            feeEarnings[m.creator] += creatorFee;
            USDC.safeTransfer(m.creator, creatorFee);
        }
        if (agentFee > 0) {
            feeEarnings[m.agent] += agentFee;
            USDC.safeTransfer(m.agent, agentFee);
        }
        if (treasuryFee > 0) {
            feeEarnings[TREASURY] += treasuryFee;
            USDC.safeTransfer(TREASURY, treasuryFee);
        }
        emit FeesPaid(marketId, grossCollateral, creatorFee, agentFee, treasuryFee);
    }

    // --- Resolution ---

    /// @notice After expiry, anyone can resolve by reading the attestation that
    ///         was valid at the expiry timestamp.
    function resolve(bytes32 marketId) external {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase == Phase.Resolved) revert AlreadyResolved();
        if (block.timestamp < m.expiry) revert MarketNotExpired();

        (int256 value, bool finalized) = ATTESTATION.valueAt(m.feedId, m.agent, m.expiry);
        if (value == 0 && !finalized) {
            // valueAt returns (0, false) when there is no attestation at or
            // before the expiry; the chain has no truth to resolve against.
            revert AttestationNotFound();
        }
        if (!finalized) revert AttestationNotFinalized();

        bool yesWon = _evaluate(value, m.threshold, m.comparator);
        m.yesWon = yesWon;
        m.phase = Phase.Resolved;
        emit Resolved(marketId, yesWon, value);
    }

    function _evaluate(int256 value, int256 threshold, Comparator c) internal pure returns (bool) {
        if (c == Comparator.GreaterThan) return value > threshold;
        if (c == Comparator.GreaterOrEqual) return value >= threshold;
        if (c == Comparator.LessThan) return value < threshold;
        return value <= threshold;
    }

    /// @notice After resolution, holders of the winning outcome redeem 1 USDC per share.
    function redeem(bytes32 marketId) external returns (uint256 payout) {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Resolved) revert NotResolved();

        if (m.yesWon) {
            payout = yesBalance[marketId][msg.sender];
            yesBalance[marketId][msg.sender] = 0;
        } else {
            payout = noBalance[marketId][msg.sender];
            noBalance[marketId][msg.sender] = 0;
        }
        if (payout == 0) revert InsufficientShares();

        USDC.safeTransfer(msg.sender, payout);
        emit Redeemed(marketId, msg.sender, payout);
    }

    // --- Views ---

    function getMarket(bytes32 marketId) external view returns (Market memory) {
        return _markets[marketId];
    }

    /// @notice YES price = noReserve / (yesReserve + noReserve), scaled to 1e18.
    function priceOf(bytes32 marketId, Outcome outcome) external view returns (uint256) {
        Market memory m = _markets[marketId];
        if (m.createdAt == 0) return 0;
        uint256 total = m.yesReserve + m.noReserve;
        if (total == 0) return 0;
        uint256 other = outcome == Outcome.Yes ? m.noReserve : m.yesReserve;
        return (other * 1e18) / total;
    }
}
