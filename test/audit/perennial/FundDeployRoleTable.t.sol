// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {Registry} from "../../../src/Registry.sol";
import {Attestation} from "../../../src/Attestation.sol";
import {Dispute} from "../../../src/Dispute.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../../../src/nanopay/MarketsV4.sol";
import {MarketsPerennial} from "../../../src/nanopay/MarketsPerennial.sol";
import {RegiFeeSplitter} from "../../../src/buyback/RegiFeeSplitter.sol";
import {INanoLedgerMinimal} from "../../../src/buyback/INanoLedgerMinimal.sol";
import {BuilderRegistry} from "../../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../../../src/perennial/VerifiedBuilderBadge.sol";
import {BuilderFund} from "../../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../../src/perennial/SeasonPool.sol";
import {WonderEscrow} from "../../../src/perennial/WonderEscrow.sol";
import {DeployOracle} from "../../../script/DeployOracle.s.sol";
import {DeployNanoStack} from "../../../script/DeployNanoStack.s.sol";
import {DeployBuilders} from "../../../script/DeployBuilders.s.sol";
import {DeployPerennial} from "../../../script/DeployPerennial.s.sol";
import {Handoff} from "../../../script/Handoff.s.sol";
import {HandoffCommonMarkets} from "../../../script/HandoffCommonMarkets.s.sol";
import {RoleTable} from "../../../script/lib/RoleTable.sol";
import {VerifyRoles} from "../../../script/VerifyRoles.s.sol";

contract FundSafeStub {}

/// A look-alike CaretakerRegistry: passes every deploy/handoff check that reads
/// it (BUILDERS(), hasRole) and routes every payout to `thief`.
contract FakeCaretakers {
    address public immutable BUILDERS;
    address public immutable thief;
    address public immutable safe;

    constructor(address b, address t, address s) {
        (BUILDERS, thief, safe) = (b, t, s);
    }

    function payoutOf(uint256) external view returns (address) {
        return thief;
    }

    function hasRole(bytes32, address who) external view returns (bool) {
        return who == safe;
    }

    function grantRole(bytes32, address) external {}
    function renounceRole(bytes32, address) external {}
}

