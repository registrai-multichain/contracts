// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BridgeRouter} from "../src/bridge/BridgeRouter.sol";
import {DeployBridgeRouter, ICreateX} from "../script/DeployBridgeRouter.s.sol";

/// @notice Proves the router lands on the SAME address on every chain when
///         deployed through real CreateX with the same (deployer, salt) — even
///         though the constructor takes a different USDC address per chain.
///
///   forge test --match-contract BridgeRouterDeployTest
contract BridgeRouterDeployTest is Test {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    DeployBridgeRouter helper;
    address deployer = address(0xD3910E);
    address treasury = address(0xFEE5);

    function setUp() public {
        helper = new DeployBridgeRouter();
        // Survives vm.createSelectFork, which otherwise discards local state.
        vm.makePersistent(address(helper));
    }

    function _deployOn(string memory rpc, uint256 expectedChainId) internal returns (address) {
        vm.createSelectFork(rpc);
        assertEq(block.chainid, expectedChainId, "fork chain id");

        address usdc = helper.usdcFor(block.chainid);
        bytes32 salt = helper.buildSalt(deployer);

        bytes memory initCode = abi.encodePacked(
            type(BridgeRouter).creationCode, abi.encode(usdc, TOKEN_MESSENGER_V2, treasury, uint16(10), treasury)
        );

        vm.prank(deployer);
        address deployed = CREATEX.deployCreate3(salt, initCode);

        // Constructor args really did differ per chain.
        assertEq(address(BridgeRouter(deployed).usdc()), usdc, "chain-specific USDC wired");
        assertEq(BridgeRouter(deployed).feeBps(), 10);
        return deployed;
    }

    function test_sameAddressAcrossChains() public {
        address onBase = _deployOn("https://base-rpc.publicnode.com", 8453);
        address onArbitrum = _deployOn("https://arbitrum-one-rpc.publicnode.com", 42161);
        address onOptimism = _deployOn("https://optimism-rpc.publicnode.com", 10);

        console2.log("base     ", onBase);
        console2.log("arbitrum ", onArbitrum);
        console2.log("optimism ", onOptimism);

        assertEq(onBase, onArbitrum, "Base and Arbitrum must match");
        assertEq(onBase, onOptimism, "Base and Optimism must match");
    }

    /// The script's predicted address must equal what CreateX actually produces.
    /// NOTE: salt and initCode must be hoisted into locals BEFORE vm.prank —
    /// an argument-position call to `helper` would consume the prank and make
    /// CreateX see the test contract as msg.sender, silently taking the
    /// random-salt branch and landing on a different address.
    function test_predictionMatchesDeployment() public {
        vm.createSelectFork("https://base-rpc.publicnode.com");

        address predicted = CREATEX.computeCreate3Address(helper.guardedSalt(deployer), address(CREATEX));
        bytes32 salt = helper.buildSalt(deployer);
        bytes memory initCode = abi.encodePacked(
            type(BridgeRouter).creationCode,
            abi.encode(helper.usdcFor(8453), TOKEN_MESSENGER_V2, treasury, uint16(10), treasury)
        );

        vm.prank(deployer);
        address deployed = CREATEX.deployCreate3(salt, initCode);

        assertEq(deployed, predicted, "script prediction must match reality");
    }

    /// Our salt is permissioned: a different sender using the identical salt
    /// gets a DIFFERENT address, so nobody can squat the address we publish.
    function test_foreignSenderCannotClaimOurAddress() public {
        vm.createSelectFork("https://base-rpc.publicnode.com");

        address ours = CREATEX.computeCreate3Address(helper.guardedSalt(deployer), address(CREATEX));
        bytes32 salt = helper.buildSalt(deployer);
        bytes memory initCode = abi.encodePacked(
            type(BridgeRouter).creationCode,
            abi.encode(helper.usdcFor(8453), TOKEN_MESSENGER_V2, treasury, uint16(10), treasury)
        );

        vm.prank(address(0xBADBAD));
        address squatted = CREATEX.deployCreate3(salt, initCode);
        assertTrue(squatted != ours, "attacker must not land on our address");

        // Our address is still free for us to claim afterwards.
        vm.prank(deployer);
        address deployed = CREATEX.deployCreate3(salt, initCode);
        assertEq(deployed, ours, "our address remains claimable");
    }
}
