// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRegistraiPoints} from "./IRegistraiPoints.sol";
import {PointsValues} from "./PointsValues.sol";

/// @title RegistraiPoints
/// @notice Soulbound protocol credit system. Non-transferable. Awarded by
///         authorized protocol contracts (Registry, Attestation, Markets) for
///         meaningful onchain participation. Points are not a security or
///         financial instrument — they are protocol activity credits.
///
/// @dev Known limitation (M3): round-trip trading (buy + immediate sell) earns
///      points on both legs. The per-wallet daily cap is the only protection.
///      This is acceptable on testnet where points carry no monetary value.
///      If points ever gate a meaningful reward, add a per-(user, marketId)
///      cooldown or restrict awards to the buy leg only.
contract RegistraiPoints is IRegistraiPoints {
    // Reason tags used in PointsAwarded events for off-chain indexing.
    bytes32 public constant REASON_REGISTER      = "register";
    bytes32 public constant REASON_ATTEST        = "attest";
    bytes32 public constant REASON_CREATE_MARKET = "create_market";
    bytes32 public constant REASON_RESOLVE       = "resolve";
    bytes32 public constant REASON_TRADE         = "trade";

    // Expose PointsValues constants publicly so explorers and frontends can read them.
    uint256 public constant POINTS_REGISTER            = PointsValues.POINTS_REGISTER;
    uint256 public constant POINTS_REGISTER_RULE_BONUS = PointsValues.POINTS_REGISTER_RULE_BONUS;
    uint256 public constant POINTS_ATTEST              = PointsValues.POINTS_ATTEST;
    uint256 public constant POINTS_ATTEST_RULE_BONUS   = PointsValues.POINTS_ATTEST_RULE_BONUS;
    uint256 public constant POINTS_CREATE_MARKET       = PointsValues.POINTS_CREATE_MARKET;
    uint256 public constant POINTS_RESOLVE             = PointsValues.POINTS_RESOLVE;
    uint256 public constant POINTS_SLASH_PENALTY       = PointsValues.POINTS_SLASH_PENALTY;
    uint256 public constant DAILY_TRADE_CAP            = PointsValues.DAILY_TRADE_CAP;
    uint256 public constant PTS_PER_USDC               = PointsValues.PTS_PER_USDC;
    uint256 public constant MAX_FLAT_AWARD             = PointsValues.MAX_FLAT_AWARD;

    mapping(address => uint256) public points;
    mapping(address => bool)    public minters;

    // Daily trade cap state.
    mapping(address => uint256) public dailyTradePts;
    mapping(address => uint256) public lastTradeDay;

    address public immutable DEPLOYER;

    event PointsAwarded(address indexed user, uint256 amount, address indexed by, bytes32 reason);
    event PointsSlashed(address indexed user, uint256 amount);
    event MinterSet(address indexed minter, bool enabled);

    error NotMinter();
    error NotDeployer();
    error AwardTooLarge();

    constructor() {
        DEPLOYER = msg.sender;
    }

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert NotMinter();
        _;
    }

    function setMinter(address minter, bool enabled) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        minters[minter] = enabled;
        emit MinterSet(minter, enabled);
    }

    /// @notice Flat award for discrete protocol actions (registration, attestation,
    ///         market creation, resolution). Caller must pass a bytes32 reason tag.
    ///         Single-call cap of MAX_FLAT_AWARD guards against minter bugs.
    function awardFlat(address user, uint256 amount, bytes32 reason) external onlyMinter {
        if (amount == 0) return;
        if (amount > PointsValues.MAX_FLAT_AWARD) revert AwardTooLarge();
        points[user] += amount;
        emit PointsAwarded(user, amount, msg.sender, reason);
    }

    /// @notice Volume-weighted award for trading. Rate: PTS_PER_USDC per 1e6 USDC,
    ///         hard-capped at DAILY_TRADE_CAP points per wallet per calendar day.
    function awardTrade(address user, uint256 usdcAmount) external onlyMinter {
        uint256 today = block.timestamp / 1 days;
        if (lastTradeDay[user] != today) {
            dailyTradePts[user] = 0;
            lastTradeDay[user] = today;
        }
        uint256 remaining = PointsValues.DAILY_TRADE_CAP - dailyTradePts[user];
        if (remaining == 0) return;

        uint256 earned = (usdcAmount * PointsValues.PTS_PER_USDC) / 1e6;
        if (earned == 0) return;
        uint256 actual = earned > remaining ? remaining : earned;

        dailyTradePts[user] += actual;
        points[user] += actual;
        emit PointsAwarded(user, actual, msg.sender, REASON_TRADE);
    }

    /// @notice Deduct points on a slashed attestation. Floors at zero.
    function slashPoints(address user, uint256 amount) external onlyMinter {
        uint256 current = points[user];
        uint256 deducted = amount > current ? current : amount;
        if (deducted == 0) return;
        points[user] = current - deducted;
        emit PointsSlashed(user, deducted);
    }
}
