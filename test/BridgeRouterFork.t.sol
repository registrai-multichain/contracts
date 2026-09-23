// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BridgeRouter} from "../src/bridge/BridgeRouter.sol";

/// @notice Exercises the router against Circle's REAL deployed CCTP v2
///         TokenMessenger on a Base fork. A mock proving a mock works is not
///         evidence; this is. Run with:
///           forge test --match-contract BridgeRouterForkTest \
///             --fork-url https://base-rpc.publicnode.com
contract BridgeRouterForkTest is Test {
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    uint32 constant ARC_DOMAIN = 26;
    uint32 constant FINALITY_FAST = 1000;
    uint32 constant FINALITY_STANDARD = 2000;

    /// Circle's own DepositForBurn event, as emitted by TokenMessengerV2.
    event DepositForBurn(
        address indexed burnToken,
        uint256 amount,
        address indexed depositor,
        bytes32 mintRecipient,
        uint32 destinationDomain,
        bytes32 destinationTokenMessenger,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 indexed minFinalityThreshold,
        bytes hookData
    );

    BridgeRouter router;
    IERC20 usdc = IERC20(USDC_BASE);

    address owner = address(0xA11CE);
    address treasury = address(0xFEE5);
    address alice = address(0xB0B);

    function setUp() public {
        vm.skip(block.chainid != 8453);
        router = new BridgeRouter(USDC_BASE, TOKEN_MESSENGER_V2, treasury, 10, owner);
        deal(USDC_BASE, alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
    }

    /// The real TokenMessenger must accept our burn and emit its own event.
    function test_fork_realCctpAcceptsBurn_standard() public {
        uint256 amount = 1_000e6;
        uint256 expectedFee = 1e6; // 10 bps
        uint256 expectedBurn = amount - expectedFee;

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.recordLogs();
        vm.prank(alice);
        uint256 burned = router.bridge(amount, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 0, FINALITY_STANDARD);

        assertEq(burned, expectedBurn, "burn = amount - fee");
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee, "fee landed");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds nothing");

        // Circle's contract must have emitted DepositForBurn for our amount.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == TOKEN_MESSENGER_V2
                    && logs[i].topics[0] == keccak256(
                        "DepositForBurn(address,uint256,address,bytes32,uint32,bytes32,bytes32,uint256,uint32,bytes)"
                    )
            ) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), USDC_BASE, "burnToken");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(router), "depositor is the router");
            }
        }
        assertTrue(found, "Circle's DepositForBurn was emitted");
    }

    /// Fast transfers require a non-zero maxFee; the burn must still clear it.
    function test_fork_realCctpAcceptsBurn_fast() public {
        uint256 amount = 1_000e6;
        uint256 maxFee = 1e6;

        vm.prank(alice);
        uint256 burned = router.bridge(amount, ARC_DOMAIN, bytes32(uint256(uint160(alice))), maxFee, FINALITY_FAST);

        assertEq(burned, 999e6);
        assertGt(burned, maxFee, "burn must exceed Circle's fee");
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    /// USDC must actually leave the user and not be recoverable by us.
    function test_fork_userIsDebitedExactly() public {
        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        router.bridge(2_500e6, ARC_DOMAIN, bytes32(uint256(uint160(alice))), 0, FINALITY_STANDARD);

        assertEq(before - usdc.balanceOf(alice), 2_500e6, "debited exactly the input");
    }
}
