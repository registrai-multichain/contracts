// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProjectNominations} from "../../src/perennial/ProjectNominations.sol";
import {SourceKey} from "../../src/perennial/SourceKey.sol";
import {DeployProjectNominations} from "../../script/DeployProjectNominations.s.sol";

/// The on-chain list of nominated projects (the builders gallery's backup): the
/// Safe and the onboarder nominate a canonical source, with an optional hash of the
/// investigated profile. No funds; nothing else can write it.
contract ProjectNominationsTest is Test {
    address constant SAFE = 0xFeE926e8Be2D1C6192213cf20f31D94Dad1e80Fb;
    ProjectNominations n;
    address admin = makeAddr("admin");
    address onboarder = makeAddr("onboarder");
    address stranger = makeAddr("stranger");
    string constant SRC = "domain:arctools.fun";

    event Nominated(bytes32 indexed key, string source, bytes32 profileHash, address indexed by);
    event Unnominated(bytes32 indexed key, string source, address indexed by);

    function setUp() public {
        n = new ProjectNominations(admin, onboarder);
    }

    function test_nominateRecordsTheSourceHashNominatorAndTime() public {
        vm.warp(1_800_000_000);
        bytes32 key = SourceKey.keyOf(SRC);
        vm.expectEmit(true, true, false, true);
        emit Nominated(key, SRC, keccak256("profile"), onboarder);
        vm.prank(onboarder);
        n.nominate(SRC, keccak256("profile"));
        assertTrue(n.nominated(key));
        (bool active, bytes32 h, address by, uint64 at) = n.nominationOf(key);
        assertTrue(active);
        assertEq(h, keccak256("profile"));
        assertEq(by, onboarder);
        assertEq(at, 1_800_000_000);
        assertEq(n.sourceOf(key), SRC);
        assertEq(n.count(), 1);
    }

    function test_onlyNominatorsWrite() public {
        bytes32 role = n.NOMINATOR_ROLE(); // cached: a call in the arguments would consume the prank
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vm.prank(stranger);
        n.nominate(SRC, bytes32(0));
        vm.prank(admin);
        n.nominate(SRC, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vm.prank(stranger);
        n.unnominate(SRC);
    }

    function test_nonCanonicalSourcesAreRefused() public {
        vm.startPrank(onboarder);
        vm.expectRevert(SourceKey.NotCanonical.selector);
        n.nominate("domain:ArcTools.fun", bytes32(0));
        vm.expectRevert(SourceKey.NotCanonical.selector);
        n.nominate("https://arctools.fun", bytes32(0));
        vm.expectRevert(SourceKey.NotCanonical.selector);
        n.nominate("github:acme/tool.git", bytes32(0));
        vm.stopPrank();
    }

    function test_renominatingUpdatesTheHashWithoutDuplicatingTheListEntry() public {
        vm.startPrank(onboarder);
        n.nominate(SRC, keccak256("v1"));
        n.nominate(SRC, keccak256("v2"));
        vm.stopPrank();
        (, bytes32 h,,) = n.nominationOf(SourceKey.keyOf(SRC));
        assertEq(h, keccak256("v2"));
        assertEq(n.count(), 1);
    }

    function test_unnominateKeepsTheHistoryButClearsTheFlag() public {
        vm.startPrank(onboarder);
        n.nominate(SRC, keccak256("v1"));
        vm.expectEmit(true, true, false, true);
        emit Unnominated(SourceKey.keyOf(SRC), SRC, onboarder);
        n.unnominate(SRC);
        vm.stopPrank();
        assertFalse(n.nominated(SourceKey.keyOf(SRC)));
        assertEq(n.count(), 1, "the source stays listed (as not nominated)");
        vm.prank(onboarder);
        vm.expectRevert(ProjectNominations.NotNominated.selector);
        n.unnominate(SRC);
    }

    function test_pageListsEverySourceWithItsState() public {
        vm.startPrank(onboarder);
        n.nominate("domain:arctools.fun", bytes32(0));
        n.nominate("domain:www.myarcade.fun", bytes32(0));
        n.nominate("github:acme/tool", bytes32(0));
        n.unnominate("domain:www.myarcade.fun");
        vm.stopPrank();
        (string[] memory sources, ProjectNominations.Nomination[] memory ns) = n.page(0, 10);
        assertEq(sources.length, 3);
        assertEq(sources[1], "domain:www.myarcade.fun");
        assertFalse(ns[1].active);
        assertTrue(ns[2].active);
        (sources,) = n.page(2, 10);
        assertEq(sources.length, 1);
        (sources,) = n.page(5, 10);
        assertEq(sources.length, 0);
    }

    function test_theAdminManagesNominators_andZeroAddressesAreRefused() public {
        bytes32 role = n.NOMINATOR_ROLE();
        vm.prank(admin);
        n.revokeRole(role, onboarder);
        vm.prank(onboarder);
        vm.expectRevert();
        n.nominate(SRC, bytes32(0));
        vm.expectRevert(ProjectNominations.ZeroAddress.selector);
        new ProjectNominations(address(0), onboarder);
    }

    // ---- deploy script ----

    function test_localDeploy_grantsExactlyAdminAndOnboarder_deployerNone() public {
        address deployer = makeAddr("deployer");
        ProjectNominations d = new DeployProjectNominations().deploy(DeployProjectNominations.Config({deployer: deployer, admin: admin, onboarder: onboarder}));
        assertTrue(d.hasRole(d.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(d.hasRole(d.NOMINATOR_ROLE(), admin));
        assertTrue(d.hasRole(d.NOMINATOR_ROLE(), onboarder));
        assertFalse(d.hasRole(d.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(d.hasRole(d.NOMINATOR_ROLE(), deployer));
        assertFalse(d.hasRole(d.DEFAULT_ADMIN_ROLE(), onboarder));
    }

    function test_mainnetDeployRequiresTheSafeAsAdmin() public {
        vm.chainId(5042);
        vm.etch(SAFE, hex"00");
        DeployProjectNominations s = new DeployProjectNominations();
        vm.expectRevert(bytes("mainnet: ADMIN must be the Admin Safe 0xFeE9...80Fb"));
        s.deploy(DeployProjectNominations.Config({deployer: makeAddr("deployer"), admin: admin, onboarder: onboarder}));
        ProjectNominations d = s.deploy(DeployProjectNominations.Config({deployer: makeAddr("deployer"), admin: SAFE, onboarder: onboarder}));
        assertTrue(d.hasRole(d.DEFAULT_ADMIN_ROLE(), SAFE));
    }
}
