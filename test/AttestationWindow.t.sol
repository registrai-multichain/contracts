// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";

/// firstInWindow: the settlement read. First non-invalidated attestation stamped
/// in [from, to], found by binary search on the append-only history.
contract AttestationWindowTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;

    address agent = address(0xA1);
    address resolver = address(0xBEEF);
    address challenger = address(0xC4A1);
    bytes32 feedId;
    uint256 constant DW = 1 hours;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        usdc.mint(agent, 10_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("f", keccak256("m"), 10e6, DW, resolver);
        // Bonded well above the minimum so it can keep attesting after a challenge
        // locks part of its bond.
        registry.registerAgent(feedId, keccak256("m"), 1_000e6);
        vm.stopPrank();
        usdc.mint(challenger, 10_000e6);
    }

    function _attest(int256 v) internal returns (bytes32 id) {
        vm.prank(agent);
        id = attestation.attest(feedId, v, keccak256(abi.encode(v, block.timestamp)));
    }

    function _invalidate(bytes32 attId) internal {
        Registry.Agent memory a = registry.getAgent(feedId, agent);
        vm.startPrank(challenger);
        usdc.approve(address(dispute), a.bond - a.lockedBond);
        bytes32 d = dispute.challenge(attId, keccak256("wrong"));
        vm.stopPrank();
        vm.prank(resolver);
        dispute.resolve(d, Dispute.DisputeOutcome.AttestationInvalid);
    }

    function test_emptyHistory_notFound() public view {
        (bool found,,,) = attestation.firstInWindow(feedId, agent, 0, type(uint256).max);
        assertFalse(found);
    }

    function test_returnsTheAttestationInsideTheWindow() public {
        vm.warp(1_000);
        _attest(42);
        (bool found, int256 v, uint256 ts,) = attestation.firstInWindow(feedId, agent, 900, 1_100);
        assertTrue(found);
        assertEq(v, 42);
        assertEq(ts, 1_000);
    }

    function test_ignoresAttestationsBeforeAndAfterTheWindow() public {
        vm.warp(100);
        _attest(1); // before
        vm.warp(2_000);
        _attest(3); // after
        (bool found,,,) = attestation.firstInWindow(feedId, agent, 500, 1_500);
        assertFalse(found, "nothing stamped inside [500, 1500]");
    }

    function test_boundariesAreInclusive() public {
        vm.warp(500);
        _attest(7);
        (bool atFrom,,,) = attestation.firstInWindow(feedId, agent, 500, 900);
        (bool atTo,,,) = attestation.firstInWindow(feedId, agent, 100, 500);
        assertTrue(atFrom, "timestamp == from counts");
        assertTrue(atTo, "timestamp == to counts");
    }

    function test_returnsTheFirstNotTheLatest() public {
        vm.warp(1_000);
        _attest(10);
        vm.warp(1_050);
        _attest(20);
        (, int256 v, uint256 ts,) = attestation.firstInWindow(feedId, agent, 900, 2_000);
        assertEq(v, 10, "the agent's first answer is its commitment");
        assertEq(ts, 1_000);
    }

    function test_skipsAnInvalidatedAttestation() public {
        vm.warp(1_000);
        bytes32 wrong = _attest(10);
        vm.warp(1_100);
        _attest(20);
        _invalidate(wrong);
        (bool found, int256 v,,) = attestation.firstInWindow(feedId, agent, 900, 2_000);
        assertTrue(found);
        assertEq(v, 20, "falls through to the next valid answer");
    }

    function test_allInvalidated_notFound() public {
        vm.warp(1_000);
        bytes32 only = _attest(10);
        _invalidate(only);
        (bool found,,,) = attestation.firstInWindow(feedId, agent, 900, 2_000);
        assertFalse(found);
    }

    function test_reportsFinalizationHonestly() public {
        vm.warp(1_000);
        _attest(5);
        (,,, bool early) = attestation.firstInWindow(feedId, agent, 900, 2_000);
        assertFalse(early, "inside the dispute window");
        vm.warp(1_000 + DW);
        (,,, bool late) = attestation.firstInWindow(feedId, agent, 900, 2_000);
        assertTrue(late, "dispute window elapsed unchallenged");
    }

    function test_pendingDisputeIsFoundButNotFinalized() public {
        vm.warp(1_000);
        bytes32 id = _attest(5);
        Registry.Agent memory a = registry.getAgent(feedId, agent);
        vm.startPrank(challenger);
        usdc.approve(address(dispute), a.bond - a.lockedBond);
        dispute.challenge(id, keccak256("e"));
        vm.stopPrank();
        vm.warp(1_000 + 30 days);
        (bool found,,, bool fin) = attestation.firstInWindow(feedId, agent, 900, 2_000);
        assertTrue(found, "still a candidate: the dispute may yet find it valid");
        assertFalse(fin, "never finalizes while the dispute is pending");
    }

    /// The old backwards scan costs O(attestations since the target time). On a
    /// busy feed resolved late that runs out of gas; binary search does not.
    function test_lookupCostDoesNotGrowWithHistoryAfterTheWindow() public {
        vm.warp(10_000);
        _attest(1);
        attestation.firstInWindow(feedId, agent, 9_000, 11_000); // warm the slots
        uint256 g0 = gasleft();
        attestation.firstInWindow(feedId, agent, 9_000, 11_000);
        uint256 small = g0 - gasleft();

        for (uint256 i = 1; i <= 400; i++) {
            vm.warp(10_000 + i * 60);
            _attest(int256(i + 1));
        }
        uint256 g1 = gasleft();
        attestation.firstInWindow(feedId, agent, 9_000, 11_000);
        uint256 big = g1 - gasleft();
        assertLt(big, small * 3, "400 later attestations must not make the lookup linear");
    }

    /// ...and not with history BEFORE it either: a forward linear scan from the
    /// start is the other way to get this wrong, and it bites every market on a
    /// feed that has been running for a long time.
    function test_lookupCostDoesNotGrowWithHistoryBeforeTheWindow() public {
        vm.warp(1_000);
        _attest(1);
        attestation.firstInWindow(feedId, agent, 1_000, 2_000); // warm
        uint256 g0 = gasleft();
        attestation.firstInWindow(feedId, agent, 1_000, 2_000);
        uint256 small = g0 - gasleft();

        for (uint256 i = 1; i <= 400; i++) {
            vm.warp(1_000 + i * 60);
            _attest(int256(i + 1));
        }
        uint256 last = 1_000 + 400 * 60;
        uint256 g1 = gasleft();
        (bool found,,,) = attestation.firstInWindow(feedId, agent, last, last + 1_000);
        uint256 big = g1 - gasleft();
        assertTrue(found);
        assertLt(big, small * 3, "400 earlier attestations must not make the lookup linear");
    }
}
