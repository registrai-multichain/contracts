// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployScriptsTest} from "./DeployScripts.t.sol";
import {DeployOracle} from "../../script/DeployOracle.s.sol";
import {DeployNanoLedger} from "../../script/DeployNanoLedger.s.sol";
import {DeployNanoStack} from "../../script/DeployNanoStack.s.sol";
import {DeployPerennial} from "../../script/DeployPerennial.s.sol";
import {DeployBuilders} from "../../script/DeployBuilders.s.sol";
import {Handoff} from "../../script/Handoff.s.sol";
import {HandoffCommonMarkets} from "../../script/HandoffCommonMarkets.s.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {VerifiedBuilderBadge} from "../../src/perennial/VerifiedBuilderBadge.sol";

/// A common-markets-only mainnet launch: oracle -> ledger -> MarketsV4, handed off
/// without the Perennial layer; the full Handoff still works once that layer lands.
contract HandoffCommonMarketsTest is DeployScriptsTest {
    function _commonOnMainnet(bool safeOwnedLedger) internal returns (HandoffCommonMarkets.Common memory c) {
        vm.chainId(5042);
        vm.etch(0x3600000000000000000000000000000000000000, address(usdc).code);
        (registry, attestation, dispute) = new DeployOracle().deploy(
            DeployOracle.Config({deployer: deployer, usdc: _usdcAddr(), minBond: 1e6, points: address(0)})
        );
        ledger = safeOwnedLedger
            ? new NanoLedger(IERC20(_usdcAddr()), admin) // arc-cf's deployOwned: the Safe owns it from the start
            : new DeployNanoLedger().deploy(DeployNanoLedger.Config({deployer: deployer, usdc: _usdcAddr()}));
        _bindSplitter();
        DeployNanoStack.Config memory nc = _v4Cfg();
        nc.settlementWindow = 1 hours;
        (, v4) = new DeployNanoStack().deploy(nc);
        c = HandoffCommonMarkets.Common(address(registry), address(attestation), address(ledger), address(v4));
    }

    function test_common_verifyFailsBeforeHandoff() public {
        HandoffCommonMarkets.Common memory c = _commonOnMainnet(false);
        HandoffCommonMarkets h = new HandoffCommonMarkets();
        vm.expectRevert(bytes("ADMIN lacks MarketsV4 GOVERNOR"));
        h.verify(c, admin, deployer);
    }

    function test_common_handoffMovesV4AndLedgerAdmin_deployerKeepsNothing() public {
        HandoffCommonMarkets.Common memory c = _commonOnMainnet(false);
        new HandoffCommonMarkets().handoff(c, admin, deployer);
        assertTrue(v4.hasRole(GOVERNOR, admin) && v4.hasRole(DEFAULT_ADMIN, admin));
        assertTrue(ledger.hasRole(GOVERNOR, admin) && ledger.hasRole(DEFAULT_ADMIN, admin));
        assertFalse(v4.hasRole(GOVERNOR, deployer) || v4.hasRole(DEFAULT_ADMIN, deployer));
        assertFalse(ledger.hasRole(GOVERNOR, deployer) || ledger.hasRole(DEFAULT_ADMIN, deployer));
        assertTrue(v4.approvedAgent(agent) && v4.approvedResolver(disputeResolver));
        assertEq(v4.SETTLEMENT_WINDOW(), 1 hours);
    }

    function test_common_handoffWithASafeOwnedLedger() public {
        HandoffCommonMarkets.Common memory c = _commonOnMainnet(true);
        new HandoffCommonMarkets().handoff(c, admin, deployer);
        assertTrue(ledger.hasRole(DEFAULT_ADMIN, admin) && !ledger.hasRole(DEFAULT_ADMIN, deployer));
    }

    function test_common_refusesAnEOAAdminOnMainnet() public {
        HandoffCommonMarkets.Common memory c = _commonOnMainnet(false);
        HandoffCommonMarkets h = new HandoffCommonMarkets();
        vm.expectRevert(bytes("mainnet: ADMIN must be a contract (Safe/timelock), not an EOA"));
        h.handoff(c, makeAddr("eoaAdmin"), deployer);
    }

    /// An EOA with an EIP-7702 delegation has code on Arc: it is still one key.
    function test_common_a7702DelegatedEOAIsNotASafe() public {
        HandoffCommonMarkets.Common memory c = _commonOnMainnet(false);
        address eoa7702 = makeAddr("delegatedEoa");
        vm.etch(eoa7702, abi.encodePacked(hex"ef0100", address(0x1234)));
        HandoffCommonMarkets h = new HandoffCommonMarkets();
        vm.expectRevert(bytes("mainnet: ADMIN must be a contract (Safe/timelock), not an EOA"));
        h.handoff(c, eoa7702, deployer);
        // and as a V4 treasury or resolver at deploy
        DeployNanoStack.Config memory nc = _v4Cfg();
        nc.settlementWindow = 1 hours;
        nc.treasury = eoa7702;
        DeployNanoStack n = new DeployNanoStack();
        vm.expectRevert(bytes("mainnet: TREASURY must be a contract (the RegiFeeSplitter)"));
        n.deploy(nc);
        nc = _v4Cfg();
        nc.settlementWindow = 1 hours;
        nc.disputeResolver = eoa7702;
        vm.expectRevert(bytes("mainnet: DISPUTE_RESOLVER must be a contract (a Safe)"));
        n.deploy(nc);
    }

    /// Phase 2 later: the Perennial layer joins the same oracle and ledger, and the
    /// full Handoff completes the table on top of the common-markets handoff.
    function test_common_thenTheFullHandoffStillCompletes() public {
        HandoffCommonMarkets.Common memory c = _commonOnMainnet(false);
        new HandoffCommonMarkets().handoff(c, admin, deployer);
        (BuilderRegistry b1, CaretakerRegistry c1, VerifiedBuilderBadge v1) = new DeployBuilders().deploy(_buildersCfg());
        DeployPerennial.Config memory pc = _perennialCfg();
        (pc.builders, pc.caretakers, pc.badge) = (address(b1), address(c1), address(v1));
        _take(new DeployPerennial().deploy(pc));
        new Handoff().handoff(_stack(), admin, deployer);
        assertFalse(v4.hasRole(DEFAULT_ADMIN, deployer) || ledger.hasRole(DEFAULT_ADMIN, deployer));
    }
}
