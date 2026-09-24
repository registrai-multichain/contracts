// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {ProgressArbiter} from "../../src/perennial/ProgressArbiter.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {DeployBase} from "../../script/lib/DeployBase.sol";
import {RoleTable} from "../../script/lib/RoleTable.sol";
import {DeployOracle} from "../../script/DeployOracle.s.sol";
import {DeployNanoLedger} from "../../script/DeployNanoLedger.s.sol";
import {DeployPerennial} from "../../script/DeployPerennial.s.sol";
import {DeployBuilders} from "../../script/DeployBuilders.s.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {DeployArbiter} from "../../script/DeployArbiter.s.sol";
import {DeployNanoStack} from "../../script/DeployNanoStack.s.sol";
import {Handoff} from "../../script/Handoff.s.sol";
import {VerifyRoles} from "../../script/VerifyRoles.s.sol";

/// Stand-in for a Safe / timelock: all Handoff needs is that ADMIN has code.
contract SafeStub {}

/// Exposes RoleTable's phase-2 onboarder guard.
contract OnboarderCheck is RoleTable {
    function check(Stack memory s, address onboarder) external view {
        _verifyOnboarder(s, onboarder, false);
    }
}

/// Exposes DeployBase's env helpers.
contract EnvHarness is DeployBase {
    function uintReq(string memory name, uint256 d) external view returns (uint256) {
        return _uintReq(name, d);
    }

    function addrReq(string memory name, address d) external view returns (address) {
        return _addrReq(name, d);
    }

    function guard() external view {
        _guardChain();
    }
}

