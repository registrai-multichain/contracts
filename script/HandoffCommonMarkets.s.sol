// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeployBase} from "./lib/DeployBase.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {NanoLedger} from "../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../src/nanopay/MarketsV4.sol";

/// @notice The admin handoff for a COMMON-MARKETS-ONLY launch: the oracle stack,
///         the shared NanoLedger and MarketsV4 are live, the Perennial layer is
///         not deployed yet. `Handoff.s.sol` needs the whole stack, so it cannot
///         run here; this script moves the admin roles of the part that exists
///         and asserts it. Running the full Handoff later still works: it skips
///         roles ADMIN already holds and renounces only what the deployer holds.
///
///         Moves to ADMIN and renounces from the deployer: MarketsV4 GOVERNOR +
///         DEFAULT_ADMIN, NanoLedger GOVERNOR + DEFAULT_ADMIN (skipped when the
///         ledger was deployed Safe-owned). Then ASSERTS (verify): ADMIN holds
///         all four, the deployer none; the oracle's one-shot deployer powers
///         (wire, setPoints) are consumed; V4 settles on this oracle and pays on
///         this ledger and is no ledger source; on mainnet the deployer is no
///         approved agent/resolver, and TREASURY is a contract (the fee splitter)
///         that withdraws from this same ledger.
///
/// @dev env: ADMIN, REGISTRY, ATTESTATION, NANO_LEDGER, MARKETS_V4.
///      VerifyCommonMarkets (below) runs the same checks read-only.
contract HandoffCommonMarkets is DeployBase {
    bytes32 internal constant DEFAULT_ADMIN = 0x00;
    bytes32 internal constant GOVERNOR = keccak256("GOVERNOR_ROLE");

    struct Common {
        address registry;
        address attestation;
        address ledger;
        address v4;
    }

    function run() external virtual {
        _guardChain();
        handoff(_load(), vm.envAddress("ADMIN"), msg.sender);
    }

    function _load() internal view returns (Common memory c) {
        c.registry = vm.envAddress("REGISTRY");
        c.attestation = vm.envAddress("ATTESTATION");
        c.ledger = vm.envAddress("NANO_LEDGER");
        c.v4 = vm.envAddress("MARKETS_V4");
    }

    /// (contract, role) pairs, DEFAULT_ADMIN last per contract so renouncing in
    /// this order never locks the deployer out mid-way.
    function _roles(Common memory c) internal pure returns (address[4] memory where, bytes32[4] memory roles) {
        where = [c.v4, c.v4, c.ledger, c.ledger];
        roles = [GOVERNOR, DEFAULT_ADMIN, GOVERNOR, DEFAULT_ADMIN];
    }

    function handoff(Common memory c, address admin, address deployer) public {
        _guardChain();
        require(admin != address(0) && deployer != address(0), "ADMIN/deployer not set");
        require(admin != deployer, "ADMIN must not be the deployer");
        if (_isMainnet()) require(admin.code.length > 0, "mainnet: ADMIN must be a contract (Safe/timelock), not an EOA");
        (address[4] memory where, bytes32[4] memory roles) = _roles(c);
        vm.startBroadcast(deployer);
        for (uint256 i; i < 4; i++) {
            if (!IAccessControl(where[i]).hasRole(roles[i], admin)) IAccessControl(where[i]).grantRole(roles[i], admin);
        }
        for (uint256 i; i < 4; i++) {
            if (IAccessControl(where[i]).hasRole(roles[i], deployer)) IAccessControl(where[i]).renounceRole(roles[i], deployer);
        }
        vm.stopBroadcast();
        verify(c, admin, deployer);
        console2.log("Common markets handoff complete. ADMIN:", admin);
    }

    function verify(Common memory c, address admin, address deployer) public view {
        (address[4] memory where, bytes32[4] memory roles) = _roles(c);
        string[4] memory names = ["MarketsV4 GOVERNOR", "MarketsV4 DEFAULT_ADMIN", "NanoLedger GOVERNOR", "NanoLedger DEFAULT_ADMIN"];
        for (uint256 i; i < 4; i++) {
            require(IAccessControl(where[i]).hasRole(roles[i], admin), string.concat("ADMIN lacks ", names[i]));
            require(!IAccessControl(where[i]).hasRole(roles[i], deployer), string.concat("deployer still holds ", names[i]));
        }
        Registry r = Registry(c.registry);
        Attestation at = Attestation(c.attestation);
        require(r.attestation() == c.attestation && r.dispute() != address(0) && at.dispute() == r.dispute(), "oracle stack not wired (deployer can still wire)");
        require(r.pointsSet() && at.pointsSet(), "setPoints not consumed (deployer can still set points)");
        MarketsV4 v4 = MarketsV4(c.v4);
        require(address(v4.LEDGER()) == c.ledger, "v4 ledger: one shared ledger");
        require(address(v4.ATTESTATION()) == c.attestation, "v4 attestation");
        require(address(v4.REGISTRY()) == c.registry, "v4 registry");
        require(!NanoLedger(c.ledger).isSource(c.v4), "v4 is a ledger source (it needs no ledger role)");
        if (_isMainnet()) {
            require(!v4.approvedAgent(deployer), "deployer is an approved agent (v4)");
            require(!v4.approvedResolver(deployer), "deployer is an approved resolver (v4)");
            address t = v4.TREASURY();
            require(t != deployer && t.code.length > 0, "mainnet: V4 TREASURY must be a contract (the fee splitter)");
            (bool ok, bytes memory ret) = t.staticcall(abi.encodeWithSignature("LEDGER()"));
            require(ok && ret.length == 32 && abi.decode(ret, (address)) == c.ledger, "mainnet: V4 TREASURY withdraws from another ledger");
        }
        console2.log("MarketsV4 SETTLEMENT_WINDOW (the rounds agent's settlement_window must equal it):", v4.SETTLEMENT_WINDOW());
    }
}

/// @notice Read-only: the same assertions as HandoffCommonMarkets.verify.
/// @dev env: ADMIN, DEPLOYER, REGISTRY, ATTESTATION, NANO_LEDGER, MARKETS_V4.
contract VerifyCommonMarkets is HandoffCommonMarkets {
    function run() external override {
        verify(_load(), vm.envAddress("ADMIN"), vm.envAddress("DEPLOYER"));
    }
}
