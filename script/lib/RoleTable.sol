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
import {ProgressPool} from "../../src/perennial/ProgressPool.sol";
import {ProgressArbiter} from "../../src/perennial/ProgressArbiter.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// @notice The role table of a deployed mainnet stack, and the assertions that
/// define "handed off": ADMIN holds every admin/governor/registrar role, the
/// deployer holds none, only the arbiter writes progress, and the oracle
/// stack's one-shot deployer powers (wire, setPoints) are consumed.
abstract contract RoleTable is DeployBase {
    struct Stack {
        address registry;
        address attestation;
        address ledger;
        address builders;
        address caretakers;
        address pool;
        address perennial;
        address v4;
        address arbiter;
    }

    bytes32 internal constant DEFAULT_ADMIN = 0x00;
    bytes32 internal constant GOVERNOR = keccak256("GOVERNOR_ROLE");
    bytes32 internal constant REGISTRAR = keccak256("REGISTRAR_ROLE");
    bytes32 internal constant PROGRESS = keccak256("PROGRESS_ROLE");
    bytes32 internal constant PROPOSER = keccak256("PROPOSER_ROLE");
    bytes32 internal constant RESOLVER = keccak256("RESOLVER_ROLE");

    function _loadStack() internal view returns (Stack memory s) {
        s.registry = vm.envAddress("REGISTRY");
        s.attestation = vm.envAddress("ATTESTATION");
        s.ledger = vm.envAddress("NANO_LEDGER");
        s.builders = vm.envAddress("BUILDER_REGISTRY");
        s.caretakers = vm.envAddress("CARETAKER_REGISTRY");
        s.pool = vm.envAddress("PROGRESS_POOL");
        s.perennial = vm.envAddress("MARKETS_PERENNIAL");
        s.v4 = vm.envAddress("MARKETS_V4");
        s.arbiter = vm.envAddress("PROGRESS_ARBITER");
    }

    /// @dev The admin-type roles of every AccessControl contract in the stack:
    /// (contract, role, name). DEFAULT_ADMIN is listed LAST per contract so a
    /// handoff that renounces in this order never locks itself out mid-way.
    function _adminRoles(Stack memory s)
        internal
        pure
        returns (address[] memory where, bytes32[] memory roles, string[] memory names)
    {
        where = new address[](13);
        roles = new bytes32[](13);
        names = new string[](13);
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
        (where[i], roles[i], names[i]) = (s.pool, GOVERNOR, "ProgressPool GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.pool, DEFAULT_ADMIN, "ProgressPool DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.perennial, GOVERNOR, "MarketsPerennial GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.perennial, DEFAULT_ADMIN, "MarketsPerennial DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.v4, GOVERNOR, "MarketsV4 GOVERNOR");
        i++;
        (where[i], roles[i], names[i]) = (s.v4, DEFAULT_ADMIN, "MarketsV4 DEFAULT_ADMIN");
        i++;
        (where[i], roles[i], names[i]) = (s.arbiter, DEFAULT_ADMIN, "ProgressArbiter DEFAULT_ADMIN");
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

        // Progress reaches the pool only through the arbiter.
        bool pArb = _has(s.pool, PROGRESS, s.arbiter);
        bool pDep = _has(s.pool, PROGRESS, deployer);
        bool pAdm = _has(s.pool, PROGRESS, admin);
        bool arbProp = _has(s.arbiter, PROPOSER, deployer);
        bool arbRes = _has(s.arbiter, RESOLVER, deployer);
        if (print) {
            console2.log(string.concat("ProgressPool PROGRESS  arbiter=", _b(pArb), "  admin=", _b(pAdm), "  deployer=", _b(pDep)));
            console2.log(string.concat("ProgressArbiter PROPOSER deployer=", _b(arbProp), "  RESOLVER deployer=", _b(arbRes)));
        }
        require(pArb, "arbiter lacks ProgressPool PROGRESS");
        require(!pDep, "deployer holds ProgressPool PROGRESS");
        require(!pAdm, "ADMIN holds ProgressPool PROGRESS (progress must go through the arbiter)");
        require(!arbProp, "deployer holds ProgressArbiter PROPOSER");
        require(!arbRes, "deployer holds ProgressArbiter RESOLVER");

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
        require(address(ProgressArbiter(s.arbiter).POOL()) == s.pool, "arbiter pool");
        require(MarketsPerennial(s.perennial).commons() == s.pool, "perennial commons");
        require(address(ProgressPool(s.pool).BUILDERS()) == s.builders, "pool builders");
        require(address(ProgressPool(s.pool).CARETAKERS()) == s.caretakers, "pool caretakers");
        require(address(ProgressArbiter(s.arbiter).BUILDERS()) == s.builders, "arbiter builders");
        require(address(ProgressArbiter(s.arbiter).CARETAKERS()) == s.caretakers, "arbiter caretakers");
        require(address(CaretakerRegistry(s.caretakers).BUILDERS()) == s.builders, "caretakers builders");
        require(address(MarketsPerennial(s.perennial).BUILDERS()) == s.builders, "perennial builders");

        if (_isMainnet()) {
            // Allowlist entries are not roles, but the deployer must not be a vetted oracle.
            require(!MarketsPerennial(s.perennial).approvedAgent(deployer), "deployer is an approved agent (perennial)");
            require(!MarketsPerennial(s.perennial).approvedResolver(deployer), "deployer is an approved resolver (perennial)");
            // V4 agents are permissionless; only its resolver allowlist is vetted.
            require(!MarketsV4(s.v4).approvedResolver(deployer), "deployer is an approved resolver (v4)");
            // Fee recipients are immutable: they must not be the deployer's key.
            require(MarketsV4(s.v4).TREASURY() != deployer, "deployer is the V4 treasury");
            require(ProgressPool(s.pool).PROTOCOL_TREASURY() != deployer, "deployer is the protocol treasury");
        }
    }

    /// @notice Phase 2 guard for the phase-1 ONBOARDER (a hot wallet with badge
    /// ISSUER + CaretakerRegistry GOVERNOR): it must hold no other admin-type role
    /// anywhere in the market stack, and never progress/proposer/resolver. On
    /// mainnet its CaretakerRegistry GOVERNOR must be revoked too (it decides who
    /// can draw from the commons once markets exist); elsewhere it is logged.
    function _verifyOnboarder(Stack memory s, address onboarder, bool print) internal view {
        if (onboarder == address(0)) return;
        (address[] memory where, bytes32[] memory roles, string[] memory names) = _adminRoles(s);
        for (uint256 i; i < where.length; i++) {
            bool h = _has(where[i], roles[i], onboarder);
            if (where[i] == s.caretakers && roles[i] == GOVERNOR) {
                // With markets live, setCaretaker decides who the operator may
                // propose progress for — i.e. who draws from the commons. A hot
                // wallet must not hold that on mainnet (audit M-1).
                if (_isMainnet()) require(!h, "mainnet: revoke the ONBOARDER's CaretakerRegistry GOVERNOR before markets");
                if (print) console2.log(string.concat("ONBOARDER CaretakerRegistry GOVERNOR (setCaretaker) = ", _b(h)));
                continue;
            }
            require(!h, string.concat("ONBOARDER holds ", names[i]));
        }
        require(!_has(s.pool, PROGRESS, onboarder), "ONBOARDER holds ProgressPool PROGRESS");
        require(!_has(s.arbiter, PROPOSER, onboarder), "ONBOARDER holds ProgressArbiter PROPOSER");
        require(!_has(s.arbiter, RESOLVER, onboarder), "ONBOARDER holds ProgressArbiter RESOLVER");
        if (print) console2.log("OK: onboarder holds no market/admin role");
    }

    function _b(bool v) internal pure returns (string memory) {
        return v ? "yes" : "no";
    }
}
