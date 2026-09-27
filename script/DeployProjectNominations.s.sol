// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {ProjectNominations} from "../src/perennial/ProjectNominations.sol";

/// @notice Deploy ProjectNominations: the Admin Safe holds DEFAULT_ADMIN + NOMINATOR,
/// the onboarder NOMINATOR, the deployer nothing (no handoff needed).
/// @dev env: ADMIN (mainnet: must be the Admin Safe), ONBOARDER (mainnet: required).
///   forge script script/DeployProjectNominations.s.sol:DeployProjectNominations --rpc-url <rpc> --broadcast
contract DeployProjectNominations is DeployBase {
    struct Config {
        address deployer;
        address admin;
        address onboarder;
    }

    address internal constant ADMIN_SAFE = 0xFeE926e8Be2D1C6192213cf20f31D94Dad1e80Fb;

    function run() external returns (ProjectNominations n) {
        n = deploy(Config({deployer: msg.sender, admin: vm.envAddress("ADMIN"), onboarder: vm.envOr("ONBOARDER", address(0))}));
        console2.log("ProjectNominations", address(n));
    }

    function deploy(Config memory c) public returns (ProjectNominations n) {
        _guardChain();
        require(c.admin != address(0), "ADMIN not set");
        require(c.admin != c.deployer && c.onboarder != c.deployer, "the deployer must hold no role");
        if (_isMainnet()) {
            require(c.admin == ADMIN_SAFE && _isContract(c.admin), "mainnet: ADMIN must be the Admin Safe 0xFeE9...80Fb");
            require(c.onboarder != address(0), "mainnet: ONBOARDER required");
        }
        vm.startBroadcast(c.deployer);
        n = new ProjectNominations(c.admin, c.onboarder);
        vm.stopBroadcast();
        require(!n.hasRole(n.DEFAULT_ADMIN_ROLE(), c.deployer) && !n.hasRole(n.NOMINATOR_ROLE(), c.deployer), "deployer holds a role");
        require(n.hasRole(n.DEFAULT_ADMIN_ROLE(), c.admin) && n.hasRole(n.NOMINATOR_ROLE(), c.admin), "admin roles missing");
    }
}
