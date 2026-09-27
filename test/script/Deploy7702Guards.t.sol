// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {DeployBase} from "../../script/lib/DeployBase.sol";
import {DeployBuilders} from "../../script/DeployBuilders.s.sol";
import {DeployBadge} from "../../script/DeployBadge.s.sol";
import {DeployOracle} from "../../script/DeployOracle.s.sol";
import {DeployNanoLedger} from "../../script/DeployNanoLedger.s.sol";
import {DeployPerennial} from "../../script/DeployPerennial.s.sol";
import {DeployBuyback} from "../../script/DeployBuyback.s.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";

contract IsContractHarness is DeployBase {
    function isContract(address a) external view returns (bool) {
        return _isContract(a);
    }
}

/// On Arc mainnet an EOA with an EIP-7702 delegation carries 23 bytes of code
/// (0xef0100 ++ delegate) yet one key controls it. Every mainnet "must be a contract
/// (a Safe)" guard must refuse it; `code.length > 0` alone accepts it.
contract Deploy7702GuardsTest is Test {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address constant SAFE = 0xFeE926e8Be2D1C6192213cf20f31D94Dad1e80Fb;
    address deployer = makeAddr("deployer");
    address operator = makeAddr("operator");
    address delegated = makeAddr("delegatedEoa");
    MockUSDC usdc;

    function setUp() public {
        usdc = new MockUSDC();
        _delegate(delegated);
    }

    function _delegate(address eoa) internal {
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(usdc)));
    }

    function test_isContract_refusesEOAsAndDelegatedEOAs() public {
        IsContractHarness h = new IsContractHarness();
        assertFalse(h.isContract(makeAddr("plainEoa")), "plain EOA");
        assertEq(delegated.code.length, 23);
        assertFalse(h.isContract(delegated), "7702-delegated EOA");
        assertTrue(h.isContract(address(usdc)), "a contract");
        address odd23 = makeAddr("odd23");
        vm.etch(odd23, abi.encodePacked(hex"ef0200", address(usdc)));
        assertTrue(h.isContract(odd23), "23 bytes that are not the designator");
    }

    function test_builders_mainnetRefusesDelegatedAdmin() public {
        vm.chainId(5042);
        DeployBuilders.Config memory c;
        c.deployer = deployer;
        c.admin = delegated;
        c.operator = operator;
        c.chainLabel = "Arc Mainnet";
        c.imageBase = "https://registrai.cc/badge/arc/";
        c.externalBase = "https://registrai.cc/builders/?builder=";
        DeployBuilders d = new DeployBuilders();
        vm.expectRevert(bytes("mainnet: ADMIN must be a contract (Safe/timelock), not an EOA"));
        d.deploy(c);
    }

    function test_badge_mainnetRefusesDelegatedAdmin() public {
        vm.chainId(5042);
        DeployBadge d = new DeployBadge();
        DeployBadge.Config memory c = DeployBadge.Config({
            deployer: deployer,
            builders: address(usdc), // any contract: the guard under test comes first
            admin: delegated,
            operator: operator,
            chainLabel: "Arc Mainnet",
            imageBase: "https://registrai.cc/badge/arc/",
            externalBase: "https://builder.registrai.cc/builders/?builder="
        });
        vm.expectRevert(bytes("mainnet: ADMIN must be a contract (Safe/timelock), not an EOA"));
        d.deploy(c);
    }

    function test_perennial_mainnetRefusesDelegatedResolver() public {
        vm.chainId(5042);
        vm.etch(ARC_USDC, address(usdc).code);
        (Registry registry, Attestation attestation,) =
            new DeployOracle().deploy(DeployOracle.Config({deployer: deployer, usdc: ARC_USDC, minBond: 10e6, points: address(0)}));
        NanoLedger ledger = new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: ARC_USDC}));
        DeployPerennial.Config memory c;
        c.deployer = deployer;
        c.registry = address(registry);
        c.attestation = address(attestation);
        c.ledger = address(ledger);
        c.epochLength = 30 days;
        c.settlementWindow = 24 hours;
        c.resolutionGrace = 7 days;
        c.protocolTreasury = makeAddr("treasury");
        c.approvedAgent = makeAddr("agent");
        c.disputeResolver = delegated;
        c.operator = operator;
        c.onboarder = makeAddr("onboarder");
        c.wonderExpiry = 180 days;
        DeployPerennial p = new DeployPerennial();
        vm.expectRevert(bytes("mainnet: DISPUTE_RESOLVER must be a contract (a Safe)"));
        p.deploy(c);
    }

    function test_nanoLedger_mainnetRefusesTheSafeAddressIfItIsADelegatedEOA() public {
        vm.chainId(5042);
        _delegate(SAFE);
        DeployNanoLedger d = new DeployNanoLedger();
        vm.expectRevert(bytes("mainnet: ADMIN must be the Admin Safe 0xFeE9...80Fb"));
        d.deployOwned(DeployNanoLedger.Config({deployer: deployer, usdc: ARC_USDC}), SAFE);
    }

    function test_buyback_refusesDelegatedLedger() public {
        vm.chainId(5042);
        DeployBuyback d = new DeployBuyback();
        vm.expectRevert(bytes("NANO_LEDGER must be the shared ledger"));
        d.deploy(SAFE, delegated);
    }
}
