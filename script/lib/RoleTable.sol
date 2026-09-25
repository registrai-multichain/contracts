// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeployBase} from "./DeployBase.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {WonderEscrow} from "../../src/perennial/WonderEscrow.sol";

/// @notice The role table of a deployed mainnet stack, and the assertions that
/// define "handed off": ADMIN holds every admin/governor/registrar role, the
/// deployer holds none, only MarketsPerennial and the WonderEscrow credit builder
/// income (fund MARKETS_ROLE), only MarketsPerennial credits the escrow, only the
/// fund funds the season pool (FUNDER_ROLE), the deployer keeps no operator
/// role (FEED, RELEASER, YIELD), and
/// the oracle stack's one-shot deployer powers (wire, setPoints) are consumed.
abstract contract RoleTable is DeployBase {
    struct Stack {
        address registry;
        address attestation;
        address ledger;
        address builders;
        address caretakers;
        address fund;
        address seasonPool;
        address perennial;
        address v4;
        address escrow;
    }

    bytes32 internal constant DEFAULT_ADMIN = 0x00;
    bytes32 internal constant GOVERNOR = keccak256("GOVERNOR_ROLE");
    bytes32 internal constant REGISTRAR = keccak256("REGISTRAR_ROLE");
    bytes32 internal constant MARKETS = keccak256("MARKETS_ROLE");
    bytes32 internal constant FUNDER = keccak256("FUNDER_ROLE");
    bytes32 internal constant NOMINATOR = keccak256("NOMINATOR_ROLE");
    bytes32 internal constant FEED = keccak256("FEED_ROLE");
    bytes32 internal constant RELEASER = keccak256("RELEASER_ROLE");
    bytes32 internal constant YIELD = keccak256("YIELD_ROLE");

    function _loadStack() internal view returns (Stack memory s) {
        s.registry = vm.envAddress("REGISTRY");
        s.attestation = vm.envAddress("ATTESTATION");
        s.ledger = vm.envAddress("NANO_LEDGER");
        s.builders = vm.envAddress("BUILDER_REGISTRY");
        s.caretakers = vm.envAddress("CARETAKER_REGISTRY");
        s.fund = vm.envAddress("BUILDER_FUND");
        s.seasonPool = vm.envAddress("SEASON_POOL");
        s.perennial = vm.envAddress("MARKETS_PERENNIAL");
        s.v4 = vm.envAddress("MARKETS_V4");
        s.escrow = vm.envAddress("WONDER_ESCROW");
    }

    /// @dev The admin-type roles of every AccessControl contract in the stack:
    /// (contract, role, name). DEFAULT_ADMIN is listed LAST per contract so a
    /// handoff that renounces in this order never locks itself out mid-way.
    function _adminRoles(Stack memory s)
        internal
        pure
        returns (address[] memory where, bytes32[] memory roles, string[] memory names)
    {
        where = new address[](18);
        roles = new bytes32[](18);
        names = new string[](18);
        uint256 i;
        (where[i], roles[i], names[i]) = (s.ledger, GOVERNOR, "NanoLedger GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.ledger, DEFAULT_ADMIN, "NanoLedger DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.builders, REGISTRAR, "BuilderRegistry REGISTRAR");
        i++;
        (where[i], roles[i], names[i]) = (s.builders, DEFAULT_ADMIN, "BuilderRegistry DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.caretakers, GOVERNOR, "CaretakerRegistry GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.caretakers, DEFAULT_ADMIN, "CaretakerRegistry DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.fund, GOVERNOR, "BuilderFund GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.fund, DEFAULT_ADMIN, "BuilderFund DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.seasonPool, GOVERNOR, "SeasonPool GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.seasonPool, DEFAULT_ADMIN, "SeasonPool DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.perennial, GOVERNOR, "MarketsPerennial GOVERNOR");
        i++;
        // The Safe nominates too (with the onboarder) and may bind a feed itself.
        (where[i], roles[i], names[i]) = (s.perennial, NOMINATOR, "MarketsPerennial NOMINATOR");
        i++;
        (where[i], roles[i], names[i]) = (s.perennial, FEED, "MarketsPerennial FEED");
        i++;
        (where[i], roles[i], names[i]) = (s.perennial, DEFAULT_ADMIN, "MarketsPerennial DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.escrow, GOVERNOR, "WonderEscrow GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.escrow, DEFAULT_ADMIN, "WonderEscrow DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.v4, GOVERNOR, "MarketsV4 GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.v4, DEFAULT_ADMIN, "MarketsV4 DEFAULT_ADMIN");
    }

    function _has(address where, bytes32 role, address who) internal view returns (bool) {
        return IAccessControl(where).hasRole(role, who);
    }

    /// @notice Assert the handed-off role table. Reverts naming the first
    /// violated row. With `print`, logs every row first.
    function _verifyRoles(Stack memory s, address admin, address deployer, bool print) internal view {
        require(admin != address(0) && deployer != address(0), "admin/deployer not set");
        (address[] memory where, bytes32[] memory roles, string[] memory names) = _adminRoles(s);
        for (uint256 i; i < where.length; i++) {
            bool a = _has(where[i], roles[i], admin);
            bool d = _has(where[i], roles[i], deployer);
            if (print) console2.log(string.concat(names[i], "  admin=", _b(a), "  deployer=", _b(d)));
            require(a, string.concat("ADMIN lacks ", names[i]));
            require(!d, string.concat("deployer still holds ", names[i]));
        }

        // Builder income is credited only by the markets, and the season pool is
        // funded only by the fund (each checks its balance, but a stray holder
        // could still misattribute what arrives).
        bool mMkt = _has(s.fund, MARKETS, s.perennial);
        bool mDep = _has(s.fund, MARKETS, deployer);
        bool mAdm = _has(s.fund, MARKETS, admin);
        bool fFund = _has(s.seasonPool, FUNDER, s.fund);
        bool fDep = _has(s.seasonPool, FUNDER, deployer);
        bool fAdm = _has(s.seasonPool, FUNDER, admin);
        if (print) {
            console2.log(string.concat("BuilderFund MARKETS  markets=", _b(mMkt), "  admin=", _b(mAdm), "  deployer=", _b(mDep)));
            console2.log(string.concat("SeasonPool FUNDER  fund=", _b(fFund), "  admin=", _b(fAdm), "  deployer=", _b(fDep)));
        }
        require(mMkt, "markets lack BuilderFund MARKETS");
        require(!mDep, "deployer holds BuilderFund MARKETS");
        require(!mAdm, "ADMIN holds BuilderFund MARKETS (income is credited by the markets only)");
        bool mEsc = _has(s.fund, MARKETS, s.escrow);
        bool eMkt = _has(s.escrow, MARKETS, s.perennial);
        bool eDep = _has(s.escrow, MARKETS, deployer);
        bool eAdm = _has(s.escrow, MARKETS, admin);
        if (print) {
            console2.log(string.concat("BuilderFund MARKETS  escrow=", _b(mEsc)));
            console2.log(string.concat("WonderEscrow MARKETS  markets=", _b(eMkt), "  admin=", _b(eAdm), "  deployer=", _b(eDep)));
        }
        require(mEsc, "escrow lacks BuilderFund MARKETS");
        require(eMkt, "markets lack WonderEscrow MARKETS");
        require(!eDep, "deployer holds WonderEscrow MARKETS");
        require(!eAdm, "ADMIN holds WonderEscrow MARKETS (the escrow is credited by the markets only)");
        require(fFund, "fund lacks SeasonPool FUNDER");
        require(!fDep, "deployer holds SeasonPool FUNDER");
        require(!fAdm, "ADMIN holds SeasonPool FUNDER (the pool is funded by the fund only)");

        // Oracle stack: no roles, but Registry/Attestation give their DEPLOYER
        // two one-shot powers. Both must be consumed.
        Registry r = Registry(s.registry);
        Attestation at = Attestation(s.attestation);
        bool wired = r.attestation() == s.attestation && r.dispute() != address(0)
            && at.dispute() == r.dispute();
        bool sealed_ = r.pointsSet() && at.pointsSet();
        if (print) {
            console2.log(string.concat("Registry/Attestation wired=", _b(wired), "  points sealed=", _b(sealed_)));
        }
        require(wired, "oracle stack not wired (deployer can still wire)");
        require(sealed_, "setPoints not consumed (deployer can still set points)");

        // Wiring sanity: markets settle on this oracle and ledger.
        require(address(MarketsPerennial(s.perennial).LEDGER()) == s.ledger, "perennial ledger");
        require(address(MarketsV4(s.v4).LEDGER()) == s.ledger, "v4 ledger: one shared ledger");
        require(address(MarketsPerennial(s.perennial).ATTESTATION()) == s.attestation, "perennial attestation");
        require(address(MarketsV4(s.v4).ATTESTATION()) == s.attestation, "v4 attestation");
        // Neither market creates fee pools: no market needs to be a ledger source.
        require(!NanoLedger(s.ledger).isSource(s.v4), "v4 is a ledger source (it needs no ledger role)");
        BuilderFund fund = BuilderFund(s.fund);
        SeasonPool pool = SeasonPool(s.seasonPool);
        require(address(MarketsPerennial(s.perennial).FUND()) == s.fund, "perennial fund");
        require(address(fund.SEASON_POOL()) == s.seasonPool, "fund season pool");
        require(address(fund.LEDGER()) == s.ledger, "fund ledger");
        require(address(pool.LEDGER()) == s.ledger, "season pool ledger");
        require(address(fund.BUILDERS()) == s.builders, "fund builders");
        require(address(fund.CARETAKERS()) == s.caretakers, "fund caretakers");
        require(address(pool.BUILDERS()) == s.builders, "season pool builders");
        require(address(pool.CARETAKERS()) == s.caretakers, "season pool caretakers");
        require(address(CaretakerRegistry(s.caretakers).BUILDERS()) == s.builders, "caretakers builders");
        require(address(MarketsPerennial(s.perennial).BUILDERS()) == s.builders, "perennial builders");
        WonderEscrow escrow = WonderEscrow(s.escrow);
        require(address(MarketsPerennial(s.perennial).ESCROW()) == s.escrow, "perennial escrow");
        require(address(escrow.FUND()) == s.fund, "escrow fund");
        require(address(escrow.LEDGER()) == s.ledger, "escrow ledger");
        require(address(escrow.BADGE()) == address(MarketsPerennial(s.perennial).BADGE()), "escrow badge");
        require(address(MarketsPerennial(s.perennial).BADGE().BUILDERS()) == s.builders, "perennial badge builders");

        if (_isMainnet()) {
            // Allowlist entries are not roles, but the deployer must not be a vetted oracle.
            require(!MarketsPerennial(s.perennial).approvedAgent(deployer), "deployer is an approved agent (perennial)");
            require(!MarketsPerennial(s.perennial).approvedResolver(deployer), "deployer is an approved resolver (perennial)");
            // V4 settles only on vetted agents and resolvers, as Perennial does.
            require(!MarketsV4(s.v4).approvedAgent(deployer), "deployer is an approved agent (v4)");
            require(!MarketsV4(s.v4).approvedResolver(deployer), "deployer is an approved resolver (v4)");
            // Fee recipients are immutable: they must not be the deployer's key.
            require(MarketsV4(s.v4).TREASURY() != deployer, "deployer is the V4 treasury");
            require(fund.PROTOCOL_TREASURY() != deployer, "deployer is the protocol treasury");
            // Operator roles: never the deployer's key (off mainnet the deployer
            // may be the operator, as DeployPerennial defaults it).
            require(!_has(s.escrow, RELEASER, deployer), "deployer holds WonderEscrow RELEASER");
            require(!_has(s.escrow, YIELD, deployer), "deployer holds WonderEscrow YIELD");
            require(!_has(s.perennial, FEED, deployer), "deployer holds MarketsPerennial FEED");
        }
    }

    /// @notice Phase 2 guard for the phase-1 ONBOARDER (a hot wallet with badge
    /// ISSUER + CaretakerRegistry GOVERNOR): it must hold no other admin-type role
    /// anywhere in the market stack (BuilderFund and SeasonPool included), and
    /// never fund MARKETS or pool FUNDER.
    ///
    /// Its CaretakerRegistry GOVERNOR may stay, on mainnet too (audit M-1,
    /// revisited for the builder-income design): with the ProgressArbiter gone
    /// no contract reads `caretakerOf` any more. Money follows the market's
    /// builder id (fund) and the Safe-published season root (pool), and is paid
    /// to `payoutOf`, which only the builder's owner sets. setCaretaker now only
    /// feeds the off-chain "verified" status (keeper, gallery, and the season
    /// eligibility the Safe re-derives before publishing a root), the same kind
    /// of power the onboarder's badge ISSUER already has. It is logged.
    function _verifyOnboarder(Stack memory s, address onboarder, bool print) internal view {
        if (onboarder == address(0)) return;
        (address[] memory where, bytes32[] memory roles, string[] memory names) = _adminRoles(s);
        for (uint256 i; i < where.length; i++) {
            bool h = _has(where[i], roles[i], onboarder);
            if (where[i] == s.caretakers && roles[i] == GOVERNOR) {
                if (print) console2.log(string.concat("ONBOARDER CaretakerRegistry GOVERNOR (setCaretaker, off-chain status only) = ", _b(h)));
                continue;
            }
            if (where[i] == s.perennial && roles[i] == NOMINATOR) {
                if (print) console2.log(string.concat("ONBOARDER MarketsPerennial NOMINATOR (wonder-market sources) = ", _b(h)));
                continue;
            }
            require(!h, string.concat("ONBOARDER holds ", names[i]));
        }
        require(!_has(s.fund, MARKETS, onboarder), "ONBOARDER holds BuilderFund MARKETS");
        require(!_has(s.seasonPool, FUNDER, onboarder), "ONBOARDER holds SeasonPool FUNDER");
        require(!_has(s.escrow, MARKETS, onboarder), "ONBOARDER holds WonderEscrow MARKETS");
        require(!_has(s.escrow, RELEASER, onboarder), "ONBOARDER holds WonderEscrow RELEASER");
        require(!_has(s.escrow, YIELD, onboarder), "ONBOARDER holds WonderEscrow YIELD");
        require(!_has(s.perennial, FEED, onboarder), "ONBOARDER holds MarketsPerennial FEED");
        if (print) console2.log("OK: onboarder holds no market/admin role");
    }

    function _b(bool v) internal pure returns (string memory) {
        return v ? "yes" : "no";
    }
}
