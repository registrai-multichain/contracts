// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BridgeRouter} from "../src/bridge/BridgeRouter.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 guardedSalt, address deployer) external view returns (address);
}

/// @notice Deploys BridgeRouter to the SAME address on every chain via
///         CreateX CREATE3.
///
/// CREATE3 derives the address from (deployer, salt) only — never from the
/// initcode — which matters here because the constructor takes a per-chain
/// USDC address. CREATE2 would give a different address on every chain; this
/// gives one address users can memorise and verify.
///
/// Salt layout required by CreateX's `_guard`:
///   bytes[0..20)  = deployer address  -> permissioned: only this EOA may use it
///   byte[20]      = 0x00              -> NO cross-chain redeploy protection.
///                                        0x01 would hash in block.chainid and
///                                        produce a DIFFERENT address per chain,
///                                        defeating the entire purpose.
///   bytes[21..32) = free entropy
///
/// Usage:
///   forge script script/DeployBridgeRouter.s.sol --rpc-url <chain> --broadcast
contract DeployBridgeRouter is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address constant TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    /// Free-entropy tail of the salt. Bump only to intentionally claim a new
    /// address; changing it changes the address on every chain.
    bytes11 constant SALT_ENTROPY = bytes11(keccak256("registrai.bridge.router.v1"));

    function usdcFor(uint256 chainId) public pure returns (address) {
        if (chainId == 1) return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Ethereum
        if (chainId == 8453) return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base
        if (chainId == 42161) return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // Arbitrum
        if (chainId == 10) return 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // Optimism
        if (chainId == 137) return 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; // Polygon PoS
        if (chainId == 43114) return 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; // Avalanche
        if (chainId == 130) return 0x078D782b760474a361dDA0AF3839290b0EF57AD6; // Unichain
        if (chainId == 59144) return 0x176211869cA2b568f2A7D4EE941E073a821EE1ff; // Linea
        if (chainId == 480) return 0x79A02482A880bCE3F13e09Da970dC34db4CD24d1; // World Chain
        if (chainId == 146) return 0x29219dd400f2Bf60E5a23d13Be72B486D4038894; // Sonic
        if (chainId == 5042) return 0x3600000000000000000000000000000000000000; // Arc (native USDC)
        revert("BridgeRouter: unmapped chain, add its USDC address");
    }

    function buildSalt(address deployer) public pure returns (bytes32) {
        return bytes32(abi.encodePacked(deployer, bytes1(0x00), SALT_ENTROPY));
    }

    /// CreateX hashes a permissioned, chain-agnostic salt this way.
    function guardedSalt(address deployer) public pure returns (bytes32) {
        return keccak256(abi.encode(deployer, buildSalt(deployer)));
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address owner = vm.envOr("ROUTER_OWNER", feeRecipient);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(50))); // default 0.50% (== MAX_FEE_BPS)

        address usdc = usdcFor(block.chainid);
        bytes32 salt = buildSalt(deployer);

        address predicted = CREATEX.computeCreate3Address(guardedSalt(deployer), address(CREATEX));

        console2.log("chainId       ", block.chainid);
        console2.log("deployer      ", deployer);
        console2.log("usdc          ", usdc);
        console2.log("feeRecipient  ", feeRecipient);
        console2.log("owner         ", owner);
        console2.log("feeBps        ", feeBps);
        console2.log("predicted     ", predicted);

        if (predicted.code.length > 0) {
            console2.log("ALREADY DEPLOYED at predicted address - nothing to do");
            return;
        }

        bytes memory initCode =
            abi.encodePacked(type(BridgeRouter).creationCode, abi.encode(usdc, TOKEN_MESSENGER_V2, feeRecipient, feeBps, owner));

        vm.startBroadcast(pk);
        address deployed = CREATEX.deployCreate3(salt, initCode);
        vm.stopBroadcast();

        console2.log("deployed      ", deployed);
        require(deployed == predicted, "address mismatch: salt or deployer differs from prediction");

        BridgeRouter router = BridgeRouter(deployed);
        require(address(router.usdc()) == usdc, "usdc mismatch");
        require(address(router.tokenMessenger()) == TOKEN_MESSENGER_V2, "messenger mismatch");
        require(router.feeBps() == feeBps, "fee mismatch");
        require(router.owner() == owner, "owner mismatch");
        console2.log("verified OK");
    }
}
