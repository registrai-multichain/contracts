// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";

/// @notice Phase 2, step 2 of the mainnet order. Deploys NanoLedger, the on-chain
///         nanopayment settlement layer. (No market needs a ledger role: neither
///         market kind creates fee pools, so MarketsV4 is no longer a ledger source.)
///
///         On mainnet the ledger is born owned by the Admin Safe (env ADMIN, required
///         and pinned): it deploys weeks before the rest of the stack (the REGI buyback
///         and its splitter need it first), so the deployer never holds a role. This is
///         compatible with Handoff: its grant loop skips roles ADMIN already has, it only
///         renounces roles the deployer holds, and _verifyRoles expects ledger
///         GOVERNOR + DEFAULT_ADMIN = ADMIN, deployer none. On testnet/local ADMIN
///         defaults to the deployer (the historical behaviour, handed off later).
///
/// Admin handoff is NOT done here. `script/Handoff.s.sol` is the single handoff
/// for the whole stack and runs last. The old HANDOFF=true path (a timelock
/// proposed/executed by the deployer, and the deployer renouncing before
/// setSource) broke the forced order and has been retired: setting it reverts.
///
/// @dev env: ADMIN [deployer; on mainnet REQUIRED = the Admin Safe 0xFeE9…80Fb],
///      USDC [0x3600…0000] (must be 0x3600…0000 on mainnet).
contract DeployNanoLedger is DeployBase {
    struct Config {
        address deployer;
        address usdc;
    }

    /// The Admin Safe (deployments/arc-mainnet.json builders.roles.adminSafe).
    address internal constant ADMIN_SAFE = 0xFeE926e8Be2D1C6192213cf20f31D94Dad1e80Fb;

    function run() external returns (NanoLedger ledger) {
        _guardChain();
        require(!vm.envOr("HANDOFF", false), "HANDOFF is retired: run script/Handoff.s.sol after the whole stack");
        address admin = _addrReq("ADMIN", msg.sender);
        // Deploying now, ahead of the stack: on mainnet the ledger is born Safe-owned.
        if (_isMainnet()) require(admin == ADMIN_SAFE, "mainnet: ADMIN must be the Admin Safe 0xFeE9...80Fb");
        ledger = deployOwned(Config({deployer: msg.sender, usdc: vm.envOr("USDC", ARC_USDC)}), admin);
        console2.log("NanoLedger:", address(ledger));
        console2.log("  USDC:", address(ledger.USDC()));
        console2.log("  DEFAULT_ADMIN + GOVERNOR:", admin);
        console2.log("  deployer holds a role:", ledger.hasRole(ledger.DEFAULT_ADMIN_ROLE(), msg.sender) || ledger.hasRole(ledger.GOVERNOR_ROLE(), msg.sender));
    }

    /// @notice The historical entry: the deployer is admin/governor until Handoff.
    function deploy(Config memory c) public returns (NanoLedger ledger) {
        return deployOwned(c, c.deployer);
    }

    /// @notice Deploy with `admin` as DEFAULT_ADMIN + GOVERNOR. On mainnet an admin other than
    ///         the deployer must be the Admin Safe, and then the deployer holds no role.
    function deployOwned(Config memory c, address admin) public returns (NanoLedger ledger) {
        _guardChain();
        require(c.deployer != address(0), "deployer not set");
        require(admin != address(0), "ADMIN not set");
        if (_isMainnet()) {
            require(c.usdc == ARC_USDC, "mainnet USDC must be 0x3600...0000");
            // The deployer-owned path (admin == deployer, handed off by Handoff after the whole
            // stack) stays available for the full-stack order; any OTHER admin must be the Safe.
            if (admin != c.deployer) {
                require(admin == ADMIN_SAFE && _isContract(admin), "mainnet: ADMIN must be the Admin Safe 0xFeE9...80Fb");
            }
        }
        vm.startBroadcast(c.deployer);
        ledger = new NanoLedger(IERC20(c.usdc), admin);
        vm.stopBroadcast();
        require(ledger.hasRole(ledger.DEFAULT_ADMIN_ROLE(), admin) && ledger.hasRole(ledger.GOVERNOR_ROLE(), admin), "admin roles");
        if (admin != c.deployer) {
            require(
                !ledger.hasRole(ledger.DEFAULT_ADMIN_ROLE(), c.deployer) && !ledger.hasRole(ledger.GOVERNOR_ROLE(), c.deployer),
                "deployer must hold no role"
            );
        }
    }
}
