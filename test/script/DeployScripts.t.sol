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
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {DeployBase} from "../../script/lib/DeployBase.sol";
import {RoleTable} from "../../script/lib/RoleTable.sol";
import {DeployOracle} from "../../script/DeployOracle.s.sol";
import {DeployNanoLedger} from "../../script/DeployNanoLedger.s.sol";
import {DeployPerennial} from "../../script/DeployPerennial.s.sol";
import {DeployBuilders} from "../../script/DeployBuilders.s.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../src/perennial/WonderEscrow.sol";
import {LaunchSchedule} from "../../script/lib/LaunchSchedule.sol";
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
/// against a local chain: (phase 1: DeployBuilders) then DeployOracle ->
/// DeployNanoLedger -> DeployPerennial (season pool + fund + markets) ->
/// DeployNanoStack -> Handoff -> VerifyRoles.
contract DeployScriptsTest is Test {
    MockUSDC usdc;
    address deployer = makeAddr("deployer");
    address admin;
    address agent = makeAddr("agent");
    address disputeResolver = makeAddr("disputeResolver");
    address operator = makeAddr("operator"); // the keeper operator
    address treasury = makeAddr("treasury");
    address protocolTreasury = makeAddr("protocolTreasury");

    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    SeasonPool pool;
    BuilderFund fund;
    MarketsPerennial perennial;
    MarketsV4 v4;

    bytes32 constant DEFAULT_ADMIN = 0x00;
    bytes32 constant GOVERNOR = keccak256("GOVERNOR_ROLE");
    bytes32 constant REGISTRAR = keccak256("REGISTRAR_ROLE");
    bytes32 constant MARKETS = keccak256("MARKETS_ROLE");
    bytes32 constant FUNDER = keccak256("FUNDER_ROLE");
    bytes32 constant NOMINATOR = keccak256("NOMINATOR_ROLE");
    bytes32 constant FEED = keccak256("FEED_ROLE");
    bytes32 constant RELEASER = keccak256("RELEASER_ROLE");
    bytes32 constant YIELD = keccak256("YIELD_ROLE");

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
            (BuilderRegistry b1, CaretakerRegistry c1, VerifiedBuilderBadge v1) =
                new DeployBuilders().deploy(_buildersCfg());
            (pc.builders, pc.caretakers, pc.badge) = (address(b1), address(c1), address(v1));
        }
        _take(new DeployPerennial().deploy(pc));
        (, v4) = new DeployNanoStack().deploy(_v4Cfg());
    }

    function _take(DeployPerennial.Deployed memory d) internal {
        (builders, caretakers, pool, fund, perennial) = (d.builders, d.caretakers, d.seasonPool, d.fund, d.markets);
    }

    function _perennialCfg() internal view returns (DeployPerennial.Config memory c) {
        c.deployer = deployer;
        c.registry = address(registry);
        c.attestation = address(attestation);
        c.ledger = address(ledger);
        c.epochLength = 30 days;
        c.settlementWindow = 24 hours;
        c.resolutionGrace = 7 days;
        c.protocolTreasury = protocolTreasury;
        c.approvedAgent = agent;
        c.disputeResolver = disputeResolver;
        c.operator = operator;
        c.onboarder = onboarder;
        c.wonderExpiry = 180 days;
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
        s.fund = address(fund);
        s.seasonPool = address(pool);
        s.perennial = address(perennial);
        s.v4 = address(v4);
        s.escrow = address(perennial) == address(0) ? address(0) : address(perennial.ESCROW());
    }

    /// Every (contract, role) that exists anywhere in the stack.
    function _allRoles() internal view returns (address[] memory w, bytes32[] memory r) {
        w = new address[](23);
        r = new bytes32[](23);
        address escrow = address(perennial.ESCROW());
        address[8] memory acs = [
            address(ledger), address(builders), address(caretakers), address(fund), address(pool), address(perennial),
            address(v4), escrow
        ];
        uint256 n;
        for (uint256 i; i < 8; i++) {
            w[n] = acs[i];
            r[n++] = DEFAULT_ADMIN;
        }
        (w[n], r[n++]) = (address(ledger), GOVERNOR);
        (w[n], r[n++]) = (address(builders), REGISTRAR);
        (w[n], r[n++]) = (address(caretakers), GOVERNOR);
        (w[n], r[n++]) = (address(fund), GOVERNOR);
        (w[n], r[n++]) = (address(fund), MARKETS);
        (w[n], r[n++]) = (address(pool), GOVERNOR);
        (w[n], r[n++]) = (address(pool), FUNDER);
        (w[n], r[n++]) = (address(perennial), GOVERNOR);
        (w[n], r[n++]) = (address(v4), GOVERNOR);
        (w[n], r[n++]) = (address(perennial), NOMINATOR);
        (w[n], r[n++]) = (address(perennial), FEED);
        (w[n], r[n++]) = (escrow, GOVERNOR);
        (w[n], r[n++]) = (escrow, MARKETS);
        (w[n], r[n++]) = (escrow, RELEASER);
        (w[n], r[n++]) = (escrow, YIELD);
        assertEq(n, 23);
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
        assertTrue(fund.hasRole(DEFAULT_ADMIN, deployer) && pool.hasRole(DEFAULT_ADMIN, deployer));
        assertFalse(ledger.isSource(address(v4)), "V4 needs no ledger role");
        assertEq(address(perennial.FUND()), address(fund));
        assertEq(address(fund.SEASON_POOL()), address(pool));
        assertEq(fund.PROTOCOL_TREASURY(), protocolTreasury);
        assertEq(fund.EPOCH_LENGTH(), 30 days);
        assertEq(fund.START(), block.timestamp);
        assertEq(fund.scheduleFor(0).length, 4, "launch schedule");
        assertEq(fund.progressiveTax(60_000e6, fund.scheduleFor(0)), 11_900e6);
        assertEq(v4.TREASURY(), treasury);
        assertTrue(perennial.approvedAgent(agent));
        assertTrue(perennial.approvedResolver(disputeResolver));
        assertTrue(v4.approvedResolver(disputeResolver));
        assertTrue(perennial.isApprovedFeed(bytes32(0), agent) == false);

        new Handoff().handoff(_stack(), admin, deployer);

        _assertDeployerHoldsNothing();
        assertFalse(fund.hasRole(DEFAULT_ADMIN, deployer), "deployer lacks DEFAULT_ADMIN after Handoff");
        assertTrue(fund.hasRole(DEFAULT_ADMIN, admin) && fund.hasRole(GOVERNOR, admin));
        assertTrue(pool.hasRole(DEFAULT_ADMIN, admin) && pool.hasRole(GOVERNOR, admin));
        assertTrue(v4.hasRole(GOVERNOR, admin));
        assertTrue(builders.hasRole(REGISTRAR, admin));
        assertTrue(fund.hasRole(MARKETS, address(perennial)));
        assertTrue(pool.hasRole(FUNDER, address(fund)));
        assertFalse(fund.hasRole(MARKETS, admin) || pool.hasRole(FUNDER, admin));
        new VerifyRoles().verify(_stack(), admin, deployer);
    }

    // ───────────── phase 1: builders before markets ─────────────

    address onboarder = makeAddr("onboarder");

    function _buildersCfg() internal view returns (DeployBuilders.Config memory c) {
        c.deployer = deployer;
        c.admin = admin;
        c.operator = operator; // the keeper operator
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
        assertTrue(badge.hasRole(badge.STATUS_ROLE(), operator) && !badge.hasRole(badge.ISSUER_ROLE(), operator));

        // the gallery's life before any market: claim, then the ONBOARDER (hot
        // wallet) onboards without the Safe
        address alice = makeAddr("alice");
        vm.prank(alice);
        (uint256 id,) = builders.registerBuilderWithProject("", "github:alice/app");
        vm.startPrank(onboarder);
        caretakers.setCaretaker(id, operator);
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
        pc.badge = address(badge);
        DeployPerennial.Deployed memory d = new DeployPerennial().deploy(pc);
        (pool, fund, perennial) = (d.seasonPool, d.fund, d.markets);
        assertEq(address(d.builders), address(builders), "registry reused");
        assertEq(address(d.caretakers), address(caretakers), "caretakers reused");
        assertEq(address(fund.BUILDERS()), address(builders));
        assertEq(address(fund.CARETAKERS()), address(caretakers));
        assertEq(address(pool.BUILDERS()), address(builders));
        assertEq(address(pool.CARETAKERS()), address(caretakers));
        assertEq(address(perennial.BUILDERS()), address(builders));
        (, v4) = new DeployNanoStack().deploy(_v4Cfg());
        new Handoff().handoff(_stack(), admin, deployer);
        _assertDeployerHoldsNothing();
        new VerifyRoles().verify(_stack(), admin, deployer);
        // audit M-1 revisited: with no arbiter, setCaretaker moves no money, so
        // the hot wallet may keep onboarding after markets launch, on mainnet too.
        assertTrue(caretakers.hasRole(GOVERNOR, onboarder));
        new OnboarderCheck().check(_stack(), onboarder);

        // everything done in phase 1 carried over
        assertEq(builders.builderIdOf(alice), id);
        assertTrue(caretakers.isCaretaker(id, operator));
        assertEq(badge.ownerOf(serial), alice);
    }

    /// Phase 2 deploys the WonderEscrow and wires it: the markets credit it, it
    /// credits the fund, the operator binds feeds and runs releases and yield,
    /// the onboarder nominates; the deployer keeps none of the operator roles
    /// through Handoff, and the Safe ends with NOMINATOR, FEED and the escrow's
    /// GOVERNOR.
    function test_deployPerennial_wiresWonderEscrow() public {
        _deployAll();
        WonderEscrow escrow = perennial.ESCROW();
        assertEq(address(escrow.FUND()), address(fund));
        assertEq(address(escrow.BADGE()), address(perennial.BADGE()));
        assertEq(escrow.EXPIRY(), 180 days);
        assertTrue(escrow.hasRole(MARKETS, address(perennial)));
        assertTrue(fund.hasRole(MARKETS, address(escrow)));
        assertTrue(escrow.hasRole(RELEASER, operator) && escrow.hasRole(YIELD, operator));
        assertTrue(perennial.hasRole(FEED, operator));
        assertTrue(perennial.hasRole(NOMINATOR, onboarder));
        new Handoff().handoff(_stack(), admin, deployer);
        _assertDeployerHoldsNothing();
        assertTrue(perennial.hasRole(NOMINATOR, admin) && perennial.hasRole(FEED, admin));
        assertTrue(escrow.hasRole(GOVERNOR, admin) && escrow.hasRole(DEFAULT_ADMIN, admin));
        assertTrue(perennial.hasRole(FEED, operator), "operator keeps FEED");
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
        (uint256 id,) = b.registerBuilderWithProject("", "domain:bob.xyz");
        vm.startPrank(onboarder);
        ct.setCaretaker(id, operator);
        badge.issue(id);
        vm.expectRevert();
        badge.revoke(id); // REVOKER stays with the Safe (audit L-3)
        vm.expectRevert();
        b.setActive(id, false); // REGISTRAR stays with the Safe
        vm.expectRevert();
        b.registerFor(makeAddr("squat"), "registrai:github:x/y");
        vm.expectRevert();
        b.addProjectFor(id, "github:x/y"); // REGISTRAR: projects on a builder's behalf
        vm.expectRevert();
        b.startRecovery(id, makeAddr("squat")); // REGISTRAR: recovery is Safe-only
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
        c.onboarder = operator;
        vm.expectRevert(bytes("ONBOARDER must differ from ADMIN, OPERATOR and the deployer"));
        d.deploy(c);
        c.onboarder = deployer;
        vm.expectRevert(bytes("ONBOARDER must differ from ADMIN, OPERATOR and the deployer"));
        d.deploy(c);
    }

    /// Phase 2 guard: an onboarder holding any market/admin role fails VerifyRoles.
    function test_phase2_verifyRolesRefusesOnboarderWithMarketRole() public {
        _phase1ThenMarkets();
        OnboarderCheck chk = new OnboarderCheck();
        RoleTable.Stack memory st = _stack();
        vm.prank(admin);
        pool.grantRole(GOVERNOR, onboarder);
        vm.expectRevert(bytes("ONBOARDER holds SeasonPool GOVERNOR"));
        chk.check(st, onboarder);
        vm.startPrank(admin);
        pool.revokeRole(GOVERNOR, onboarder);
        fund.grantRole(DEFAULT_ADMIN, onboarder);
        vm.stopPrank();
        vm.expectRevert(bytes("ONBOARDER holds BuilderFund DEFAULT_ADMIN"));
        chk.check(st, onboarder);
        vm.startPrank(admin);
        fund.revokeRole(DEFAULT_ADMIN, onboarder);
        fund.grantRole(MARKETS, onboarder);
        vm.stopPrank();
        vm.expectRevert(bytes("ONBOARDER holds BuilderFund MARKETS"));
        chk.check(st, onboarder);
        vm.startPrank(admin);
        fund.revokeRole(MARKETS, onboarder);
        pool.grantRole(FUNDER, onboarder);
        vm.stopPrank();
        vm.expectRevert(bytes("ONBOARDER holds SeasonPool FUNDER"));
        chk.check(st, onboarder);
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
        DeployPerennial.Deployed memory d = p.deploy(pc);
        assertEq(address(d.builders), address(b1));
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
        RoleTable.Stack memory st = _stack();
        vm.expectRevert();
        v.verify(st, admin, deployer);
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

    /// Off mainnet OPERATOR and ONBOARDER default to the deployer: the handoff
    /// must still go through (the deployer keeps its operator roles there).
    function test_handoff_testnet_operatorIsTheDeployer() public {
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 10e6, points: address(0)})
        );
        ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
        DeployPerennial.Config memory pc = _perennialCfg();
        (pc.operator, pc.onboarder) = (deployer, deployer);
        _take(new DeployPerennial().deploy(pc));
        (, v4) = new DeployNanoStack().deploy(_v4Cfg());
        new Handoff().handoff(_stack(), admin, deployer);
        assertTrue(perennial.hasRole(FEED, admin) && perennial.hasRole(NOMINATOR, admin));
        assertFalse(perennial.hasRole(DEFAULT_ADMIN, deployer) || perennial.ESCROW().hasRole(GOVERNOR, deployer));
    }

    // ───────────── regression ports (PoC) ─────────────

    /// PoC test_deployerAdminDrainsCommons, ported to the fund: the deployer
    /// kept DEFAULT_ADMIN, re-granted itself the income-writer role and drained
    /// the builders' money. After Handoff every step of that attack reverts.
    function test_regression_deployerCannotDrainFundAfterHandoff() public {
        _deployAll();
        new Handoff().handoff(_stack(), admin, deployer);
        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN)
        );
        fund.grantRole(MARKETS, deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, REGISTRAR)
        );
        builders.registerFor(address(0xD3AD), "me");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, MARKETS)
        );
        fund.credit(1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, GOVERNOR)
        );
        fund.setSchedule(LaunchSchedule.brackets());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, GOVERNOR)
        );
        fund.sweepFrozen(0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, GOVERNOR)
        );
        ledger.skimSurplus(deployer);
        vm.stopPrank();
    }

    /// Nor can it touch the season pool: no funder, no seasons, no caretakers.
    /// ADMIN (the Safe) keeps those powers.
    function test_regression_deployerCannotTouchSeasonPoolAfterHandoff() public {
        _deployAll();
        new Handoff().handoff(_stack(), admin, deployer);
        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN)
        );
        pool.grantRole(FUNDER, deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, FUNDER)
        );
        pool.fund(1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, GOVERNOR)
        );
        pool.publishSeason(1, bytes32(uint256(1)), 1, uint64(block.timestamp + 1));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, GOVERNOR)
        );
        caretakers.setCaretaker(1, deployer);
        vm.stopPrank();
        vm.prank(admin);
        fund.setSchedule(LaunchSchedule.brackets());
        assertEq(fund.scheduleCount(), 2);
    }

    // ───────────── negative wiring (VerifyRoles) ─────────────

    function _handedOff() internal returns (VerifyRoles v, RoleTable.Stack memory st) {
        _deployAll();
        new Handoff().handoff(_stack(), admin, deployer);
        v = new VerifyRoles();
        st = _stack();
    }

    function test_verifyRoles_refusesMarketsWithoutFundRole() public {
        (VerifyRoles v, RoleTable.Stack memory st) = _handedOff();
        vm.prank(admin);
        fund.revokeRole(MARKETS, address(perennial));
        vm.expectRevert(bytes("markets lack BuilderFund MARKETS"));
        v.verify(st, admin, deployer);
    }

    function test_verifyRoles_refusesAdminAsIncomeWriterOrFunder() public {
        (VerifyRoles v, RoleTable.Stack memory st) = _handedOff();
        vm.prank(admin);
        fund.grantRole(MARKETS, admin);
        vm.expectRevert(bytes("ADMIN holds BuilderFund MARKETS (income is credited by the markets only)"));
        v.verify(st, admin, deployer);
        vm.startPrank(admin);
        fund.revokeRole(MARKETS, admin);
        pool.grantRole(FUNDER, admin);
        vm.stopPrank();
        vm.expectRevert(bytes("ADMIN holds SeasonPool FUNDER (the pool is funded by the fund only)"));
        v.verify(st, admin, deployer);
    }

    function test_verifyRoles_refusesFundWithoutFunderRole() public {
        (VerifyRoles v, RoleTable.Stack memory st) = _handedOff();
        vm.prank(admin);
        pool.revokeRole(FUNDER, address(fund));
        vm.expectRevert(bytes("fund lacks SeasonPool FUNDER"));
        v.verify(st, admin, deployer);
    }

    /// A stack naming another fund or season pool than the markets / fund use.
    function test_verifyRoles_refusesMiswiredFundOrPool() public {
        (VerifyRoles v, RoleTable.Stack memory st) = _handedOff();
        // a second, correctly-roled pool the fund does not pay into
        SeasonPool other = new SeasonPool(ledger, builders, caretakers, admin);
        vm.startPrank(admin);
        other.grantRole(FUNDER, address(fund));
        vm.stopPrank();
        RoleTable.Stack memory bad = st;
        bad.seasonPool = address(other);
        vm.expectRevert(bytes("fund season pool"));
        v.verify(bad, admin, deployer);

        // a second fund the markets do not credit
        BuilderFund otherFund =
            new BuilderFund(ledger, builders, caretakers, pool, protocolTreasury, admin, 30 days, LaunchSchedule.brackets());
        vm.startPrank(admin);
        otherFund.grantRole(MARKETS, address(perennial));
        otherFund.grantRole(MARKETS, address(perennial.ESCROW()));
        pool.grantRole(FUNDER, address(otherFund));
        vm.stopPrank();
        bad = _stack();
        bad.fund = address(otherFund);
        vm.expectRevert(bytes("perennial fund"));
        v.verify(bad, admin, deployer);
    }

    function test_verifyRoles_refusesFundOnOtherBuilders() public {
        (VerifyRoles v, RoleTable.Stack memory st) = _handedOff();
        RoleTable.Stack memory bad = st;
        bad.builders = address(new BuilderRegistry(admin));
        vm.expectRevert(bytes("fund builders"));
        v.verify(bad, admin, deployer);
    }

    /// Mainnet: the fund's protocol treasury must not be the deployer.
    function test_verifyRoles_mainnetRefusesDeployerProtocolTreasury() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        _deployAll();
        // hand-built fund paying the deployer (the script refuses this on mainnet)
        vm.startPrank(deployer);
        pool = new SeasonPool(ledger, builders, caretakers, deployer);
        fund = new BuilderFund(ledger, builders, caretakers, pool, deployer, deployer, 30 days, LaunchSchedule.brackets());
        VerifiedBuilderBadge bdg = new VerifiedBuilderBadge(builders, deployer, deployer, "t", "", "");
        WonderEscrow escrow = new WonderEscrow(ledger, fund, bdg, deployer, 180 days);
        perennial =
            new MarketsPerennial(ledger, registry, attestation, builders, deployer, fund, 24 hours, 7 days, bdg, escrow);
        escrow.grantRole(escrow.MARKETS_ROLE(), address(perennial));
        fund.grantRole(MARKETS, address(perennial));
        fund.grantRole(MARKETS, address(escrow));
        pool.grantRole(FUNDER, address(fund));
        vm.stopPrank();
        Handoff h = new Handoff();
        RoleTable.Stack memory st = _stack();
        vm.expectRevert(bytes("deployer is the protocol treasury"));
        h.handoff(st, admin, deployer);
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

    /// EPOCH_LENGTH = 0 is refused on every chain (time-based epochs need a length).
    function test_perennial_requiresPositiveEpoch() public {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 10e6, points: address(0)})
        );
        ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
        DeployPerennial p = new DeployPerennial();
        DeployPerennial.Config memory c = _perennialCfg();
        c.epochLength = 0;
        vm.expectRevert(bytes("EPOCH_LENGTH must be > 0"));
        p.deploy(c);
        c.epochLength = 30 days;
        c.disputeResolver = deployer;
        vm.expectRevert(bytes("mainnet: DISPUTE_RESOLVER must not be the deployer"));
        p.deploy(c);
        // testnet refuses 0 as well; a short epoch is fine
        vm.chainId(5042002);
        c = _perennialCfg();
        c.epochLength = 0;
        vm.expectRevert(bytes("EPOCH_LENGTH must be > 0"));
        p.deploy(c);
        c.epochLength = 1 hours;
        DeployPerennial.Deployed memory d = p.deploy(c);
        assertEq(d.fund.EPOCH_LENGTH(), 1 hours);
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
