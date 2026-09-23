// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BridgeRouter, ITokenMessengerV2} from "../src/bridge/BridgeRouter.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mirrors CCTP v2: pulls the approved amount and records the call.
contract MockTokenMessenger is ITokenMessengerV2 {
    struct Burn {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }

    Burn public last;
    uint256 public callCount;

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        last = Burn(
            amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold
        );
        callCount++;
    }
}

contract BridgeRouterTest is Test {
    uint32 constant ARC_DOMAIN = 26;
    uint32 constant ETH_DOMAIN = 0;

    MockUSDC usdc;
    MockTokenMessenger messenger;
    BridgeRouter router;

    address owner = address(0xA11CE);
    address treasury = address(0xFEE5);
    address alice = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
        messenger = new MockTokenMessenger();
        router = new BridgeRouter(address(usdc), address(messenger), treasury, 10, owner);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
    }

    /* ---------------------------------------------------------------- happy */

    function test_bridge_splitsFeeAndBurnsRemainder() public {
        uint256 amount = 1_000e6;

        vm.prank(alice);
        uint256 burned = router.bridge(amount, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 1e6, 1000);

        assertEq(burned, 999e6, "burn = amount - 0.10%");
        assertEq(usdc.balanceOf(treasury), 1e6, "fee to treasury");
        assertEq(usdc.balanceOf(address(messenger)), 999e6, "remainder to CCTP");
        assertEq(usdc.balanceOf(address(router)), 0, "router retains nothing");

        (uint256 burnAmount, uint32 dstDomain, bytes32 recipient,, bytes32 dstCaller, uint256 maxFee, uint32 fin) =
            messenger.last();
        assertEq(burnAmount, 999e6);
        assertEq(dstDomain, ARC_DOMAIN);
        assertEq(recipient, bytes32(uint256(uint160(alice))));
        assertEq(dstCaller, bytes32(0), "permissionless receive");
        assertEq(maxFee, 1e6);
        assertEq(fin, 1000);
    }

    /// Arc -> elsewhere is the same code path; only the domain changes.
    function test_bridge_outboundFromArc() public {
        vm.prank(alice);
        router.bridgeTo(500e6, ETH_DOMAIN, alice, 0, 2000);

        (uint256 burnAmount, uint32 dstDomain,,,,, uint32 fin) = messenger.last();
        assertEq(burnAmount, 499.5e6);
        assertEq(dstDomain, ETH_DOMAIN);
        assertEq(fin, 2000, "standard transfer");
    }

    /// bridgeTo must pull from the caller, not from the router.
    function test_bridgeTo_pullsFromCallerNotRouter() public {
        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        router.bridgeTo(100e6, ARC_DOMAIN, alice, 1e5, 1000);

        assertEq(usdc.balanceOf(alice), before - 100e6, "debited the caller");
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(messenger.callCount(), 1);
    }

    function test_zeroFee_burnsEverything() public {
        vm.prank(owner);
        router.setFeeConfig(0, treasury);

        vm.prank(alice);
        uint256 burned = router.bridge(1_000e6, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 0, 2000);

        assertEq(burned, 1_000e6);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_quote_matchesExecution() public {
        (uint256 quotedFee, uint256 quotedBurn) = router.quote(777e6);

        vm.prank(alice);
        uint256 burned = router.bridge(777e6, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 1e5, 1000);

        assertEq(burned, quotedBurn);
        assertEq(usdc.balanceOf(treasury), quotedFee);
    }

    /* ---------------------------------------------------------------- guards */

    function test_revert_feeAboveHardCap() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BridgeRouter.FeeTooHigh.selector, uint16(51), uint16(50)));
        router.setFeeConfig(51, treasury);
    }

    function test_revert_nonOwnerCannotSetFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router.setFeeConfig(0, alice);
    }

    function test_revert_amountAfterFeeBelowMaxFee() public {
        // 100 USDC in, 0.10% fee -> 99.9 burned, which cannot cover a 200 maxFee.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BridgeRouter.AmountTooSmall.selector, uint256(99.9e6), uint256(200e6)));
        router.bridge(100e6, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 200e6, 1000);
    }

    function test_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(BridgeRouter.ZeroAmount.selector);
        router.bridge(0, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 0, 2000);
    }

    function test_revert_zeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(BridgeRouter.ZeroAddress.selector);
        router.bridge(1e6, ARC_DOMAIN, bytes32(0), 0, 2000);
    }

    function test_revert_badFinalityThreshold() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BridgeRouter.InvalidFinalityThreshold.selector, uint32(1500)));
        router.bridge(1e6, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 0, 1500);
    }

    function test_constructorRejectsFeeAboveCap() public {
        vm.expectRevert(abi.encodeWithSelector(BridgeRouter.FeeTooHigh.selector, uint16(500), uint16(50)));
        new BridgeRouter(address(usdc), address(messenger), treasury, 500, owner);
    }

    /* ---------------------------------------------------------------- invariant */

    /// The router must never retain USDC, at any fee level or amount.
    function testFuzz_routerNeverRetainsBalance(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        bps = uint16(bound(bps, 0, router.MAX_FEE_BPS()));

        vm.prank(owner);
        router.setFeeConfig(bps, treasury);

        uint256 expectedFee = (amount * bps) / 10_000;
        vm.assume(amount - expectedFee > 0);

        vm.prank(alice);
        router.bridge(amount, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 0, 2000);

        assertEq(usdc.balanceOf(address(router)), 0, "no dust retained");
        assertEq(usdc.balanceOf(treasury), expectedFee, "fee exact");
        assertEq(usdc.balanceOf(address(messenger)), amount - expectedFee, "remainder burned");
    }

    /// Fee + burned must always reconstruct the input exactly — no leakage.
    function testFuzz_conservationOfValue(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);

        vm.prank(alice);
        uint256 burned = router.bridge(amount, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 0, 2000);

        assertEq(burned + usdc.balanceOf(treasury), amount, "fee + burn == input");
    }
}
