// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Circle's CCTP v2 TokenMessenger. Deployed at the same address on
///         every supported EVM chain, Arc included.
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// @title BridgeRouter
/// @notice Thin fee-taking wrapper over Circle's CCTP v2 `depositForBurn`.
///
/// The router takes a basis-point fee on the source chain and forwards the
/// remainder to Circle's canonical TokenMessenger, which burns it here and
/// mints native USDC on the destination domain. The router is deliberately
/// *not* a bridge: it holds no liquidity, mints nothing, and custodies
/// nothing across transactions. Every transfer it initiates produces a real
/// `DepositForBurn` event from Circle's own contract, so any user can verify
/// in a block explorer that the burn actually happened — which is the whole
/// difference between this and the "Arc bridge" sites that took deposits and
/// never burned anything.
///
/// Direction-agnostic: the same contract on Ethereum bridges to Arc, and the
/// same contract on Arc bridges back out. `mintRecipient` is a bytes32 so
/// non-EVM destinations (Solana, Sui, Aptos, Noble) work unchanged.
///
/// Deployed via CreateX CREATE3 so the address is identical on every chain.
/// The address does not depend on constructor arguments, which differ per
/// chain because the USDC token address does.
contract BridgeRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Hard ceiling on the configurable fee. Not upgradeable, not
    ///         governable: the owner can never set a fee above this.
    uint16 public constant MAX_FEE_BPS = 50; // 0.50%

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice CCTP finality thresholds. Fast transfers settle in seconds and
    ///         require a non-zero `maxFee`; standard transfers are free but
    ///         wait for source-chain finality.
    uint32 public constant FINALITY_FAST = 1000;
    uint32 public constant FINALITY_STANDARD = 2000;

    IERC20 public immutable usdc;
    ITokenMessengerV2 public immutable tokenMessenger;

    uint16 public feeBps;
    address public feeRecipient;

    event Bridged(
        address indexed sender,
        uint32 indexed destinationDomain,
        bytes32 indexed mintRecipient,
        uint256 amountIn,
        uint256 routerFee,
        uint256 amountBurned,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );
    event FeeConfigUpdated(uint16 feeBps, address feeRecipient);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh(uint16 requested, uint16 maximum);
    error AmountTooSmall(uint256 amountAfterFee, uint256 maxFee);
    error InvalidFinalityThreshold(uint32 provided);

    constructor(address _usdc, address _tokenMessenger, address _feeRecipient, uint16 _feeBps, address _owner)
        Ownable(_owner)
    {
        if (_usdc == address(0) || _tokenMessenger == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh(_feeBps, MAX_FEE_BPS);

        usdc = IERC20(_usdc);
        tokenMessenger = ITokenMessengerV2(_tokenMessenger);
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;

        emit FeeConfigUpdated(_feeBps, _feeRecipient);
    }

    /// @notice Take the router fee and burn the remainder through CCTP v2.
    /// @param amount Total USDC pulled from the caller, fee inclusive.
    /// @param destinationDomain CCTP domain of the destination chain (Arc = 26).
    /// @param mintRecipient Destination address, left-padded to bytes32.
    /// @param maxFee Maximum CCTP fee, in USDC base units, paid to Circle out
    ///        of the burned amount. Must be 0 < maxFee for fast transfers.
    /// @param minFinalityThreshold `FINALITY_FAST` or `FINALITY_STANDARD`.
    /// @return amountBurned USDC actually handed to CCTP, before Circle's own fee.
    function bridge(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external nonReentrant returns (uint256 amountBurned) {
        return _bridge(msg.sender, amount, destinationDomain, mintRecipient, maxFee, minFinalityThreshold);
    }

    function _bridge(
        address payer,
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) internal returns (uint256 amountBurned) {
        if (amount == 0) revert ZeroAmount();
        if (mintRecipient == bytes32(0)) revert ZeroAddress();
        if (minFinalityThreshold != FINALITY_FAST && minFinalityThreshold != FINALITY_STANDARD) {
            revert InvalidFinalityThreshold(minFinalityThreshold);
        }

        // Cache config so a mid-flight owner update cannot change this transfer.
        uint16 bps = feeBps;
        address recipient = feeRecipient;

        usdc.safeTransferFrom(payer, address(this), amount);

        uint256 routerFee = (amount * bps) / BPS_DENOMINATOR;
        amountBurned = amount - routerFee;

        // CCTP deducts its own fee from the burned amount, so the burn must
        // strictly exceed it or the recipient receives nothing.
        if (amountBurned <= maxFee) revert AmountTooSmall(amountBurned, maxFee);

        if (routerFee > 0) {
            usdc.safeTransfer(recipient, routerFee);
        }

        usdc.forceApprove(address(tokenMessenger), amountBurned);
        tokenMessenger.depositForBurn(
            amountBurned,
            destinationDomain,
            mintRecipient,
            address(usdc),
            bytes32(0), // permissionless receive: anyone may deliver the mint
            maxFee,
            minFinalityThreshold
        );

        emit Bridged(
            payer, destinationDomain, mintRecipient, amount, routerFee, amountBurned, maxFee, minFinalityThreshold
        );
    }

    /// @notice Convenience helper for EVM destinations.
    function bridgeTo(
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external nonReentrant returns (uint256) {
        if (mintRecipient == address(0)) revert ZeroAddress();
        return _bridge(
            msg.sender,
            amount,
            destinationDomain,
            bytes32(uint256(uint160(mintRecipient))),
            maxFee,
            minFinalityThreshold
        );
    }

    /// @notice Quote the split for a given input without sending anything.
    function quote(uint256 amount) external view returns (uint256 routerFee, uint256 amountBurned) {
        routerFee = (amount * feeBps) / BPS_DENOMINATOR;
        amountBurned = amount - routerFee;
    }

    function setFeeConfig(uint16 _feeBps, address _feeRecipient) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh(_feeBps, MAX_FEE_BPS);
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        emit FeeConfigUpdated(_feeBps, _feeRecipient);
    }

    /// @notice Recover tokens sent here by mistake.
    /// @dev The router holds no balance between transactions — `bridge` pays
    ///      out the fee and burns the remainder in the same call — so this can
    ///      only ever move stray transfers, never funds in flight.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }
}
