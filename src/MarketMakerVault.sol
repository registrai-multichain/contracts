// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Markets} from "./Markets.sol";

/// @title MarketMakerVault
/// @notice Pooled USDC deployed as buy-side and LP liquidity on Registrai
///         markets by an authorized off-chain operator. Depositors mint
///         pro-rata vault shares against current NAV; the operator submits
///         buys, sells, and add-liquidity calls; resolved-market winnings
///         and LP residuals flow back into the vault and depositors withdraw
///         their slice.
///
///         v1 NAV is conservative — accounted as the vault's USDC balance,
///         ignoring open outcome positions. This makes pricing trivially
///         resistant to AMM-state sandwich attacks and removes any need for
///         per-market position bookkeeping in storage. The cost is mild
///         intra-cohort unfairness: depositors entering while positions are
///         open pay no premium for unrealized PnL, withdrawers leave their
///         share of it behind. Acceptable for a bootstrapping primitive;
///         v2 (mark-to-market NAV + performance fee) can replace this
///         without changing the depositor interface.
contract MarketMakerVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    Markets public immutable MARKETS;

    address public owner;
    address public operator;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    error NotOwner();
    error NotOperator();
    error AmountZero();
    error InsufficientShares();
    error ZeroAddress();

    event Deposited(address indexed user, uint256 usdcIn, uint256 sharesOut);
    event Withdrawn(address indexed user, uint256 sharesIn, uint256 usdcOut);
    event OperatorRotated(address indexed previous, address indexed next);
    event OwnerRotated(address indexed previous, address indexed next);
    event TradeExecuted(
        bytes32 indexed marketId, Markets.Outcome outcome, uint256 collateralIn, uint256 sharesOut
    );
    event TradeUnwound(
        bytes32 indexed marketId, Markets.Outcome outcome, uint256 sharesIn, uint256 collateralOut
    );
    event LiquidityProvided(bytes32 indexed marketId, uint256 amount, uint256 lpShares);
    event Redeemed(bytes32 indexed marketId, uint256 payout);
    event LpClaimed(bytes32 indexed marketId, uint256 payout);

    constructor(IERC20 usdc, Markets markets, address operator_) {
        if (address(usdc) == address(0)) revert ZeroAddress();
        if (address(markets) == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        USDC = usdc;
        MARKETS = markets;
        owner = msg.sender;
        operator = operator_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /* ───────────────── Depositor side ───────────────── */

    /// @notice "Virtual offset" used to defang the first-depositor share-
    /// inflation attack. One USDC-unit (1e6) on both sides of the mint
    /// equation makes a donation attack require many orders of magnitude
    /// more capital than it could ever steal.
    uint256 private constant VIRTUAL_OFFSET = 1e6;

    /// @notice Deposit USDC, mint shares against current NAV.
    function deposit(uint256 amount) external returns (uint256 shares) {
        if (amount == 0) revert AmountZero();
        uint256 navBefore = USDC.balanceOf(address(this));
        shares = (amount * (totalShares + VIRTUAL_OFFSET)) / (navBefore + VIRTUAL_OFFSET);
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += shares;
        totalShares += shares;
        emit Deposited(msg.sender, amount, shares);
    }

    /// @notice Burn shares, redeem pro-rata USDC from the vault's balance.
    function withdraw(uint256 shares) external returns (uint256 amount) {
        if (shares == 0) revert AmountZero();
        if (sharesOf[msg.sender] < shares) revert InsufficientShares();
        uint256 nav_ = USDC.balanceOf(address(this));
        amount = (shares * nav_) / totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        USDC.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, shares, amount);
    }

    /// @notice NAV in USDC. Conservative — counts only the vault's idle
    /// balance, not the marked value of any outcome shares it currently holds.
    function nav() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Price of one vault share in USDC, scaled to 1e6 (USDC decimals).
    function pricePerShare() external view returns (uint256) {
        if (totalShares == 0) return 1e6;
        return (nav() * 1e6) / totalShares;
    }

    /* ───────────────── Operator side ───────────────── */

    function executeBuy(
        bytes32 marketId,
        Markets.Outcome outcome,
        uint256 collateralIn,
        uint256 minSharesOut
    ) external onlyOperator returns (uint256 sharesOut) {
        USDC.forceApprove(address(MARKETS), collateralIn);
        sharesOut = MARKETS.buy(marketId, outcome, collateralIn, minSharesOut);
        emit TradeExecuted(marketId, outcome, collateralIn, sharesOut);
    }

    function executeSell(
        bytes32 marketId,
        Markets.Outcome outcome,
        uint256 sharesIn,
        uint256 minCollateralOut
    ) external onlyOperator returns (uint256 collateralOut) {
        collateralOut = MARKETS.sell(marketId, outcome, sharesIn, minCollateralOut);
        emit TradeUnwound(marketId, outcome, sharesIn, collateralOut);
    }

    function executeAddLiquidity(bytes32 marketId, uint256 amount)
        external
        onlyOperator
        returns (uint256 lpShares)
    {
        USDC.forceApprove(address(MARKETS), amount);
        lpShares = MARKETS.addLiquidity(marketId, amount);
        emit LiquidityProvided(marketId, amount, lpShares);
    }

    /// @notice Anyone can call after a market resolves — pulls vault's
    /// winning-share payout into the vault.
    function redeem(bytes32 marketId) external returns (uint256 payout) {
        payout = MARKETS.redeem(marketId);
        emit Redeemed(marketId, payout);
    }

    /// @notice Anyone can call after resolution — pulls vault's LP residual.
    function claimLp(bytes32 marketId) external returns (uint256 payout) {
        payout = MARKETS.claimLP(marketId);
        emit LpClaimed(marketId, payout);
    }

    /* ───────────────── Admin ───────────────── */

    function rotateOperator(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OperatorRotated(operator, next);
        operator = next;
    }

    function rotateOwner(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnerRotated(owner, next);
        owner = next;
    }
}
