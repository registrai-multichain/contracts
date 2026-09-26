// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {DeployNanoLedger} from "../../script/DeployNanoLedger.s.sol";

/// The shared ledger deploys weeks before the rest of the stack, so it is born with the
/// Admin Safe as DEFAULT_ADMIN + GOVERNOR and the deployer holding nothing.
contract DeployNanoLedgerTest is Test {
    address constant SAFE = 0xFeE926e8Be2D1C6192213cf20f31D94Dad1e80Fb;
    address deployer = makeAddr("deployer");

    function test_localDeployGivesTheAdminBothRolesAndTheDeployerNone() public {
        if (block.chainid == 5042) return; // a mock USDC is (rightly) refused on mainnet
        address admin = makeAddr("admin");
        MockUSDC usdc = new MockUSDC();
        NanoLedger l = new DeployNanoLedger().deployOwned(DeployNanoLedger.Config({deployer: deployer, usdc: address(usdc)}), admin);
        assertTrue(l.hasRole(l.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(l.hasRole(l.GOVERNOR_ROLE(), admin));
        assertFalse(l.hasRole(l.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(l.hasRole(l.GOVERNOR_ROLE(), deployer));
        assertEq(address(l.USDC()), address(usdc));
    }

    function test_zeroAdminIsRefused() public {
        MockUSDC usdc = new MockUSDC();
        DeployNanoLedger d = new DeployNanoLedger();
        vm.expectRevert(bytes("ADMIN not set"));
        d.deployOwned(DeployNanoLedger.Config({deployer: deployer, usdc: address(usdc)}), address(0));
    }

    // ---- Arc mainnet fork: forge test --match-path test/nanopay/DeployNanoLedger.t.sol --fork-url arc_mainnet ----

    function test_mainnetRefusesAnyAdminButTheSafe() public {
        if (block.chainid != 5042) return;
        DeployNanoLedger d = new DeployNanoLedger();
        vm.expectRevert(bytes("mainnet: ADMIN must be the Admin Safe 0xFeE9...80Fb"));
        d.deployOwned(DeployNanoLedger.Config({deployer: deployer, usdc: 0x3600000000000000000000000000000000000000}), makeAddr("not-the-safe"));
    }

    function test_mainnetDeployIsSafeOwnedOnArcUsdc() public {
        if (block.chainid != 5042) return;
        NanoLedger l = new DeployNanoLedger().deployOwned(DeployNanoLedger.Config({deployer: deployer, usdc: 0x3600000000000000000000000000000000000000}), SAFE);
        assertTrue(l.hasRole(l.DEFAULT_ADMIN_ROLE(), SAFE));
        assertTrue(l.hasRole(l.GOVERNOR_ROLE(), SAFE));
        assertFalse(l.hasRole(l.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(l.hasRole(l.GOVERNOR_ROLE(), deployer));
        assertEq(address(l.USDC()), 0x3600000000000000000000000000000000000000);
        assertEq(l.totalOwed(), 0);
    }
}
