// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Registry} from "../Registry.sol";
import {Attestation} from "../Attestation.sol";
import {NanoLedger} from "./NanoLedger.sol";

/// @title MarketsV4. A binary prediction market settled entirely on NanoLedger.
/// @notice Same constant-product AMM as Markets, but ALL value moves as
///         NanoLedger internal-balance accounting instead of ERC20 transfers:
///           - collateral in: ledger.transferFromInternal(trader -> this)
///           - collateral out / payouts: ledger.internalTransfer(this -> trader)
///           - the per-trade fee: ONE ledger.accrue(marketId, fee) write that
///             distributes to creator/agent/treasury by share; recipients claim
///             lazily via ledger.claim(marketId).
///         So a trade does zero ERC20 transfers and one fee write instead of
///         three pushes, and traders/creators just hold ledger balances. Real
///         USDC only crosses at NanoLedger.deposit/withdraw. Oracle-resolved via
///         Attestation, exactly like Markets (markets pass agent = the oracle).
///
/// MarketsV4 must be registered as a NanoLedger source (setSource) so it can
/// create + credit fee pools. Traders approve MarketsV4 on the ledger
/// (approveSpender) before trading.
contract MarketsV4 is ReentrancyGuard {
    enum Outcome { Yes, No }
    enum Comparator { GreaterThan, GreaterOrEqual, LessThan, LessOrEqual }
    enum Phase { Trading, Resolved }

    struct Market {
        bytes32 feedId;
        address agent;
        int256 threshold;
        Comparator comparator;
        uint256 expiry;
        address creator;
        uint256 yesReserve;
        uint256 noReserve;
        Phase phase;
        bool yesWon;
        uint256 createdAt;
    }

    NanoLedger public immutable LEDGER;
    Registry public immutable REGISTRY;
    Attestation public immutable ATTESTATION;
    address public immutable TREASURY;

    uint256 public constant MIN_LIQUIDITY = 5e6;
    uint256 public constant FEE_BPS_CREATOR = 40;
    uint256 public constant FEE_BPS_AGENT = 20;
    uint256 public constant FEE_BPS_TREASURY = 10;
    uint256 public constant FEE_BPS_TOTAL = 70;
    uint256 private constant BPS = 10_000;

    mapping(bytes32 => Market) internal _markets;
    mapping(bytes32 => mapping(address => uint256)) public yesBalance;
    mapping(bytes32 => mapping(address => uint256)) public noBalance;
    mapping(address => uint256) public createdBy;
    mapping(bytes32 => mapping(address => uint256)) public lpShares;
    mapping(bytes32 => uint256) public totalLpShares;
    mapping(bytes32 => uint256) public lpPotAtResolution;

    event MarketCreated(bytes32 indexed marketId, address indexed creator, bytes32 indexed feedId, address agent, int256 threshold, Comparator comparator, uint256 expiry, uint256 liquidity);
    event Bought(bytes32 indexed marketId, address indexed buyer, Outcome outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee);
    event Sold(bytes32 indexed marketId, address indexed seller, Outcome outcome, uint256 sharesIn, uint256 collateralOut, uint256 fee);
    event Resolved(bytes32 indexed marketId, bool yesWon, int256 value);
    event Redeemed(bytes32 indexed marketId, address indexed holder, uint256 payout);
    event LPClaimed(bytes32 indexed marketId, address indexed lp, uint256 payout);

    error MarketMissing();
    error MarketExists();
    error NotTrading();
    error MarketExpired();
    error MarketNotExpired();
    error AlreadyResolved();
    error NotResolved();
    error AmountTooLow();
    error LiquidityTooLow();
    error BadExpiry();
    error AgentNotRegistered();
    error SlippageExceeded();
    error InsufficientShares();
    error NoLPShares();
    error AttestationNotFound();
    error AttestationNotFinalized();

    constructor(NanoLedger ledger_, Registry registry_, Attestation attestation_, address treasury_) {
        if (treasury_ == address(0)) revert AmountTooLow();
        LEDGER = ledger_;
        REGISTRY = registry_;
        ATTESTATION = attestation_;
        TREASURY = treasury_;
    }

    // ───────────────────────────── create ─────────────────────────────

    function createMarket(
        bytes32 feedId,
        address agent,
        int256 threshold,
        Comparator comparator,
        uint256 expiry,
        uint256 liquidity
    ) external nonReentrant returns (bytes32 marketId) {
        if (expiry <= block.timestamp) revert BadExpiry();
        if (liquidity < MIN_LIQUIDITY) revert LiquidityTooLow();
        if (!REGISTRY.isActiveAgent(feedId, agent)) revert AgentNotRegistered();

        uint256 nonce = createdBy[msg.sender]++;
        marketId = keccak256(abi.encode(msg.sender, nonce, feedId, agent, threshold, comparator, expiry));
        if (_markets[marketId].createdAt != 0) revert MarketExists();

        // pull seed liquidity from the creator's ledger balance (approved)
        LEDGER.transferFromInternal(msg.sender, address(this), liquidity);

        _markets[marketId] = Market({
            feedId: feedId, agent: agent, threshold: threshold, comparator: comparator,
            expiry: expiry, creator: msg.sender, yesReserve: liquidity, noReserve: liquidity,
            phase: Phase.Trading, yesWon: false, createdAt: block.timestamp
        });
        lpShares[marketId][msg.sender] = liquidity;
        totalLpShares[marketId] = liquidity;

        // fee pool: creator 40 / agent 20 / treasury 10 bps, deduped by address.
        LEDGER.createPool(marketId);
        _setFeeShares(marketId, msg.sender, agent);

        emit MarketCreated(marketId, msg.sender, feedId, agent, threshold, comparator, expiry, liquidity);
    }

    function _setFeeShares(bytes32 marketId, address creator, address agent) internal {
        address[3] memory who = [creator, agent, TREASURY];
        uint256[3] memory bps = [FEE_BPS_CREATOR, FEE_BPS_AGENT, FEE_BPS_TREASURY];
        for (uint256 i; i < 3; i++) {
            // only the first occurrence of an address sets its summed share
            bool first = true;
            for (uint256 j; j < i; j++) { if (who[j] == who[i]) { first = false; break; } }
            if (!first) continue;
            uint256 sum;
            for (uint256 j = i; j < 3; j++) { if (who[j] == who[i]) sum += bps[j]; }
            LEDGER.setShares(marketId, who[i], sum);
        }
    }

    // ───────────────────────────── trade ─────────────────────────────

    function buy(bytes32 marketId, Outcome outcome, uint256 collateralIn, uint256 minSharesOut)
        external nonReentrant returns (uint256 sharesOut)
    {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert NotTrading();
        if (block.timestamp >= m.expiry) revert MarketExpired();
        if (collateralIn == 0) revert LiquidityTooLow();

        // pull full collateral into this market's ledger account, then skim fee
        LEDGER.transferFromInternal(msg.sender, address(this), collateralIn);
        uint256 fee = (collateralIn * FEE_BPS_TOTAL) / BPS;
        uint256 effectiveIn = collateralIn - fee;
        if (fee > 0) LEDGER.accrue(marketId, fee); // ONE write distributes to all recipients

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
        if (sharesOut == 0) revert AmountTooLow();
        if (sharesOut < minSharesOut) revert SlippageExceeded();
        emit Bought(marketId, msg.sender, outcome, collateralIn, sharesOut, fee);
    }

    function sell(bytes32 marketId, Outcome outcome, uint256 sharesIn, uint256 minCollateralOut)
        external nonReentrant returns (uint256 collateralOut)
    {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Trading) revert NotTrading();
        if (block.timestamp >= m.expiry) revert MarketExpired();
        if (sharesIn == 0) revert LiquidityTooLow();

        if (outcome == Outcome.Yes) {
            if (yesBalance[marketId][msg.sender] < sharesIn) revert InsufficientShares();
            yesBalance[marketId][msg.sender] -= sharesIn;
        } else {
            if (noBalance[marketId][msg.sender] < sharesIn) revert InsufficientShares();
            noBalance[marketId][msg.sender] -= sharesIn;
        }

        uint256 yesPostSell = outcome == Outcome.Yes ? m.yesReserve + sharesIn : m.yesReserve;
        uint256 noPostSell = outcome == Outcome.No ? m.noReserve + sharesIn : m.noReserve;
        uint256 k = m.yesReserve * m.noReserve;
        uint256 sumAB = yesPostSell + noPostSell;
        uint256 prodAB = yesPostSell * noPostSell;
        uint256 disc = sumAB * sumAB - 4 * (prodAB - k);
        uint256 grossOut = (sumAB - Math.sqrt(disc)) / 2;

        uint256 fee = (grossOut * FEE_BPS_TOTAL) / BPS;
        collateralOut = grossOut - fee;
        if (collateralOut < minCollateralOut) revert SlippageExceeded();

        m.yesReserve = yesPostSell - grossOut;
        m.noReserve = noPostSell - grossOut;

        if (fee > 0) LEDGER.accrue(marketId, fee);
        if (collateralOut > 0) LEDGER.internalTransfer(msg.sender, collateralOut);
        emit Sold(marketId, msg.sender, outcome, sharesIn, collateralOut, fee);
    }

    // ───────────────────────── resolve / claim ─────────────────────────

    function resolve(bytes32 marketId) external nonReentrant {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase == Phase.Resolved) revert AlreadyResolved();
        if (block.timestamp < m.expiry) revert MarketNotExpired();

        (int256 value, bool finalized) = ATTESTATION.valueAt(m.feedId, m.agent, m.expiry);
        if (value == 0 && !finalized) revert AttestationNotFound();
        if (!finalized) revert AttestationNotFinalized();

        bool yesWon = _evaluate(value, m.threshold, m.comparator);
        m.yesWon = yesWon;
        m.phase = Phase.Resolved;
        lpPotAtResolution[marketId] = yesWon ? m.yesReserve : m.noReserve;
        emit Resolved(marketId, yesWon, value);
    }

    function _evaluate(int256 value, int256 threshold, Comparator c) internal pure returns (bool) {
        if (c == Comparator.GreaterThan) return value > threshold;
        if (c == Comparator.GreaterOrEqual) return value >= threshold;
        if (c == Comparator.LessThan) return value < threshold;
        return value <= threshold;
    }

    function redeem(bytes32 marketId) external nonReentrant returns (uint256 payout) {
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
        LEDGER.internalTransfer(msg.sender, payout);
        emit Redeemed(marketId, msg.sender, payout);
    }

    function claimLP(bytes32 marketId) external nonReentrant returns (uint256 payout) {
        Market storage m = _markets[marketId];
        if (m.createdAt == 0) revert MarketMissing();
        if (m.phase != Phase.Resolved) revert NotResolved();
        uint256 myShares = lpShares[marketId][msg.sender];
        if (myShares == 0) revert NoLPShares();
        payout = (myShares * lpPotAtResolution[marketId]) / totalLpShares[marketId];
        lpShares[marketId][msg.sender] = 0;
        if (payout > 0) LEDGER.internalTransfer(msg.sender, payout);
        emit LPClaimed(marketId, msg.sender, payout);
    }

    // ───────────────────────────── views ─────────────────────────────

    function getMarket(bytes32 marketId) external view returns (Market memory) {
        return _markets[marketId];
    }

    function priceOf(bytes32 marketId, Outcome outcome) external view returns (uint256) {
        Market memory m = _markets[marketId];
        uint256 total = m.yesReserve + m.noReserve;
        if (total == 0) return 0;
        uint256 other = outcome == Outcome.Yes ? m.noReserve : m.yesReserve;
        return (other * 1e18) / total;
    }
}
