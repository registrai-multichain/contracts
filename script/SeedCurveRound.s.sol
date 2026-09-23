// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveMarket} from "../src/curve/CurveMarket.sol";

/// @notice Seeds a curve round with a small real distribution so the ladder
///         shows genuine on-chain depth rather than a placeholder.
///
///   CURVE_MARKET=0x.. MARKET_ID=0x.. forge script \
///     script/SeedCurveRound.s.sol --rpc-url $RPC --broadcast
contract SeedCurveRound is Script {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        CurveMarket cm = CurveMarket(vm.envAddress("CURVE_MARKET"));
        bytes32 marketId = vm.envBytes32("MARKET_ID");

        // A plausible bell across nine bands, in USDC base units (6dp).
        // Deliberately small: this is testnet depth for legibility, not liquidity.
        uint256[9] memory amounts =
            [uint256(40_000), 80_000, 150_000, 260_000, 340_000, 250_000, 140_000, 70_000, 30_000];

        uint256 total;
        for (uint256 i = 0; i < 9; i++) {
            total += amounts[i];
        }
        console2.log("seeding total (base units)", total);
        console2.log("deployer balance          ", deployer.balance);

        vm.startBroadcast(pk);
        IERC20(ARC_USDC).approve(address(cm), total);
        for (uint8 b = 0; b < 9; b++) {
            cm.stake(marketId, b, amounts[b]);
        }
        vm.stopBroadcast();

        console2.log("seeded. pool now:");
        uint256[41] memory stakes = cm.bucketStakes(marketId);
        for (uint8 b = 0; b < 9; b++) {
            console2.log(uint256(b), stakes[b]);
        }
    }
}