/// @notice Runs the real deploy-script logic, in the forced mainnet order,
/// against a local chain: DeployOracle -> DeployNanoLedger -> DeployPerennial ->
/// DeployArbiter -> DeployNanoStack -> Handoff -> VerifyRoles.
contract DeployScriptsTest is Test {
    MockUSDC usdc;
    address deployer = makeAddr("deployer");
    address admin;
    address agent = makeAddr("agent");
    address disputeResolver = makeAddr("disputeResolver");
    address proposer = makeAddr("proposer");
    address arbResolver = makeAddr("arbResolver");
    address treasury = makeAddr("treasury");
    address protocolTreasury = makeAddr("protocolTreasury");

    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    ProgressPool pool;
    MarketsPerennial perennial;
    ProgressArbiter arbiter;
    MarketsV4 v4;

    bytes32 constant DEFAULT_ADMIN = 0x00;
    bytes32 constant GOVERNOR = keccak256("GOVERNOR_ROLE");
    bytes32 constant REGISTRAR = keccak256("REGISTRAR_ROLE");
    bytes32 constant PROGRESS = keccak256("PROGRESS_ROLE");
    bytes32 constant PROPOSER = keccak256("PROPOSER_ROLE");
    bytes32 constant RESOLVER = keccak256("RESOLVER_ROLE");

    function setUp() public {
        usdc = new MockUSDC();
        admin = address(new SafeStub());
    }

    function _usdcAddr() internal view returns (address) {
        return block.chainid == 5042 ? 0x3600000000000000000000000000000000000000 : address(usdc);
    }

    function _deployAll() internal {
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 10e6, points: address(0)})
        );
        ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
        DeployPerennial.Config memory pc = _perennialCfg();
        if (block.chainid == 5042) {
            // mainnet: the builder side is phase 1; markets must reuse it
            (BuilderRegistry b1, CaretakerRegistry c1,) = new DeployBuilders().deploy(_buildersCfg());
            (pc.builders, pc.caretakers) = (address(b1), address(c1));
        }
        (builders, caretakers, pool, perennial) = new DeployPerennial().deploy(pc);
        arbiter = new DeployArbiter().deploy(_arbiterCfg());
        (, v4) = new DeployNanoStack().deploy(_v4Cfg());
    }

    function _perennialCfg() internal view returns (DeployPerennial.Config memory c) {
        c.deployer = deployer;
        c.registry = address(registry);
        c.attestation = address(attestation);
        c.ledger = address(ledger);
        c.epochLength = 30 days;
        c.streamWindow = 30 days;
        c.settlementWindow = 24 hours;
        c.resolutionGrace = 7 days;
        c.protocolTreasury = protocolTreasury;
        c.approvedAgent = agent;
        c.disputeResolver = disputeResolver;
    }

    function _arbiterCfg() internal view returns (DeployArbiter.Config memory c) {
        c.deployer = deployer;
        c.ledger = address(ledger);
        c.pool = address(pool);
        c.builders = address(builders);
        c.caretakers = address(caretakers);
        c.proposer = proposer;
        c.resolver = arbResolver;
        c.challengeWindow = 1 hours;
        c.stakePerProposal = 50e6;
        c.maxWeight = 10;
        c.resolveTimeout = 7 days;
    }

    function _v4Cfg() internal view returns (DeployNanoStack.Config memory c) {
        c.deployer = deployer;
        c.usdc = _usdcAddr();
        c.registry = address(registry);
        c.attestation = address(attestation);
        c.ledger = address(ledger);
        c.treasury = treasury;
        c.settlementWindow = 24 hours;
        c.resolutionGrace = 7 days;
        c.disputeResolver = disputeResolver;
    }

    function _stack() internal view returns (RoleTable.Stack memory s) {
        s.registry = address(registry);
        s.attestation = address(attestation);
        s.ledger = address(ledger);
        s.builders = address(builders);
        s.caretakers = address(caretakers);
        s.pool = address(pool);
        s.perennial = address(perennial);
        s.v4 = address(v4);
        s.arbiter = address(arbiter);
    }

    /// Every (contract, role) that exists anywhere in the stack.
    function _allRoles() internal view returns (address[] memory w, bytes32[] memory r) {
        w = new address[](17);
        r = new bytes32[](17);
        address[9] memory acs = [
            address(ledger), address(builders), address(caretakers), address(pool), address(perennial), address(v4),
            address(arbiter), address(0), address(0)
        ];
        uint256 n;
        for (uint256 i; i < 7; i++) {
            w[n] = acs[i];
            r[n++] = DEFAULT_ADMIN;
        }
        (w[n], r[n++]) = (address(ledger), GOVERNOR);
        (w[n], r[n++]) = (address(builders), REGISTRAR);
        (w[n], r[n++]) = (address(caretakers), GOVERNOR);
        (w[n], r[n++]) = (address(pool), GOVERNOR);
        (w[n], r[n++]) = (address(pool), PROGRESS);
        (w[n], r[n++]) = (address(perennial), GOVERNOR);
        (w[n], r[n++]) = (address(v4), GOVERNOR);
        (w[n], r[n++]) = (address(arbiter), PROPOSER);
        (w[n], r[n++]) = (address(arbiter), RESOLVER);
        (w[n], r[n++]) = (address(arbiter), DEFAULT_ADMIN); // repeat is harmless
        assertEq(n, 17);
    }

    function _assertDeployerHoldsNothing() internal view {
        (address[] memory w, bytes32[] memory r) = _allRoles();
        for (uint256 i; i < w.length; i++) {
            assertFalse(IAccessControl(w[i]).hasRole(r[i], deployer), "deployer still holds a role");
        }
    }

    // ───────────── the forced order ─────────────

    function test_forcedOrder_thenHandoff_deployerHoldsNothing() public {
        _deployAll();
        // before Handoff the deployer holds the admin roles (the wiring needs them)
        assertTrue(pool.hasRole(DEFAULT_ADMIN, deployer));
        assertFalse(ledger.isSource(address(v4)), "V4 needs no ledger role");
        assertEq(perennial.commons(), address(pool));
        assertEq(pool.PROTOCOL_TREASURY(), protocolTreasury);
        assertEq(v4.TREASURY(), treasury);
        assertTrue(perennial.approvedAgent(agent));
        assertTrue(perennial.approvedResolver(disputeResolver));
        assertTrue(v4.approvedResolver(disputeResolver));
        assertTrue(perennial.isApprovedFeed(bytes32(0), agent) == false);

        new Handoff().handoff(_stack(), admin, deployer);

        _assertDeployerHoldsNothing();
        assertFalse(pool.hasRole(DEFAULT_ADMIN, deployer), "deployer lacks DEFAULT_ADMIN after Handoff");
        assertTrue(pool.hasRole(DEFAULT_ADMIN, admin));
        assertTrue(arbiter.hasRole(DEFAULT_ADMIN, admin));
        assertTrue(v4.hasRole(GOVERNOR, admin));
        assertTrue(builders.hasRole(REGISTRAR, admin));
        assertTrue(pool.hasRole(PROGRESS, address(arbiter)));
        assertFalse(pool.hasRole(PROGRESS, admin));
        new VerifyRoles().verify(_stack(), admin, deployer);
    }

    // ───────────── phase 1: builders before markets ─────────────

    address onboarder = makeAddr("onboarder");

    function _buildersCfg() internal view returns (DeployBuilders.Config memory c) {
        c.deployer = deployer;
        c.admin = admin;
        c.operator = proposer; // the keeper operator
        c.onboarder = onboarder;
        c.chainLabel = "Arc Mainnet";
        c.imageBase = "https://registrai.cc/badge/arc/";
        c.externalBase = "https://registrai.cc/builders/?builder=";
    }

    /// Phase 1 puts only the builder side on chain (ADMIN holds everything, the
    /// deployer nothing); builders register, get a caretaker and a badge; phase 2
    /// runs the forced order reusing the registries and hands off cleanly.
    function _phase1ThenMarkets() internal {
        VerifiedBuilderBadge badge;
        (builders, caretakers, badge) = new DeployBuilders().deploy(_buildersCfg());
        assertFalse(builders.hasRole(DEFAULT_ADMIN, deployer));
        assertFalse(caretakers.hasRole(GOVERNOR, deployer));
        assertTrue(builders.hasRole(REGISTRAR, admin) && caretakers.hasRole(GOVERNOR, admin));
        assertTrue(badge.hasRole(badge.STATUS_ROLE(), proposer) && !badge.hasRole(badge.ISSUER_ROLE(), proposer));

        // the gallery's life before any market: claim, then the ONBOARDER (hot
        // wallet) onboards without the Safe
        address alice = makeAddr("alice");
        vm.prank(alice);
        uint256 id = builders.registerBuilder("registrai:github:alice/app");
        vm.startPrank(onboarder);
        caretakers.setCaretaker(id, proposer);
        uint256 serial = badge.issue(id);
        vm.stopPrank();

        // phase 2: the forced order, reusing the registries
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 10e6, points: address(0)})
        );
        ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
        DeployPerennial.Config memory pc = _perennialCfg();
        pc.builders = address(builders);
        pc.caretakers = address(caretakers);
        (BuilderRegistry b2, CaretakerRegistry c2, ProgressPool p2, MarketsPerennial m2) = new DeployPerennial().deploy(pc);
        (pool, perennial) = (p2, m2);
        assertEq(address(b2), address(builders), "registry reused");
        assertEq(address(c2), address(caretakers), "caretakers reused");
        assertEq(address(pool.BUILDERS()), address(builders));
        assertEq(address(perennial.BUILDERS()), address(builders));
        arbiter = new DeployArbiter().deploy(_arbiterCfg());
        (, v4) = new DeployNanoStack().deploy(_v4Cfg());
        new Handoff().handoff(_stack(), admin, deployer);
        _assertDeployerHoldsNothing();
        new VerifyRoles().verify(_stack(), admin, deployer);
        if (block.chainid == 5042) {
            // audit M-1: on mainnet the hot wallet must lose setCaretaker before markets
            OnboarderCheck chk = new OnboarderCheck();
            vm.expectRevert(bytes("mainnet: revoke the ONBOARDER's CaretakerRegistry GOVERNOR before markets"));
            chk.check(_stack(), onboarder);
            vm.prank(admin);
            caretakers.revokeRole(GOVERNOR, onboarder);
        }
        new OnboarderCheck().check(_stack(), onboarder);

        // everything done in phase 1 carried over
        assertEq(builders.builderIdOf(alice), id);
        assertTrue(caretakers.isCaretaker(id, proposer));
        assertEq(badge.ownerOf(serial), alice);
    }

    function test_phase1Builders_thenMarketsReuseRegistries() public {
        _phase1ThenMarkets();
    }

    function test_phase1Builders_onMainnetChainId() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        _phase1ThenMarkets();
    }

    function test_phase1Builders_refusesEOAAdminOnMainnetAndSharedKeys() public {
        DeployBuilders d = new DeployBuilders();
        DeployBuilders.Config memory c = _buildersCfg();
        c.operator = admin;
        vm.expectRevert(bytes("ADMIN and OPERATOR must differ: the operator may only set badge status"));
        d.deploy(c);
        c = _buildersCfg();
        c.admin = deployer;
        vm.expectRevert(bytes("ADMIN must not be the deployer"));
        d.deploy(c);
        vm.chainId(5042);
        c = _buildersCfg();
        c.admin = makeAddr("eoaAdmin");
        vm.expectRevert(bytes("mainnet: ADMIN must be a contract (Safe/timelock), not an EOA"));
        d.deploy(c);
    }

    /// The onboarder can onboard, issue and revoke — and nothing else; the Safe
    /// takes its roles back in one call each; the deployer never keeps a role.
    function test_phase1Onboarder_isLimitedAndRemovable() public {
        (BuilderRegistry b, CaretakerRegistry ct, VerifiedBuilderBadge badge) = new DeployBuilders().deploy(_buildersCfg());
        bytes32 issuer = badge.ISSUER_ROLE();
        bytes32 gov = ct.GOVERNOR_ROLE();
        assertTrue(badge.hasRole(issuer, onboarder) && ct.hasRole(gov, onboarder));
        assertFalse(badge.hasRole(DEFAULT_ADMIN, onboarder) || ct.hasRole(DEFAULT_ADMIN, onboarder) || b.hasRole(DEFAULT_ADMIN, onboarder));
        assertFalse(b.hasRole(REGISTRAR, onboarder) || badge.hasRole(badge.STATUS_ROLE(), onboarder));
        assertFalse(badge.hasRole(DEFAULT_ADMIN, deployer) || badge.hasRole(issuer, deployer) || ct.hasRole(DEFAULT_ADMIN, deployer) || ct.hasRole(gov, deployer));
        assertTrue(badge.hasRole(DEFAULT_ADMIN, admin) && badge.hasRole(issuer, admin) && ct.hasRole(DEFAULT_ADMIN, admin) && ct.hasRole(gov, admin));

        address bob = makeAddr("bob");
        vm.prank(bob);
        uint256 id = b.registerBuilder("registrai:domain:bob.xyz");
        vm.startPrank(onboarder);
        ct.setCaretaker(id, proposer);
        badge.issue(id);
        vm.expectRevert();
        badge.revoke(id); // REVOKER stays with the Safe (audit L-3)
        vm.expectRevert();
        b.setActive(id, false); // REGISTRAR stays with the Safe
        vm.expectRevert();
        b.registerFor(makeAddr("squat"), "registrai:github:x/y");
        vm.expectRevert();
        badge.grantRole(issuer, makeAddr("friend"));
        vm.expectRevert();
        badge.setBases("x", "y");
        vm.expectRevert();
        badge.setLapsed(id, true);
        vm.stopPrank();

        assertFalse(badge.hasRole(badge.REVOKER_ROLE(), onboarder));
        assertTrue(badge.hasRole(badge.REVOKER_ROLE(), admin));
        vm.prank(admin);
        badge.revoke(id);

        vm.startPrank(admin);
        badge.revokeRole(issuer, onboarder);
        ct.revokeRole(gov, onboarder);
        vm.stopPrank();
        vm.prank(onboarder);
        vm.expectRevert();
        badge.issue(id);
    }

    function test_phase1_withoutOnboarder_stillAllSafe() public {
        DeployBuilders.Config memory c = _buildersCfg();
        c.onboarder = address(0);
        (BuilderRegistry b, CaretakerRegistry ct, VerifiedBuilderBadge badge) = new DeployBuilders().deploy(c);
        assertTrue(badge.hasRole(badge.ISSUER_ROLE(), admin) && ct.hasRole(ct.GOVERNOR_ROLE(), admin) && b.hasRole(REGISTRAR, admin));
        assertFalse(badge.hasRole(DEFAULT_ADMIN, deployer) || ct.hasRole(DEFAULT_ADMIN, deployer));
    }

    function test_phase1_onboarderMustBeDistinct() public {
        DeployBuilders d = new DeployBuilders();
        DeployBuilders.Config memory c = _buildersCfg();
        c.onboarder = admin;
        vm.expectRevert(bytes("ONBOARDER must differ from ADMIN, OPERATOR and the deployer"));
        d.deploy(c);
        c.onboarder = proposer;
        vm.expectRevert(bytes("ONBOARDER must differ from ADMIN, OPERATOR and the deployer"));
        d.deploy(c);
        c.onboarder = deployer;
        vm.expectRevert(bytes("ONBOARDER must differ from ADMIN, OPERATOR and the deployer"));
        d.deploy(c);
    }

    /// Phase 2 guard: an onboarder holding any market/admin role fails VerifyRoles.
    function test_phase2_verifyRolesRefusesOnboarderWithMarketRole() public {
        _phase1ThenMarkets();
        vm.prank(admin);
        pool.grantRole(GOVERNOR, onboarder);
        OnboarderCheck chk = new OnboarderCheck();
        vm.expectRevert(bytes("ONBOARDER holds ProgressPool GOVERNOR"));
        chk.check(_stack(), onboarder);
    }

    function test_perennial_reuseNeedsBothMatchingRegistries() public {
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 10e6, points: address(0)})
        );
        ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
        (BuilderRegistry b1, CaretakerRegistry c1,) = new DeployBuilders().deploy(_buildersCfg());
        (, CaretakerRegistry cOther,) = new DeployBuilders().deploy(_buildersCfg());
        DeployPerennial p = new DeployPerennial();

        DeployPerennial.Config memory pc = _perennialCfg();
        pc.builders = address(b1);
        vm.expectRevert(bytes("BUILDER_REGISTRY and CARETAKER_REGISTRY: both or neither"));
        p.deploy(pc);

        pc.caretakers = address(cOther);
        vm.expectRevert(bytes("CARETAKER_REGISTRY belongs to a different BuilderRegistry"));
        p.deploy(pc);

        pc.caretakers = address(c1);
        (BuilderRegistry b,,,) = p.deploy(pc);
        assertEq(address(b), address(b1));
    }

    /// The same order on chainid 5042, with every mainnet validation active.
    function test_forcedOrder_onMainnetChainId() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        _deployAll();
        new Handoff().handoff(_stack(), admin, deployer);
        _assertDeployerHoldsNothing();
        new VerifyRoles().verify(_stack(), admin, deployer);
    }

    function test_verifyRoles_failsBeforeHandoff() public {
        _deployAll();
        VerifyRoles v = new VerifyRoles();
        vm.expectRevert();
        v.verify(_stack(), admin, deployer);
    }

    // ───────────── Handoff refuses bad admins ─────────────

    function test_handoff_refusesAdminEqualsDeployer() public {
        _deployAll();
        Handoff h = new Handoff();
        RoleTable.Stack memory s = _stack();
        vm.expectRevert(bytes("ADMIN must not be the deployer"));
        h.handoff(s, deployer, deployer);
    }

    function test_handoff_mainnet_refusesEOAAdmin() public {
        _deployAll();
        vm.chainId(5042);
        Handoff h = new Handoff();
        RoleTable.Stack memory s = _stack();
        address eoa = makeAddr("eoaAdmin");
        vm.expectRevert(bytes("mainnet: ADMIN must be a contract (Safe/timelock), not an EOA"));
        h.handoff(s, eoa, deployer);
    }

    function test_handoff_testnet_allowsEOAAdmin() public {
        _deployAll();
        vm.chainId(5042002);
        address eoa = makeAddr("eoaAdmin");
        new Handoff().handoff(_stack(), eoa, deployer);
        _assertDeployerHoldsNothing();
    }

    // ───────────── regression ports (PoC) ─────────────

    /// PoC test_deployerAdminDrainsCommons: the deployer kept DEFAULT_ADMIN on the
    /// pool, re-granted itself PROGRESS_ROLE and drained the commons. After
    /// Handoff every step of that attack reverts.
    function test_regression_deployerCannotDrainCommonsAfterHandoff() public {
        _deployAll();
        new Handoff().handoff(_stack(), admin, deployer);
        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN)
        );
        pool.grantRole(PROGRESS, deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, REGISTRAR)
        );
        builders.registerFor(address(0xD3AD), "me");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, PROGRESS)
        );
        pool.addProgress(address(0xD3AD), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, GOVERNOR)
        );
        pool.setEpochLength(0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, GOVERNOR)
        );
        ledger.skimSurplus(deployer);
        vm.stopPrank();
    }

    /// PoC test_arbiterAdminBypassesChallengeWindow: the deployer shrank the
    /// challenge window, made itself proposer and pushed 1e30 weight. After
    /// Handoff it has no arbiter power.
    function test_regression_deployerCannotBypassArbiterAfterHandoff() public {
        _deployAll();
        new Handoff().handoff(_stack(), admin, deployer);
        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN)
        );
        arbiter.setParams(1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN)
        );
        arbiter.setMaxWeightPerProposal(type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN)
        );
        arbiter.grantRole(PROPOSER, deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, GOVERNOR)
        );
        caretakers.setCaretaker(1, deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, PROPOSER)
        );
        arbiter.propose(address(0xB111), 1);
        vm.stopPrank();
        // ADMIN (the Safe) keeps the powers
        vm.prank(admin);
        arbiter.setMaxWeightPerProposal(20);
        assertEq(arbiter.maxWeightPerProposal(), 20);
    }

    // ───────────── chain guard + required inputs ─────────────

    function test_scripts_refuseUnknownChain() public {
        vm.chainId(1);
        DeployOracle o = new DeployOracle();
        vm.expectRevert(bytes("unsupported chain: only Arc mainnet 5042, Arc testnet 5042002, local 31337"));
        o.deploy(DeployOracle.Config({deployer: deployer, usdc: address(usdc), minBond: 10e6, points: address(0)}));
        DeployNanoLedger l = new DeployNanoLedger();
        vm.expectRevert(bytes("unsupported chain: only Arc mainnet 5042, Arc testnet 5042002, local 31337"));
        l.deploy(DeployNanoLedger.Config({deployer: deployer, usdc: address(usdc)}));
        DeployPerennial p = new DeployPerennial();
        DeployPerennial.Config memory pc = _perennialCfg();
        vm.expectRevert(bytes("unsupported chain: only Arc mainnet 5042, Arc testnet 5042002, local 31337"));
        p.deploy(pc);
        DeployArbiter a = new DeployArbiter();
        DeployArbiter.Config memory ac = _arbiterCfg();
        vm.expectRevert(bytes("unsupported chain: only Arc mainnet 5042, Arc testnet 5042002, local 31337"));
        a.deploy(ac);
        DeployNanoStack n = new DeployNanoStack();
        DeployNanoStack.Config memory nc = _v4Cfg();
        vm.expectRevert(bytes("unsupported chain: only Arc mainnet 5042, Arc testnet 5042002, local 31337"));
        n.deploy(nc);
        Handoff h = new Handoff();
        RoleTable.Stack memory s = _stack();
        vm.expectRevert(bytes("unsupported chain: only Arc mainnet 5042, Arc testnet 5042002, local 31337"));
        h.handoff(s, admin, deployer);
        EnvHarness e = new EnvHarness();
        vm.expectRevert(bytes("unsupported chain: only Arc mainnet 5042, Arc testnet 5042002, local 31337"));
        e.guard();
    }

    function test_env_requiredOnMainnet_defaultedElsewhere() public {
        EnvHarness e = new EnvHarness();
        string memory unset = "ARC_TEST_VAR_THAT_IS_NEVER_SET_7F3A";
        vm.chainId(5042002);
        assertEq(e.uintReq(unset, 42), 42);
        assertEq(e.addrReq(unset, address(0xBEEF)), address(0xBEEF));
        vm.chainId(31337);
        assertEq(e.uintReq(unset, 42), 42);
        vm.chainId(5042);
        vm.expectRevert(bytes("mainnet: required env var not set: ARC_TEST_VAR_THAT_IS_NEVER_SET_7F3A"));
        e.uintReq(unset, 42);
        vm.expectRevert(bytes("mainnet: required env var not set: ARC_TEST_VAR_THAT_IS_NEVER_SET_7F3A"));
        e.addrReq(unset, address(0xBEEF));
    }

    /// M4: EPOCH_LENGTH = 0 lets finalize + closeEpoch in one tx grab the pot.
    function test_perennial_mainnetRequiresPositiveEpoch() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 10e6, points: address(0)})
        );
        ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
        DeployPerennial p = new DeployPerennial();
        DeployPerennial.Config memory c = _perennialCfg();
        c.epochLength = 0;
        vm.expectRevert(bytes("mainnet: EPOCH_LENGTH must be > 0"));
        p.deploy(c);
        c.epochLength = 30 days;
        c.disputeResolver = deployer;
        vm.expectRevert(bytes("mainnet: DISPUTE_RESOLVER must not be the deployer"));
        p.deploy(c);
        // testnet keeps the same-session demo default
        vm.chainId(5042002);
        c = _perennialCfg();
        c.epochLength = 0;
        (,, ProgressPool pl,) = p.deploy(c);
        assertEq(pl.epochLength(), 0);
    }

    function test_perennial_mainnetRefusesDeployerAsProtocolTreasury() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 10e6, points: address(0)})
        );
        ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
        DeployPerennial p = new DeployPerennial();
        DeployPerennial.Config memory c = _perennialCfg();
        c.protocolTreasury = deployer;
        vm.expectRevert(bytes("mainnet: PROTOCOL_TREASURY must not be the deployer"));
        p.deploy(c);
        c.protocolTreasury = address(0);
        vm.expectRevert(bytes("protocol treasury not set"));
        p.deploy(c);
    }

    /// VerifyRoles refuses a stack whose V4 was (needlessly) made a ledger source.
    function test_verifyRoles_refusesV4AsLedgerSource() public {
        _deployAll();
        new Handoff().handoff(_stack(), admin, deployer);
        vm.prank(admin);
        ledger.setSource(address(v4), true);
        VerifyRoles v = new VerifyRoles();
        RoleTable.Stack memory st = _stack();
        vm.expectRevert(bytes("v4 is a ledger source (it needs no ledger role)"));
        v.verify(st, admin, deployer);
    }

    function test_nanoStack_mainnetRefusesDeployerTreasuryAndFreshLedger() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        _deployAll();
        DeployNanoStack n = new DeployNanoStack();
        DeployNanoStack.Config memory c = _v4Cfg();
        c.treasury = deployer;
        vm.expectRevert(bytes("mainnet: TREASURY must not be the deployer"));
        n.deploy(c);
        c = _v4Cfg();
        c.ledger = address(0);
        vm.expectRevert(bytes("mainnet: NANO_LEDGER must be the shared ledger"));
        n.deploy(c);
        c = _v4Cfg();
        c.disputeResolver = deployer;
        vm.expectRevert(bytes("mainnet: DISPUTE_RESOLVER must not be the deployer"));
        n.deploy(c);
    }

    function test_arbiter_mainnetRefusesDeployerAsProposer() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        _deployAll();
        DeployArbiter a = new DeployArbiter();
        DeployArbiter.Config memory c = _arbiterCfg();
        c.proposer = deployer;
        vm.expectRevert(bytes("mainnet: deployer must not propose/resolve"));
        a.deploy(c);
    }

    function test_oracle_minBondAndPointsSealed() public {
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: address(usdc), minBond: 100e6, points: address(0)})
        );
        assertEq(registry.MIN_BOND(), 100e6);
        assertTrue(registry.pointsSet() && attestation.pointsSet());
        vm.prank(deployer);
        vm.expectRevert(Registry.AlreadyWired.selector);
        registry.setPoints(address(0xBAD));
        vm.prank(deployer);
        vm.expectRevert(Registry.AlreadyWired.selector);
        registry.wire(address(1), address(2));
    }
}
