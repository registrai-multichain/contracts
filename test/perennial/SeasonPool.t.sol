// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {MerkleKit} from "./MerkleKit.sol";

/// SeasonPool: funded by the BuilderFund (the test contract plays it, FUNDER),
/// seasons published by the Safe (the test contract, GOVERNOR) as merkle roots,
/// claimed by builders against a proof, capped at 20% of the season per builder.
contract SeasonPoolTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    SeasonPool pool;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");
    uint256 aliceId;
    uint256 bobId;
    uint256 carolId;

    uint256 constant U = 1e6;
    uint256 constant S1 = 1;
    uint256 constant TOTAL = 1_000 * U; // cap = 200
    uint64 deadline;

    // the season-1 tree: alice at the cap, bob under it, carol above it
    bytes32[] leaves;
    uint256[3] amounts = [uint256(200 * U), 150 * U, 250 * U];

    event Funded(address indexed funder, uint256 amount, uint256 unallocated);
    event SeasonPublished(uint256 indexed seasonId, bytes32 root, uint256 total, uint64 deadline);
    event SeasonClaimed(uint256 indexed seasonId, uint256 indexed builderId, uint256 amount, address payout);
    event SeasonReclaimed(uint256 indexed seasonId, uint256 amount);

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        vm.prank(alice);
        (aliceId,) = builders.registerBuilderWithProject("", "github:alice/app");
        vm.prank(bob);
        (bobId,) = builders.registerBuilderWithProject("", "domain:bob.xyz");
        vm.prank(carol);
        (carolId,) = builders.registerBuilderWithProject("", "github:carol/lib");
        pool = new SeasonPool(ledger, builders, caretakers, address(this));
        pool.grantRole(pool.FUNDER_ROLE(), address(this));

        usdc.mint(address(this), 1_000_000 * U);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000_000 * U);

        deadline = uint64(block.timestamp + 30 days);
        leaves.push(pool.leafOf(S1, aliceId, amounts[0]));
        leaves.push(pool.leafOf(S1, bobId, amounts[1]));
        leaves.push(pool.leafOf(S1, carolId, amounts[2]));
    }

    function _fund(uint256 amount) internal {
        ledger.internalTransfer(address(pool), amount);
        pool.fund(amount);
    }

    function _publish() internal {
        _fund(TOTAL);
        pool.publishSeason(S1, MerkleKit.root(leaves), TOTAL, deadline);
    }

    function _claim(uint256 i) internal returns (uint256) {
        uint256[3] memory ids = [aliceId, bobId, carolId];
        return pool.claim(S1, ids[i], amounts[i], MerkleKit.proof(leaves, i));
    }

    function _accounted() internal view {
        assertGe(ledger.balanceOf(address(pool)), pool.unallocated() + pool.reserved(), "pool below accounted");
    }

    // ───────────────────────────── funding ─────────────────────────────

    function test_fund_onlyFunder_andMustBeFunded() public {
        bytes32 role = pool.FUNDER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        pool.fund(1);
        vm.expectRevert(SeasonPool.Unfunded.selector);
        pool.fund(1); // nothing was transferred
        vm.expectRevert(SeasonPool.ZeroAmount.selector);
        pool.fund(0);
        ledger.internalTransfer(address(pool), 5 * U);
        vm.expectEmit(address(pool));
        emit Funded(address(this), 5 * U, 5 * U);
        pool.fund(5 * U);
        assertEq(pool.unallocated(), 5 * U);
    }

    function test_sync_absorbsDonationsOnly() public {
        vm.expectRevert(SeasonPool.NothingToSync.selector);
        pool.sync();
        _fund(10 * U);
        ledger.internalTransfer(address(pool), 3 * U); // a donation, not accounted
        vm.prank(stranger);
        assertEq(pool.sync(), 3 * U);
        assertEq(pool.unallocated(), 13 * U);
        vm.expectRevert(SeasonPool.NothingToSync.selector);
        pool.sync();
    }

    // ───────────────────────────── publish ─────────────────────────────

    /// Audit 2026-09-27 I-3: a deadline typo (ms instead of s, or max) would lock
    /// the season's allocation for ever; at most MAX_SEASON_LENGTH (365 days) ahead.
    function test_publish_deadlineAtMostAYearAhead() public {
        _fund(TOTAL);
        bytes32 root = MerkleKit.root(leaves);
        uint256 max = pool.MAX_SEASON_LENGTH();
        assertEq(max, 365 days);
        uint64 now_ = uint64(vm.getBlockTimestamp());
        vm.expectRevert(SeasonPool.BadDeadline.selector);
        pool.publishSeason(S1, root, TOTAL, type(uint64).max);
        vm.expectRevert(SeasonPool.BadDeadline.selector);
        pool.publishSeason(S1, root, TOTAL, now_ + uint64(max) + 1);
        pool.publishSeason(S1, root, TOTAL, now_ + uint64(max));
    }

    function test_publish_boundedByUnallocated() public {
        _fund(TOTAL - 1);
        bytes32 root = MerkleKit.root(leaves);
        vm.expectRevert(SeasonPool.InsufficientUnallocated.selector);
        pool.publishSeason(S1, root, TOTAL, deadline);
        _fund(1);
        vm.expectEmit(address(pool));
        emit SeasonPublished(S1, root, TOTAL, deadline);
        pool.publishSeason(S1, root, TOTAL, deadline); // exactly the unallocated balance
        assertEq(pool.unallocated(), 0);
        assertEq(pool.reserved(), TOTAL);
        (bytes32 r, uint256 t, uint256 c, uint64 d, bool re) = pool.seasons(S1);
        assertEq(r, root);
        assertEq(t, TOTAL);
        assertEq(c, 0);
        assertEq(d, deadline);
        assertFalse(re);
        assertEq(pool.capOf(S1), 200 * U);
        _accounted();

        _fund(TOTAL);
        vm.expectRevert(SeasonPool.SeasonExists.selector);
        pool.publishSeason(S1, root, 1, deadline);
    }

    function test_publish_refusals() public {
        _fund(TOTAL);
        bytes32 root = MerkleKit.root(leaves);
        vm.expectRevert(SeasonPool.BadDeadline.selector);
        pool.publishSeason(2, root, 1, uint64(block.timestamp));
        vm.expectRevert(SeasonPool.BadSeason.selector);
        pool.publishSeason(2, bytes32(0), 1, deadline);
        vm.expectRevert(SeasonPool.BadSeason.selector);
        pool.publishSeason(2, root, 0, deadline);
        bytes32 gov = pool.GOVERNOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, gov));
        pool.publishSeason(2, root, 1, deadline);
    }

    // ───────────────────────────── claim ─────────────────────────────

    function test_merkle_threeLeafTree_claims() public {
        // the tree is built here, from the documented leaf encoding
        bytes32 l0 = keccak256(bytes.concat(keccak256(abi.encode(S1, aliceId, amounts[0]))));
        assertEq(leaves[0], l0, "leaf = OZ double hash of abi.encode(seasonId, builderId, amount)");
        bytes32 root = MerkleKit.hashPair(MerkleKit.hashPair(leaves[0], leaves[1]), leaves[2]);
        assertEq(MerkleKit.root(leaves), root);
        assertEq(MerkleKit.proof(leaves, 2).length, 1);
        _publish();

        address cold = makeAddr("bobCold");
        vm.prank(bob);
        caretakers.setPayout(bobId, cold);

        vm.expectEmit(address(pool));
        emit SeasonClaimed(S1, aliceId, 200 * U, alice);
        vm.prank(stranger); // anyone may claim for the builder
        assertEq(_claim(0), 200 * U, "exactly at the 20% cap");
        assertEq(ledger.balanceOf(alice), 200 * U);
        assertEq(ledger.balanceOf(stranger), 0);
        _claim(1);
        assertEq(ledger.balanceOf(cold), 150 * U, "paid to payoutOf");
        assertTrue(pool.claimed(S1, aliceId) && pool.claimed(S1, bobId));
        (,, uint256 c,,) = pool.seasons(S1);
        assertEq(c, 350 * U);
        assertEq(pool.reserved(), 650 * U);
        _accounted();
    }

    function test_claim_cap20Percent() public {
        _publish();
        vm.expectRevert(SeasonPool.AboveCap.selector);
        _claim(2); // carol's leaf says 250 of 1,000: in the tree, refused on-chain
    }

    function test_claim_refusals() public {
        _publish();
        bytes32[] memory p0 = MerkleKit.proof(leaves, 0);
        vm.expectRevert(SeasonPool.UnknownSeason.selector);
        pool.claim(2, aliceId, amounts[0], p0);
        vm.expectRevert(SeasonPool.InvalidProof.selector);
        pool.claim(S1, aliceId, amounts[0] - 1, p0); // wrong amount
        vm.expectRevert(SeasonPool.InvalidProof.selector);
        pool.claim(S1, bobId, amounts[0], p0); // someone else's leaf
        vm.expectRevert(SeasonPool.ZeroAmount.selector);
        pool.claim(S1, aliceId, 0, p0);

        _claim(0);
        vm.expectRevert(SeasonPool.AlreadyClaimed.selector);
        _claim(0);
    }

    function test_claim_inactiveBuilderRefused() public {
        _publish();
        builders.setActive(bobId, false);
        vm.expectRevert(SeasonPool.BuilderInactive.selector);
        _claim(1);
        builders.setActive(bobId, true);
        _claim(1);
    }

    function test_claim_deadline() public {
        _publish();
        vm.warp(deadline); // the deadline itself is still open
        _claim(0);
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(SeasonPool.SeasonClosed.selector);
        _claim(1);
    }

    function test_claim_ownerChangeFallback() public {
        _publish();
        vm.prank(alice);
        caretakers.setPayout(aliceId, makeAddr("aliceOld"));
        vm.prank(alice);
        builders.proposeOwner(makeAddr("aliceNew"));
        vm.prank(makeAddr("aliceNew"));
        builders.acceptOwnership(aliceId);
        _claim(0);
        assertEq(ledger.balanceOf(makeAddr("aliceNew")), 200 * U);
        assertEq(ledger.balanceOf(makeAddr("aliceOld")), 0);
    }

    /// A root that over-allocates cannot pay more than the season total.
    function test_claim_overAllocatedRoot_boundedByTotal() public {
        uint256 total = 100 * U; // cap 20
        bytes32[] memory ls = new bytes32[](6);
        uint256[] memory ids = new uint256[](6);
        for (uint256 i; i < 6; i++) {
            address b = makeAddr(string.concat("b", vm.toString(i)));
            vm.prank(b);
            (ids[i],) = builders.registerBuilderWithProject("", "github:x/y");
            ls[i] = pool.leafOf(7, ids[i], 20 * U);
        }
        _fund(total);
        pool.publishSeason(7, MerkleKit.root(ls), total, deadline);
        for (uint256 i; i < 5; i++) {
            pool.claim(7, ids[i], 20 * U, MerkleKit.proof(ls, i));
        }
        bytes32[] memory p5 = MerkleKit.proof(ls, 5);
        vm.expectRevert(SeasonPool.ExceedsSeason.selector);
        pool.claim(7, ids[5], 20 * U, p5);
        assertEq(pool.reserved(), 0);
        _accounted();
    }

    // ───────────────────────────── reclaim ─────────────────────────────

    function test_reclaim_afterDeadline_restToUnallocated() public {
        _publish();
        _claim(0);
        vm.expectRevert(SeasonPool.SeasonOpen.selector);
        pool.reclaim(S1);
        vm.warp(uint256(deadline) + 1);
        bytes32 gov = pool.GOVERNOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, gov));
        pool.reclaim(S1);
        vm.expectEmit(address(pool));
        emit SeasonReclaimed(S1, 800 * U);
        assertEq(pool.reclaim(S1), 800 * U);
        assertEq(pool.unallocated(), 800 * U);
        assertEq(pool.reserved(), 0);
        vm.expectRevert(SeasonPool.AlreadyReclaimed.selector);
        pool.reclaim(S1);
        vm.expectRevert(SeasonPool.UnknownSeason.selector);
        pool.reclaim(9);

        // the reclaimed rest funds the next season
        pool.publishSeason(2, MerkleKit.root(leaves), 800 * U, uint64(block.timestamp + 1 days));
        assertEq(pool.unallocated(), 0);
        _accounted();
    }
}
