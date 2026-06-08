// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {SuffixTreasury} from "../src/suffix/SuffixTreasury.sol";

/// @notice Deploys the Suffix Pool treasury (NOT YET FOR PRODUCTION — research)
///         with the intended production admin posture: GOVERNOR_ROLE held by a
///         TimelockController, KEEPER_ROLE on a hot keeper key, and the deployer
///         renouncing its EOA governor/admin powers after initial setup.
///
/// @dev env: RPC, PRIVATE_KEY (deployer), USDC, optional KEEPER, optional
///      TIMELOCK_DELAY (seconds, default 2 days), SENIOR_CAP, MIN_CUSHION_BPS.
contract DeploySuffix is Script {
    function run() external returns (SuffixTreasury treasury, TimelockController timelock) {
        address usdc = vm.envAddress("USDC");
        address keeper = vm.envOr("KEEPER", msg.sender);
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(2 days));
        uint256 seniorCap = vm.envOr("SENIOR_CAP", uint256(0));
        uint256 minCushionBps = vm.envOr("MIN_CUSHION_BPS", uint256(0));
        string memory name_ = vm.envOr("SUFFIX_NAME", string("Suffix AI"));
        string memory symbol_ = vm.envOr("SUFFIX_SYMBOL", string("ai"));
        require(usdc != address(0), "USDC not configured");

        // HANDOFF=true (default, production): renounce EOA powers to a timelock.
        // HANDOFF=false (testnet): deployer keeps roles to seed + manage.
        bool handoff = vm.envOr("HANDOFF", true);

        vm.startBroadcast();

        // 1. Treasury — deployer is initial admin.
        treasury = new SuffixTreasury(IERC20(usdc), msg.sender, name_, symbol_);

        // 2. Initial parameter setup while the deployer still holds GOVERNOR.
        if (seniorCap > 0) treasury.setSeniorCap(seniorCap);
        if (minCushionBps > 0) treasury.setMinCushion(minCushionBps);
        if (keeper != msg.sender) treasury.grantRole(treasury.KEEPER_ROLE(), keeper);

        if (handoff) {
            // 3. Timelock — proposer/executor = deployer for now (move to a DAO/
            //    multisig later); no extra admin (self-administered).
            address[] memory props = new address[](1);
            props[0] = msg.sender;
            address[] memory execs = new address[](1);
            execs[0] = msg.sender;
            timelock = new TimelockController(delay, props, execs, address(0));

            // 4. Hand governance to the timelock; deployer renounces EOA powers.
            treasury.grantRole(treasury.GOVERNOR_ROLE(), address(timelock));
            treasury.grantRole(treasury.DEFAULT_ADMIN_ROLE(), address(timelock));
            treasury.renounceRole(treasury.GOVERNOR_ROLE(), msg.sender);
            treasury.renounceRole(treasury.DEFAULT_ADMIN_ROLE(), msg.sender);
        }

        vm.stopBroadcast();

        console2.log("SuffixTreasury:", address(treasury));
        console2.log("  senior ($ai):", address(treasury.senior()));
        console2.log("  junior ($aiLP):", address(treasury.junior()));
        console2.log("TimelockController (GOVERNOR):", address(timelock));
        console2.log("timelock delay (s):", delay);
    }
}
