// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegiBuyback} from "../src/buyback/RegiBuyback.sol";
import {RegiFeeSplitter} from "../src/buyback/RegiFeeSplitter.sol";
import {PoolKey, IPoolManagerMinimal, V4Lib} from "../src/buyback/UniswapV4Minimal.sol";
import {INanoLedgerMinimal} from "../src/buyback/INanoLedgerMinimal.sol";

/// @notice Deploys RegiBuyback, then RegiFeeSplitter, on Arc MAINNET. Run AFTER the
///         shared NanoLedger exists and BEFORE DeployNanoStack, which takes the splitter
///         as TREASURY (it requires TREASURY to have code on mainnet).
///
///   SAFE=0xFeE9…80Fb NANO_LEDGER=0x… forge script script/DeployBuyback.s.sol --rpc-url arc_mainnet
///   (dry run: no --broadcast. The deploy itself is signed as the audit and runbook say.)
contract DeployBuyback is Script {
    IPoolManagerMinimal constant PM = IPoolManagerMinimal(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant REGI = 0x93D5b8c53ee763C2c4522bF0d958ce51Af4360ae;
    address constant HOOKS = 0x779A7F22480db20eD3Ed2BB7950B207Ce71Ae044;
    bytes32 constant POOL_ID = 0x0530f18eb32d732cc8b067bbd0b2ba7e5d807d4f5cf4f7d74429f2a78d3120c8;

    function run() external returns (RegiBuyback bb, RegiFeeSplitter sp) {
        require(block.chainid == 5042, "DeployBuyback: Arc mainnet only");
        address safe = vm.envAddress("SAFE");
        address ledger = vm.envAddress("NANO_LEDGER");
        require(safe.code.length > 0, "SAFE must be the Admin Safe (a contract)");
        require(ledger.code.length > 0, "NANO_LEDGER must be the shared ledger");
        require(V4Lib.poolId(PoolKey(USDC, REGI, 10_000, 200, HOOKS)) == POOL_ID, "pool key");
        require(V4Lib.sqrtPriceX96(PM, POOL_ID) > 0, "pool not initialized");

        vm.startBroadcast();
        bb = new RegiBuyback(PM, IERC20(USDC), REGI, HOOKS, 10_000, 200, INanoLedgerMinimal(ledger));
        sp = new RegiFeeSplitter(INanoLedgerMinimal(ledger), IERC20(USDC), safe, address(bb));
        vm.stopBroadcast();

        console.log("RegiBuyback     ", address(bb));
        console.log("RegiFeeSplitter ", address(sp));
        console.log("next: DeployNanoStack with TREASURY =", address(sp));
    }
}