/// Runs the real phase-1 + oracle + V4 + phase-2 (DeployPerennial) + Handoff
/// scripts locally on chainid 5042 (no fork), recording every log, and rebuilds
/// the FINAL role table of every AccessControl contract from RoleGranted /
/// RoleRevoked events (AccessControl is not enumerable).
contract FundDeployRoleTableTest is Test {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    bytes32 constant DA = 0x00;
    bytes32 constant GOVERNOR = keccak256("GOVERNOR_ROLE");
    bytes32 constant REGISTRAR = keccak256("REGISTRAR_ROLE");
    bytes32 constant MARKETS = keccak256("MARKETS_ROLE");
    bytes32 constant FUNDER = keccak256("FUNDER_ROLE");
    bytes32 constant NOMINATOR = keccak256("NOMINATOR_ROLE");
    bytes32 constant FEED = keccak256("FEED_ROLE");
    bytes32 constant RELEASER = keccak256("RELEASER_ROLE");
    bytes32 constant LATE = keccak256("LATE_ROLE");
    bytes32 constant ISSUER = keccak256("ISSUER_ROLE");
    bytes32 constant REVOKER = keccak256("REVOKER_ROLE");
    bytes32 constant STATUS = keccak256("STATUS_ROLE");

    address deployer = makeAddr("deployer");
    address agent = makeAddr("agent");
    address operator = makeAddr("operator");
    address onboarder = makeAddr("onboarder");
    address safe;
    RegiFeeSplitter splitter;
    NanoLedger ledger;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    MarketsV4 v4;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    VerifiedBuilderBadge badge;
    DeployPerennial.Deployed d;

    Vm.Log[] recorded;

    function setUp() public {
        vm.warp(1_790_000_000);
        vm.chainId(5042);
        MockUSDC m = new MockUSDC();
        vm.etch(ARC_USDC, address(m).code);
        safe = address(new FundSafeStub());
        // live on mainnet already: the Safe-owned ledger and the splitter bound to it
        ledger = new NanoLedger(IERC20(ARC_USDC), safe);
        splitter = new RegiFeeSplitter(INanoLedgerMinimal(address(ledger)), IERC20(ARC_USDC), safe, makeAddr("buyback"));
    }

    function _phase1() internal {
        (builders, caretakers, badge) = new DeployBuilders().deploy(
            DeployBuilders.Config({
                deployer: deployer,
                admin: safe,
                operator: operator,
                onboarder: onboarder,
                chainLabel: "Arc Mainnet",
                imageBase: "https://registrai.cc/badge/arc/",
                externalBase: "https://registrai.cc/builders/?builder="
            })
        );
    }

    function _oracleAndV4() internal {
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: ARC_USDC, minBond: 2e6, points: address(0)})
        );
        (, v4) = new DeployNanoStack().deploy(
            DeployNanoStack.Config({
                deployer: deployer,
                usdc: ARC_USDC,
                registry: address(registry),
                attestation: address(attestation),
                ledger: address(ledger),
                treasury: address(splitter),
                settlementWindow: 1 hours,
                resolutionGrace: 7 days,
                disputeResolver: safe,
                approvedAgent: agent
            })
        );
    }

    function _cfg() internal view returns (DeployPerennial.Config memory c) {
        c.deployer = deployer;
        c.registry = address(registry);
        c.attestation = address(attestation);
        c.ledger = address(ledger);
        c.epochLength = 30 days;
        c.settlementWindow = 24 hours;
        c.resolutionGrace = 7 days;
        c.protocolTreasury = address(splitter);
        c.approvedAgent = agent;
        c.disputeResolver = safe;
        c.builders = address(builders);
        c.caretakers = address(caretakers);
        c.badge = address(badge);
        c.wonderExpiry = 180 days;
        c.operator = operator;
        c.onboarder = onboarder;
    }

    function _phase2() internal {
        d = new DeployPerennial().deploy(_cfg());
    }

    function _stack() internal view returns (RoleTable.Stack memory s) {
        s.registry = address(registry);
        s.attestation = address(attestation);
        s.ledger = address(ledger);
        s.builders = address(builders);
        s.caretakers = address(caretakers);
        s.fund = address(d.fund);
        s.seasonPool = address(d.seasonPool);
        s.perennial = address(d.markets);
        s.v4 = address(v4);
        s.escrow = address(d.escrow);
    }

    function _handoff() internal {
        new Handoff().handoff(_stack(), safe, deployer);
    }

    // ─────────────────────────── log-derived role table ───────────────────────────

    function _holders(address where, bytes32 role) internal view returns (address[] memory out) {
        bytes32 granted = keccak256("RoleGranted(bytes32,address,address)");
        bytes32 revoked = keccak256("RoleRevoked(bytes32,address,address)");
        address[] memory seen = new address[](recorded.length);
        uint256 n;
        for (uint256 i; i < recorded.length; i++) {
            Vm.Log memory l = recorded[i];
            if (l.emitter != where || l.topics.length < 3 || l.topics[1] != role) continue;
            if (l.topics[0] != granted && l.topics[0] != revoked) continue;
            address acct = address(uint160(uint256(l.topics[2])));
            bool dup;
            for (uint256 j; j < n; j++) if (seen[j] == acct) dup = true;
            if (!dup) seen[n++] = acct;
        }
        uint256 k;
        out = new address[](n);
        for (uint256 j; j < n; j++) if (IAccessControl(where).hasRole(role, seen[j])) out[k++] = seen[j];
        assembly {
            mstore(out, k)
        }
    }

    /// Every role id ever granted on `where` must be one of `known`.
    function _onlyKnownRoles(address where, bytes32[] memory known, string memory what) internal view {
        bytes32 granted = keccak256("RoleGranted(bytes32,address,address)");
        for (uint256 i; i < recorded.length; i++) {
            Vm.Log memory l = recorded[i];
            if (l.emitter != where || l.topics[0] != granted) continue;
            bool k;
            for (uint256 j; j < known.length; j++) if (known[j] == l.topics[1]) k = true;
            require(k, string.concat(what, ": unexpected role granted"));
        }
        for (uint256 j; j < known.length; j++) {
            assertEq(IAccessControl(where).getRoleAdmin(known[j]), DA, string.concat(what, ": role admin != DEFAULT_ADMIN"));
        }
    }

    function _set(address[] memory got, address[] memory want, string memory what) internal pure {
        require(got.length == want.length, string.concat(what, ": holder count"));
        for (uint256 i; i < want.length; i++) {
            bool f;
            for (uint256 j; j < got.length; j++) if (got[j] == want[i]) f = true;
            require(f, string.concat(what, ": missing expected holder"));
        }
    }

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _a(address x, address y) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (x, y);
    }

    function _r(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](2);
        (r[0], r[1]) = (a, b);
    }

    function _r(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _r(bytes32 a, bytes32 b, bytes32 c, bytes32 e) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, e);
    }

    function _r5(bytes32 a, bytes32 b, bytes32 c, bytes32 e, bytes32 f) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, e, f);
    }

    function _record() internal {
        Vm.Log[] memory l = vm.getRecordedLogs();
        for (uint256 i; i < l.length; i++) recorded.push(l[i]);
    }

    // ─────────────────────────── the table ───────────────────────────

    function test_fullStack_phase1_oracle_v4_perennial_handoff_exactRoleTable() public {
        vm.recordLogs();
        _phase1();
        _oracleAndV4();
        _phase2();
        _handoff();
        _record();

        address fund = address(d.fund);
        address pool = address(d.seasonPool);
        address per = address(d.markets);
        address esc = address(d.escrow);

        // phase-1 registries (reused)
        assertEq(address(d.builders), address(builders));
        assertEq(address(d.caretakers), address(caretakers));
        assertEq(address(d.badge), address(badge));
        _onlyKnownRoles(address(builders), _r(DA, REGISTRAR), "builders");
        _set(_holders(address(builders), DA), _a(safe), "builders DA");
        _set(_holders(address(builders), REGISTRAR), _a(safe), "builders REGISTRAR");
        _onlyKnownRoles(address(caretakers), _r(DA, GOVERNOR), "caretakers");
        _set(_holders(address(caretakers), DA), _a(safe), "caretakers DA");
        _set(_holders(address(caretakers), GOVERNOR), _a(safe, onboarder), "caretakers GOVERNOR");
        _onlyKnownRoles(address(badge), _r(DA, ISSUER, REVOKER, STATUS), "badge");
        _set(_holders(address(badge), DA), _a(safe), "badge DA");
        _set(_holders(address(badge), ISSUER), _a(safe, onboarder), "badge ISSUER");
        _set(_holders(address(badge), REVOKER), _a(safe), "badge REVOKER");
        _set(_holders(address(badge), STATUS), _a(operator), "badge STATUS");

        // phase 2: the money contracts
        _onlyKnownRoles(fund, _r(DA, GOVERNOR, MARKETS, LATE), "fund");
        _set(_holders(fund, DA), _a(safe), "fund DA");
        _set(_holders(fund, GOVERNOR), _a(safe), "fund GOVERNOR");
        _set(_holders(fund, MARKETS), _a(per, esc), "fund MARKETS");
        _set(_holders(fund, LATE), _a(esc), "fund LATE");
        _onlyKnownRoles(pool, _r(DA, GOVERNOR, FUNDER), "pool");
        _set(_holders(pool, DA), _a(safe), "pool DA");
        _set(_holders(pool, GOVERNOR), _a(safe), "pool GOVERNOR");
        _set(_holders(pool, FUNDER), _a(fund), "pool FUNDER");
        _onlyKnownRoles(per, _r(DA, GOVERNOR, FEED, NOMINATOR), "perennial");
        _set(_holders(per, DA), _a(safe), "perennial DA");
        _set(_holders(per, GOVERNOR), _a(safe), "perennial GOVERNOR");
        _set(_holders(per, FEED), _a(safe, operator), "perennial FEED");
        _set(_holders(per, NOMINATOR), _a(safe, onboarder), "perennial NOMINATOR");
        _onlyKnownRoles(esc, _r(DA, GOVERNOR, MARKETS, RELEASER), "escrow");
        _set(_holders(esc, DA), _a(safe), "escrow DA");
        _set(_holders(esc, GOVERNOR), _a(safe), "escrow GOVERNOR");
        _set(_holders(esc, MARKETS), _a(per), "escrow MARKETS");
        _set(_holders(esc, RELEASER), _a(operator), "escrow RELEASER");

        // common markets + ledger
        _onlyKnownRoles(address(v4), _r(DA, GOVERNOR), "v4");
        _set(_holders(address(v4), DA), _a(safe), "v4 DA");
        _set(_holders(address(v4), GOVERNOR), _a(safe), "v4 GOVERNOR");
        assertEq(_holders(address(ledger), DA).length, 0, "no ledger admin granted during launch");
        assertEq(_holders(address(ledger), GOVERNOR).length, 0, "no ledger governor granted during launch");
        assertTrue(ledger.hasRole(DA, safe) && ledger.hasRole(GOVERNOR, safe));

        // the deployer holds nothing anywhere
        address[9] memory acs = [address(builders), address(caretakers), address(badge), fund, pool, per, esc, address(v4), address(ledger)];
        bytes32[12] memory all = [DA, GOVERNOR, REGISTRAR, MARKETS, FUNDER, NOMINATOR, FEED, RELEASER, LATE, ISSUER, REVOKER, STATUS];
        for (uint256 i; i < acs.length; i++) {
            for (uint256 j; j < all.length; j++) {
                assertFalse(IAccessControl(acs[i]).hasRole(all[j], deployer), "deployer holds a role");
            }
        }

        // the script-side exact check (VerifyRoles) agrees: no stray holder anywhere
        new VerifyRoles().verifyExact(_stack(), safe, operator, onboarder, recorded);

        // allowlists + immutables of the money path
        assertTrue(d.markets.approvedAgent(agent) && !d.markets.approvedAgent(deployer));
        assertTrue(d.markets.approvedResolver(safe) && !d.markets.approvedResolver(deployer));
        assertEq(d.fund.PROTOCOL_TREASURY(), address(splitter));
        assertEq(address(d.fund.SEASON_POOL()), pool);
        assertEq(d.fund.EPOCH_LENGTH(), 30 days);
        assertEq(d.fund.scheduleCount(), 1);
        assertEq(d.fund.scheduleFor(0)[3].rateBps, 3000);
        assertEq(address(d.markets.FUND()), fund);
        assertEq(address(d.escrow.FUND()), fund);
        assertEq(d.escrow.EXPIRY(), 180 days);
        assertFalse(ledger.isSource(per) || ledger.isSource(fund) || ledger.isSource(pool));

        // deployer powers are gone
        vm.startPrank(deployer);
        vm.expectRevert();
        d.fund.grantRole(MARKETS, deployer);
        vm.expectRevert();
        d.seasonPool.publishSeason(1, bytes32(uint256(1)), 1, uint64(block.timestamp + 1));
        vm.expectRevert();
        d.fund.sweepFrozen(0, 1);
        vm.expectRevert();
        builders.setActive(1, false);
        vm.stopPrank();
    }

    /// The common markets may already be handed off (HandoffCommonMarkets) when
    /// phase 2 runs; the full-stack Handoff must still pass and leave the same table.
    function test_commonMarketsHandedOffFirst_thenPerennialHandoff() public {
        vm.recordLogs();
        _phase1();
        _oracleAndV4();
        new HandoffCommonMarkets().handoff(
            HandoffCommonMarkets.Common(address(registry), address(attestation), address(ledger), address(v4)), safe, deployer
        );
        _phase2();
        _handoff();
        _record();
        _set(_holders(address(d.fund), DA), _a(safe), "fund DA");
        _set(_holders(address(d.fund), GOVERNOR), _a(safe), "fund GOVERNOR");
        _set(_holders(address(d.fund), MARKETS), _a(address(d.markets), address(d.escrow)), "fund MARKETS");
        _set(_holders(address(d.seasonPool), GOVERNOR), _a(safe), "pool GOVERNOR");
        _set(_holders(address(d.seasonPool), FUNDER), _a(address(d.fund)), "pool FUNDER");
        _set(_holders(address(v4), DA), _a(safe), "v4 DA");
        assertFalse(d.fund.hasRole(DA, deployer) || d.seasonPool.hasRole(DA, deployer) || v4.hasRole(DA, deployer));
    }

    // ─────────────────────────── findings ───────────────────────────

    /// FIXED L-2: a stray grant between DeployPerennial and Handoff (compromised
    /// key, mistaken script) still passes Handoff's "ADMIN has all, deployer none",
    /// but the exact check over every RoleGranted log (VerifyRoles.verifyExact,
    /// run after Handoff) names it, on each contract of the Perennial stack.
    function test_FIXED_L2_strayGrantFailsTheExactRoleCheck() public {
        vm.recordLogs();
        _phase1();
        _oracleAndV4();
        _phase2();
        address hot = makeAddr("strayHotKey");
        vm.prank(deployer);
        d.seasonPool.grantRole(GOVERNOR, hot);
        _handoff();
        _record();
        VerifyRoles v = new VerifyRoles();
        vm.expectRevert(bytes("stray role holder: SeasonPool GOVERNOR"));
        v.verifyExact(_stack(), safe, operator, onboarder, recorded);
    }

    function test_FIXED_L2_strayFundAdminFailsTheExactRoleCheck() public {
        vm.recordLogs();
        _phase1();
        _oracleAndV4();
        _phase2();
        address hot = makeAddr("strayHotKey");
        vm.prank(deployer);
        d.fund.grantRole(DA, hot);
        _handoff();
        _record();
        VerifyRoles v = new VerifyRoles();
        vm.expectRevert(bytes("stray role holder: BuilderFund DEFAULT_ADMIN"));
        v.verifyExact(_stack(), safe, operator, onboarder, recorded);
    }

    /// FIXED L-3: on mainnet the (immutable) epoch is exactly 30 days and the
    /// (immutable) protocol treasury is a contract on this NanoLedger (the fee
    /// splitter): no ten-year epoch, no EOA or other-ledger treasury.
    function test_FIXED_L3_mainnetRequires30DayEpochAndALedgerTreasury() public {
        _phase1();
        _oracleAndV4();
        DeployPerennial script = new DeployPerennial();
        DeployPerennial.Config memory c = _cfg();
        c.epochLength = 3650 days;
        vm.expectRevert(bytes("mainnet: EPOCH_LENGTH must be 30 days"));
        script.deploy(c);
        c.epochLength = 29 days;
        vm.expectRevert(bytes("mainnet: EPOCH_LENGTH must be 30 days"));
        script.deploy(c);
        c.epochLength = 30 days;
        string memory treasuryErr = "mainnet: PROTOCOL_TREASURY must be a contract on this NanoLedger (the fee splitter)";
        c.protocolTreasury = makeAddr("someEOA");
        vm.expectRevert(bytes(treasuryErr));
        script.deploy(c);
        c.protocolTreasury = address(new FundSafeStub()); // a contract with no LEDGER()
        vm.expectRevert(bytes(treasuryErr));
        script.deploy(c);
        NanoLedger other = new NanoLedger(IERC20(ARC_USDC), safe);
        c.protocolTreasury = address(new RegiFeeSplitter(INanoLedgerMinimal(address(other)), IERC20(ARC_USDC), safe, makeAddr("bb")));
        vm.expectRevert(bytes(treasuryErr));
        script.deploy(c);
        c.protocolTreasury = address(splitter);
        d = script.deploy(c);
        assertEq(d.fund.EPOCH_LENGTH(), 30 days);
        assertEq(d.fund.PROTOCOL_TREASURY(), address(splitter));
    }

    /// FIXED L-4: the CaretakerRegistry is pinned by code (a local copy over the
    /// same BuilderRegistry must have identical runtime code): a look-alike that
    /// routes payouts elsewhere is refused before anything is deployed.
    function test_FIXED_L4_lookalikeCaretakerRegistryRefused() public {
        _phase1();
        _oracleAndV4();
        FakeCaretakers fake = new FakeCaretakers(address(builders), makeAddr("thief"), safe);
        DeployPerennial.Config memory c = _cfg();
        c.caretakers = address(fake);
        DeployPerennial script = new DeployPerennial();
        vm.expectRevert(bytes("CARETAKER_REGISTRY is not this CaretakerRegistry"));
        script.deploy(c);
    }

    /// FIXED L-4: on Arc mainnet the phase-1 contracts are pinned to their live
    /// addresses; env pointing anywhere else (a stale testnet address, a poisoned
    /// runbook) is refused. (Enforced where the live contracts have code, i.e. on
    /// Arc mainnet and its forks; this local chain gets their code etched.)
    function test_FIXED_L4_mainnetPinsThePhase1Addresses() public {
        _phase1();
        _oracleAndV4();
        DeployPerennial script = new DeployPerennial();
        vm.etch(script.MAINNET_BUILDER_REGISTRY(), address(builders).code);
        vm.etch(script.MAINNET_CARETAKER_REGISTRY(), address(caretakers).code);
        vm.etch(script.MAINNET_VERIFIED_BADGE(), address(badge).code);
        DeployPerennial.Config memory c = _cfg(); // the local copies, not the live ones
        vm.expectRevert(bytes("mainnet: BUILDER_REGISTRY is not the live phase-1 BuilderRegistry"));
        script.deploy(c);
        c.builders = script.MAINNET_BUILDER_REGISTRY();
        vm.expectRevert(bytes("mainnet: CARETAKER_REGISTRY is not the live phase-1 CaretakerRegistry"));
        script.deploy(c);
    }

    // merkle helpers (OZ sorted pairs)
    function _hp(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _up(bytes32[] memory l) internal pure returns (bytes32[] memory n) {
        n = new bytes32[]((l.length + 1) / 2);
        for (uint256 i; i < n.length; i++) {
            n[i] = 2 * i + 1 < l.length ? _hp(l[2 * i], l[2 * i + 1]) : l[2 * i];
        }
    }

    function _root(bytes32[] memory l) internal pure returns (bytes32) {
        while (l.length > 1) l = _up(l);
        return l[0];
    }

    function _proof(bytes32[] memory l, uint256 idx) internal pure returns (bytes32[] memory p) {
        bytes32[] memory buf = new bytes32[](16);
        uint256 n;
        while (l.length > 1) {
            uint256 sib = idx ^ 1;
            if (sib < l.length) buf[n++] = l[sib];
            l = _up(l);
            idx /= 2;
        }
        p = new bytes32[](n);
        for (uint256 i; i < n; i++) {
            p[i] = buf[i];
        }
    }
}
