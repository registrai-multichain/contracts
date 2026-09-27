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
import {BinaryMarket} from "../../../src/nanopay/BinaryMarket.sol";
import {RegiFeeSplitter} from "../../../src/buyback/RegiFeeSplitter.sol";
import {INanoLedgerMinimal} from "../../../src/buyback/INanoLedgerMinimal.sol";
import {DeployOracle} from "../../../script/DeployOracle.s.sol";
import {DeployNanoStack} from "../../../script/DeployNanoStack.s.sol";
import {HandoffCommonMarkets} from "../../../script/HandoffCommonMarkets.s.sol";

contract V4SafeStub {}

/// Runs the exact mainnet launch path locally (chainid 5042, no fork):
/// DeployOracle -> (live, Safe-owned NanoLedger + real RegiFeeSplitter) ->
/// DeployNanoStack -> HandoffCommonMarkets, recording every log, and rebuilds the
/// FINAL role / approval table from the events (AccessControl is not enumerable,
/// so hasRole spot checks alone cannot prove "nobody else").
contract V4DeployRoleTableTest is Test {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    bytes32 constant DEFAULT_ADMIN = 0x00;
    bytes32 constant GOVERNOR = keccak256("GOVERNOR_ROLE");

    address deployer = makeAddr("deployer");
    address agent = makeAddr("agent");
    address safe;
    RegiFeeSplitter splitter;
    NanoLedger ledger;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    MarketsV4 v4;

    Vm.Log[] recorded;

    function setUp() public {
        vm.warp(1_790_000_000);
        vm.chainId(5042);
        MockUSDC m = new MockUSDC();
        vm.etch(ARC_USDC, address(m).code);
        safe = address(new V4SafeStub());
        // already live on mainnet: the Safe-owned ledger and the splitter bound to it
        ledger = new NanoLedger(IERC20(ARC_USDC), safe);
        splitter = new RegiFeeSplitter(INanoLedgerMinimal(address(ledger)), IERC20(ARC_USDC), safe, makeAddr("buyback"));
    }

    function _launch() internal {
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

    function _handoff() internal {
        new HandoffCommonMarkets().handoff(
            HandoffCommonMarkets.Common(address(registry), address(attestation), address(ledger), address(v4)), safe, deployer
        );
    }

    /// Final holders of `role` on `where`, from RoleGranted / RoleRevoked logs.
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

    /// Final `true` set of a V4 allowlist, from its `XApprovalSet(address indexed, bool)` logs.
    function _approved(bytes32 sig) internal view returns (address[] memory out) {
        address[] memory seen = new address[](recorded.length);
        bool[] memory on = new bool[](recorded.length);
        uint256 n;
        for (uint256 i; i < recorded.length; i++) {
            Vm.Log memory l = recorded[i];
            if (l.emitter != address(v4) || l.topics[0] != sig) continue;
            address a = address(uint160(uint256(l.topics[1])));
            bool v = abi.decode(l.data, (bool));
            uint256 j;
            for (; j < n; j++) if (seen[j] == a) break;
            if (j == n) seen[n++] = a;
            on[j] = v;
        }
        out = new address[](n);
        uint256 k;
        for (uint256 j; j < n; j++) if (on[j]) out[k++] = seen[j];
        assembly {
            mstore(out, k)
        }
    }

    function _only(address[] memory got, address want, string memory what) internal pure {
        require(got.length == 1 && got[0] == want, what);
    }

    function test_launchPath_finalRoleTable_onlyTheSafe() public {
        vm.recordLogs();
        _launch();
        _handoff();
        Vm.Log[] memory l = vm.getRecordedLogs();
        for (uint256 i; i < l.length; i++) recorded.push(l[i]);

        // AccessControl: only the Safe holds anything, on V4 and on the ledger
        _only(_holders(address(v4), DEFAULT_ADMIN), safe, "V4 DEFAULT_ADMIN != {Safe}");
        _only(_holders(address(v4), GOVERNOR), safe, "V4 GOVERNOR != {Safe}");
        assertEq(v4.getRoleAdmin(GOVERNOR), DEFAULT_ADMIN);
        assertTrue(ledger.hasRole(DEFAULT_ADMIN, safe) && ledger.hasRole(GOVERNOR, safe));
        assertFalse(ledger.hasRole(DEFAULT_ADMIN, deployer) || ledger.hasRole(GOVERNOR, deployer));
        assertEq(_holders(address(ledger), DEFAULT_ADMIN).length, 0, "no new ledger admin granted during launch");
        assertEq(_holders(address(ledger), GOVERNOR).length, 0, "no new ledger governor granted during launch");

        // V4 allowlists: exactly the intended agent and resolver, no creator
        _only(_approved(keccak256("AgentApprovalSet(address,bool)")), agent, "approved agents != {agent}");
        _only(_approved(keccak256("ResolverApprovalSet(address,bool)")), safe, "approved resolvers != {Safe}");
        assertEq(_approved(keccak256("CreatorApprovalSet(address,bool)")).length, 0, "an approved creator exists");

        // wiring
        assertEq(address(v4.LEDGER()), address(ledger));
        assertEq(v4.TREASURY(), address(splitter));
        assertEq(address(splitter.LEDGER()), address(ledger));
        assertEq(v4.SETTLEMENT_WINDOW(), 1 hours);
        assertEq(v4.RESOLUTION_GRACE(), 7 days);
        assertEq(v4.EXPIRY_GRID(), 5 minutes);
        assertFalse(ledger.isSource(address(v4)));
        assertEq(registry.MIN_BOND(), 2e6);

        // the deployer's one-shot oracle powers are consumed; Dispute has no admin
        vm.startPrank(deployer);
        vm.expectRevert(Registry.AlreadyWired.selector);
        registry.wire(address(1), address(2));
        vm.expectRevert(Registry.AlreadyWired.selector);
        registry.setPoints(address(1));
        vm.expectRevert(Attestation.AlreadyWired.selector);
        attestation.wire(address(1));
        vm.expectRevert(Attestation.AlreadyWired.selector);
        attestation.setPoints(address(1));
        // and it can do nothing on V4 / the ledger
        vm.expectRevert();
        v4.setApprovedCreator(deployer, true);
        vm.expectRevert();
        v4.grantRole(GOVERNOR, deployer);
        vm.expectRevert();
        ledger.setSource(deployer, true);
        vm.expectRevert();
        ledger.skimSurplus(deployer);
        // and cannot open a market (not the agent, not a creator)
        vm.expectRevert();
        v4.createMarket(bytes32(0), agent, 0, BinaryMarket.Comparator.GreaterThan, 1_790_000_100, 5e6);
        vm.stopPrank();
    }

    /// Verify gap (Info): HandoffCommonMarkets.verify only proves the DEPLOYER holds
    /// no role. A role the deployer key granted to another address before the
    /// handoff (a compromised or fat-fingered key between steps 3 and 4) survives,
    /// and verify / VerifyCommonMarkets still pass.
    function test_verifyGap_extraGovernorGrantedBeforeHandoffSurvives() public {
        _launch();
        address extra = makeAddr("extraHotKey");
        vm.startPrank(deployer);
        v4.grantRole(DEFAULT_ADMIN, extra);
        v4.setApprovedCreator(extra, true); // ... and it may even pre-approve itself as a creator
        v4.setApprovedCreator(extra, false); // (verify does check deployer-as-creator only)
        vm.stopPrank();
        _handoff(); // passes (verify runs inside)
        assertTrue(v4.hasRole(DEFAULT_ADMIN, extra), "extra admin survived a passing handoff+verify");
        // the extra admin can now make itself governor and approve itself as a market creator
        vm.startPrank(extra);
        v4.grantRole(GOVERNOR, extra);
        v4.setApprovedCreator(extra, true);
        vm.stopPrank();
        assertTrue(v4.approvedCreator(extra));
    }
}
