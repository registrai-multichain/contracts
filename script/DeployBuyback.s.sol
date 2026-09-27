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
    /// The Admin Safe (deployments/arc-mainnet.json builders.roles.adminSafe): the splitter's
    /// permanent 60% recipient and the only address that can repoint the 40%.
    address constant ADMIN_SAFE = 0xFeE926e8Be2D1C6192213cf20f31D94Dad1e80Fb;

    function run() external returns (RegiBuyback bb, RegiFeeSplitter sp) {
        return deploy(vm.envAddress("SAFE"), vm.envAddress("NANO_LEDGER"));
    }

    /// @dev The same deploy with explicit inputs (tests call this: env vars are process-wide
    ///      and forge runs tests in parallel).
    function deploy(address safe, address ledger) public returns (RegiBuyback bb, RegiFeeSplitter sp) {
        require(block.chainid == 5042, "DeployBuyback: Arc mainnet only");
        require(safe == ADMIN_SAFE, "SAFE must be the Admin Safe 0xFeE9...80Fb");
        require(_isContract(ledger), "NANO_LEDGER must be the shared ledger");
        // MarketsV4 pays the splitter on its ledger; a ledger on another token (or a
        // different ledger than DeployNanoStack uses) strands 100% of treasury income.
        (bool ok, bytes memory ret) = ledger.staticcall(abi.encodeWithSignature("USDC()"));
        require(ok && ret.length == 32 && abi.decode(ret, (address)) == USDC, "NANO_LEDGER must hold Arc USDC (0x3600...)");
        require(V4Lib.poolId(PoolKey(USDC, REGI, 10_000, 200, HOOKS)) == POOL_ID, "pool key");
        require(V4Lib.sqrtPriceX96(PM, POOL_ID) > 0, "pool not initialized");

        vm.startBroadcast();
        bb = new RegiBuyback(PM, IERC20(USDC), REGI, HOOKS, 10_000, 200, INanoLedgerMinimal(ledger));
        sp = new RegiFeeSplitter(INanoLedgerMinimal(ledger), IERC20(USDC), safe, address(bb));
        vm.stopBroadcast();

        require(V4Lib.poolId(bb.key()) == POOL_ID, "deployed buyback: pool key");
        require(sp.buyback() == address(bb), "deployed splitter: buyback");
        require(address(bb.LEDGER()) == ledger && address(sp.LEDGER()) == ledger, "deployed pair: one ledger");
        require(sp.SAFE() == ADMIN_SAFE, "deployed splitter: Safe");

        console.log("RegiBuyback     ", address(bb));
        console.log("RegiFeeSplitter ", address(sp));
        console.log("next: CANARY GATE before any TREASURY points at the splitter:");
        console.log("  send 200 USDC to the buyback and press burnChunk() 4 times, 10 min apart;");
        console.log("  every press must burn REGI to 0x...dEaD. Only then DeployNanoStack with TREASURY =", address(sp));
    }

    /// @dev As DeployBase._isContract: an EIP-7702-delegated EOA carries 23 bytes of
    ///      code (0xef0100 ++ delegate) yet one key controls it; it is not a contract.
    function _isContract(address a) internal view returns (bool) {
        bytes memory c = a.code;
        if (c.length == 0) return false;
        return !(c.length == 23 && c[0] == 0xef && c[1] == 0x01 && c[2] == 0x00);
    }
}
