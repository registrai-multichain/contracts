// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {MedianRule} from "../src/rules/MedianRule.sol";
import {TrimmedMeanRule} from "../src/rules/TrimmedMeanRule.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// End-to-end tests proving the verifiable-agent flow:
///   1. Register agent with an onchain rule contract
///   2. Submit raw inputs via attestWithRule
///   3. Attestation contract recomputes value via rule.submit, stores result
///   4. Plain attest() is blocked for rule-bound agents
///   5. attestWithRule() is blocked for non-rule agents
contract AttestationWithRuleTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    MedianRule medianRule;
    TrimmedMeanRule trimRule;

    // v2 rule: feed creator and agent are the same wallet. We have two agents
    // for the rule-vs-plain distinction, each creating their own feed.
    address agent = makeAddr("agent");
    address agentPlain = makeAddr("agentPlain");
    address resolver = makeAddr("resolver");

    bytes32 constant METHODOLOGY = keccak256("ipfs://methodology");
    uint256 constant DISPUTE_WINDOW = 1 days;
    uint256 constant MIN_BOND = 100e6;

    bytes32 feedId;       // created by `agent`, used for rule-bound flow
    bytes32 feedIdPlain;  // created by `agentPlain`, used for plain flow

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        medianRule = new MedianRule();
        trimRule = new TrimmedMeanRule(1000); // 10% trim per tail

        usdc.mint(agent, 1_000e6);
        usdc.mint(agentPlain, 1_000e6);

        vm.prank(agent);
        feedId = registry.createFeed(
            "Test feed", METHODOLOGY, MIN_BOND, DISPUTE_WINDOW, resolver
        );
        vm.prank(agentPlain);
        feedIdPlain = registry.createFeed(
            "Test feed plain", METHODOLOGY, MIN_BOND, DISPUTE_WINDOW, resolver
        );
    }

    function test_registerAgentWithRule_storesRule() public {
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgentWithRule(feedId, METHODOLOGY, MIN_BOND, address(medianRule));
        vm.stopPrank();

        assertEq(registry.ruleOf(feedId, agent), address(medianRule));
    }

    function test_attestWithRule_recordsRuleOutput() public {
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgentWithRule(feedId, METHODOLOGY, MIN_BOND, address(medianRule));

        int256[] memory raw = new int256[](5);
        raw[0] = 100; raw[1] = 50; raw[2] = 200; raw[3] = 75; raw[4] = 150;
        // Sorted: [50, 75, 100, 150, 200] → median = 100
        bytes32 attId = attestation.attestWithRule(feedId, raw);
        vm.stopPrank();

        (int256 value, , bool finalized) = attestation.latestValue(feedId, agent);
        assertEq(value, 100);
        // Not finalized until dispute window passes.
        assertFalse(finalized);

        // inputHash should equal keccak256(abi.encode(rawInputs)) — re-derivable
        // by anyone watching events, which is what makes the system verifiable.
        Attestation.AttestationData memory att = attestation.getAttestation(attId);
        assertEq(att.inputHash, keccak256(abi.encode(raw)));
        assertEq(att.value, 100);
    }

    function test_attestWithRule_trimmedMean() public {
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgentWithRule(feedId, METHODOLOGY, MIN_BOND, address(trimRule));

        int256[] memory raw = new int256[](10);
        raw[0] = 1; raw[1] = 100; raw[2] = 100; raw[3] = 100; raw[4] = 100;
        raw[5] = 100; raw[6] = 100; raw[7] = 100; raw[8] = 100; raw[9] = 9999;
        attestation.attestWithRule(feedId, raw);
        vm.stopPrank();

        (int256 value, , ) = attestation.latestValue(feedId, agent);
        // After 10% trim per tail: drop 1 and 9999, mean of 8 hundreds = 100.
        assertEq(value, 100);
    }

    function test_plainAttest_blockedForRuleAgent() public {
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgentWithRule(feedId, METHODOLOGY, MIN_BOND, address(medianRule));

        vm.expectRevert(Attestation.AgentHasRule.selector);
        attestation.attest(feedId, 999, bytes32(0));
        vm.stopPrank();
    }

    function test_attestWithRule_blockedForPlainAgent() public {
        vm.startPrank(agentPlain);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgent(feedIdPlain, METHODOLOGY, MIN_BOND);

        int256[] memory raw = new int256[](3);
        raw[0] = 1; raw[1] = 2; raw[2] = 3;
        vm.expectRevert(Attestation.AgentHasNoRule.selector);
        attestation.attestWithRule(feedIdPlain, raw);
        vm.stopPrank();
    }

    function test_plainAttest_stillWorksForPlainAgent() public {
        vm.startPrank(agentPlain);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgent(feedIdPlain, METHODOLOGY, MIN_BOND);
        attestation.attest(feedIdPlain, 17500, keccak256("inputs"));
        vm.stopPrank();

        (int256 value, , ) = attestation.latestValue(feedIdPlain, agentPlain);
        assertEq(value, 17500);
    }

    function test_registerAgentWithRule_rejectsZeroRule() public {
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        vm.expectRevert(Registry.NotAuthorized.selector);
        registry.registerAgentWithRule(feedId, METHODOLOGY, MIN_BOND, address(0));
        vm.stopPrank();
    }
}
