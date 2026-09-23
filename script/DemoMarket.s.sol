// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../src/nanopay/MarketsV4.sol";

/// @notice Stands up one live MarketsV4 market end-to-end on the nanopay stack:
///         a bonded feed (deployer = agent), an attestation, a ledger deposit,
///         a market, and a demo buy so fees accrue on-chain. Prints feedId +
///         marketId to wire into the frontend.
contract DemoMarket is Script {
    function run() external {
        Registry reg = Registry(vm.envAddress("REGISTRY"));
        Attestation att = Attestation(vm.envAddress("ATTESTATION"));
        NanoLedger ledger = NanoLedger(vm.envAddress("NANO_LEDGER"));
        MarketsV4 mkt = MarketsV4(vm.envAddress("MARKETS_V4"));
        IERC20 usdc = IERC20(vm.envOr("USDC", address(0x3600000000000000000000000000000000000000)));

        bytes32 methHash = keccak256("nanopay-demo");

        vm.startBroadcast();
        address me = msg.sender;

        // 1. Bonded feed: deployer is creator AND agent (v2), resolver = deployer.
        usdc.approve(address(reg), type(uint256).max);
        bytes32 feedId = reg.createFeed("BTC/USD spot (nanopay demo)", methHash, 10e6, 1 hours, me);
        reg.registerAgent(feedId, methHash, 10e6);

        // 2. Attest a value so the feed is alive and the market is resolvable.
        att.attest(feedId, int256(123_456), keccak256("obs"));

        // 3. Fund the ledger and authorise MarketsV4 to pull from our balance.
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(40e6);
        ledger.approveSpender(address(mkt), type(uint256).max);

        // 4. Create a market: BTC/USD >= 100000, 7-day expiry, 10 USDC liquidity.
        bytes32 marketId = mkt.createMarket(
            feedId, me, int256(100_000), MarketsV4.Comparator.GreaterOrEqual,
            block.timestamp + 7 days, 10e6
        );

        // 5. Demo buy so the per-trade fee accrues on the ledger.
        mkt.buy(marketId, MarketsV4.Outcome.Yes, 5e6, 0);

        vm.stopBroadcast();

        console2.log("feedId:");
        console2.logBytes32(feedId);
        console2.log("marketId:");
        console2.logBytes32(marketId);
        console2.log("agent/creator:", me);
    }
}
