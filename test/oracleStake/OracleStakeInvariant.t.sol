// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {OracleStake} from "../../src/oraclestake/OracleStake.sol";

/// @notice Drives randomized stake/deploy/withdraw/attest/slash/exit/skim
/// sequences against OracleStake. The handler is also the feeds' neutral
/// resolver, so it can run real Registry slashes to completion.
contract Handler is Test {
    OracleStake public os;
    Registry public registry;
    Dispute public dispute;
    MockUSDC public usdc;

    address[3] public actors = [address(0xA11), address(0xA22), address(0xA33)];
    mapping(address => bool) approved;
    bytes32[] public feeds;
    mapping(bytes32 => address) public feedOwner;
    uint256 public nonce;

    constructor(OracleStake _os, Registry _r, Dispute _d, MockUSDC _u) {
        os = _os; registry = _r; dispute = _d; usdc = _u;
        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(dispute), type(uint256).max);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _prep(address a) internal {
        if (!approved[a]) {
            usdc.mint(a, 100_000_000e6);
            vm.prank(a);
            usdc.approve(address(os), type(uint256).max);
            approved[a] = true;
        }
    }

    function stake(uint256 actorSeed, uint256 amt) external {
        address a = _actor(actorSeed);
        _prep(a);
        amt = bound(amt, 1e6, 20_000e6);
        vm.prank(a);
        os.stake(amt);
    }

    function withdraw(uint256 actorSeed, uint256 amt) external {
        address a = _actor(actorSeed);
        amt = bound(amt, 1, 30_000e6);
        vm.prank(a);
        try os.withdraw(amt) {} catch {}
    }

    function deploy(uint256 actorSeed, uint256 minBondSeed) external {
        address a = _actor(actorSeed);
        _prep(a);
        uint256 minBond = bound(minBondSeed, 10e6, 60e6);
        string memory desc = string.concat("f-", vm.toString(nonce++));
        vm.prank(a);
        try os.deployFeed(desc, keccak256(bytes(desc)), minBond, 1 hours) returns (bytes32 fid) {
            feeds.push(fid);
            feedOwner[fid] = a;
        } catch {}
    }

    function attest(uint256 feedSeed, int256 val) external {
        if (feeds.length == 0) return;
        bytes32 fid = feeds[feedSeed % feeds.length];
        vm.prank(feedOwner[fid]);
        try os.attest(fid, val, bytes32("ih")) {} catch {}
    }

    function slash(uint256 feedSeed) external {
        if (feeds.length == 0) return;
        bytes32 fid = feeds[feedSeed % feeds.length];
        address owner = feedOwner[fid];
        vm.prank(owner);
        try os.attest(fid, int256(1), bytes32("ih")) returns (bytes32 attId) {
            try dispute.challenge(attId, bytes32("ev")) returns (bytes32 dId) {
                // handler is the neutral resolver for these feeds
                try dispute.resolve(dId, Dispute.DisputeOutcome.AttestationInvalid) {
                    os.syncFeed(fid);
                } catch {}
            } catch {}
        } catch {}
    }

    function exit(uint256 feedSeed) external {
        if (feeds.length == 0) return;
        bytes32 fid = feeds[feedSeed % feeds.length];
        vm.prank(feedOwner[fid]);
        try os.exitFeed(fid) {} catch {}
    }

    function skim() external {
        try os.skimFees() {} catch {}
    }

    function skipTime(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 9 days));
    }

    function actorCount() external pure returns (uint256) { return 3; }
}

contract OracleStakeInvariantTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    OracleStake os;
    Handler handler;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        // neutralResolver/feeSink are placeholders until the handler exists;
        // set the resolver to the handler BEFORE any feed is deployed so every
        // feed snapshots the handler as its resolver.
        os = new OracleStake(usdc, registry, attestation, address(this), address(0xBEEF), address(0xFEE));
        OracleStake.Tier[] memory t = new OracleStake.Tier[](3);
        t[0] = OracleStake.Tier({minStake: 125e6, maxOracles: 5});
        t[1] = OracleStake.Tier({minStake: 1000e6, maxOracles: 20});
        t[2] = OracleStake.Tier({minStake: 5000e6, maxOracles: 100});
        os.setTiers(t);

        handler = new Handler(os, registry, dispute, usdc);
        os.setNeutralResolver(address(handler));

        targetContract(address(handler));
    }

    /// Free USDC owed to deployers is always physically present.
    function invariant_solvency() public view {
        assertLe(
            os.accountedDeposits() - os.accountedBonded(),
            usdc.balanceOf(address(os)),
            "free owed exceeds balance"
        );
    }

    /// Per-actor: gross deposit never less than what is locked in the Registry.
    function invariant_perActorBacking() public view {
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actors(i);
            assertGe(os.depositOf(a), os.bondedOf(a) + os.strandedOf(a), "deposit < registry-held");
        }
    }

    /// Global ghost sums match the per-actor ledger (no orphaned accounting).
    function invariant_ghostSums() public view {
        uint256 sumDep;
        uint256 sumBondStrand;
        for (uint256 i = 0; i < 3; i++) {
            address a = handler.actors(i);
            sumDep += os.depositOf(a);
            sumBondStrand += os.bondedOf(a) + os.strandedOf(a);
        }
        assertEq(sumDep, os.accountedDeposits(), "accountedDeposits drift");
        assertEq(sumBondStrand, os.accountedBonded(), "accountedBonded drift");
    }
}
