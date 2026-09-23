// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CurveMarket} from "../src/curve/CurveMarket.sol";

/// @notice Deploys CurveMarket and optionally opens a first BTC round.
///
///   forge script script/DeployCurveMarket.s.sol --rpc-url $RPC --broadcast
///
/// Arc uses USDC as both gas and collateral, and `0x3600…0000` is the ERC-20
/// view of the same native balance — so the collateral token needs no
/// approval plumbing beyond a normal ERC-20 allowance.
contract DeployCurveMarket is Script {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("chainId ", block.chainid);
        console2.log("deployer", deployer);
        console2.log("balance ", deployer.balance);

        vm.startBroadcast(pk);
        CurveMarket cm = new CurveMarket(ARC_USDC);
        vm.stopBroadcast();

        console2.log("CurveMarket", address(cm));
        require(address(cm.collateral()) == ARC_USDC, "collateral mismatch");
        console2.log("verified OK");
    }
}

/// @notice Opens one BTC round on an already-deployed CurveMarket.
///
///   CURVE_MARKET=0x.. STRIKE_CENTS=7788246 forge script \
///     script/DeployCurveMarket.s.sol:OpenBtcRound --rpc-url $RPC --broadcast
contract OpenBtcRound is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        CurveMarket cm = CurveMarket(vm.envAddress("CURVE_MARKET"));

        // Round window: opens now, closes in `OPEN_SECONDS`, settles shortly after.
        uint64 opensAt = uint64(block.timestamp);
        uint64 closesAt = uint64(block.timestamp + vm.envOr("OPEN_SECONDS", uint256(300)));
        uint64 resolveAfter = closesAt + 30;

        // The metric and rules documents are committed by hash so neither we nor
        // the resolver can restate the question after staking begins.
        bytes32 marketId = keccak256(abi.encodePacked("BTCUSD-5M-", block.timestamp));
        bytes32 metricHash = keccak256(
            "BTCUSD spot at closesAt, Coinbase BTC-USD spot, normalized to +/-0.4% of the strike, 9 buckets"
        );
        bytes32 rulesHash = keccak256(
            "Settles to the Coinbase BTC-USD spot price at closesAt. Invalid if the source is unavailable for 5 minutes."
        );

        console2.log("marketId");
        console2.logBytes32(marketId);

        vm.startBroadcast(pk);
        cm.createMarket(
            marketId,
            metricHash,
            rulesHash,
            deployer, // resolver — replaced by the price-source adapter later
            deployer, // fee recipient
            9, // buckets
            2000, // 20% jackpot share
            100, // 1% fee
            opensAt,
            closesAt,
            resolveAfter
        );
        vm.stopBroadcast();

        console2.log("opensAt     ", opensAt);
        console2.log("closesAt    ", closesAt);
        console2.log("resolveAfter", resolveAfter);
    }
}
