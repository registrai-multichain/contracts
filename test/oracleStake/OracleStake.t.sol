// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {Markets} from "../../src/Markets.sol";
import {OracleStake} from "../../src/oraclestake/OracleStake.sol";

/// @notice OracleStake unit + integration tests. Mirrors the rigor of the
/// suffix suite: tier quota, per-feed bond isolation, self-slash penalty,
/// decoupled per-feed gating, exit-window gate, donation-cannot-inflate,
/// and a full market-consumability end-to-end (markets resolve against
/// agent = OracleStake with zero deployed-contract changes).
contract OracleStakeTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    Markets markets;
    OracleStake os;

    address admin = address(this);
    address resolver = address(0xBEEF);
    address feeSink = address(0xFEE);
    address dev = address(0xD1);
    address dev2 = address(0xD2);
    address challenger = address(0xC4A);
    address trader = address(0x713A);

    uint256 constant FLOOR = 20e6;
    uint256 constant MIN_BOND = 10e6;
    uint256 constant DW = 1 hours;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        markets = new Markets(attestation, registry, usdc, address(0xABCD));
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        os = new OracleStake(usdc, registry, attestation, admin, resolver, feeSink);

        OracleStake.Tier[] memory t = new OracleStake.Tier[](3);
        t[0] = OracleStake.Tier({minStake: 125e6, maxOracles: 5});
        t[1] = OracleStake.Tier({minStake: 1000e6, maxOracles: 20});
        t[2] = OracleStake.Tier({minStake: 5000e6, maxOracles: 100});
        os.setTiers(t);

        usdc.mint(dev, 1_000_000e6);
        usdc.mint(dev2, 1_000_000e6);
        usdc.mint(challenger, 1_000_000e6);
        usdc.mint(trader, 1_000_000e6);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _stake(address who, uint256 amt) internal {
        vm.startPrank(who);
        usdc.approve(address(os), type(uint256).max);
        os.stake(amt);
        vm.stopPrank();
    }

    function _deploy(address who, string memory desc) internal returns (bytes32 feedId) {
        vm.prank(who);
        feedId = os.deployFeed(desc, keccak256(bytes(desc)), MIN_BOND, DW);
    }

    function _attest(address who, bytes32 feedId, int256 val) internal returns (bytes32 id) {
        vm.prank(who);
        id = os.attest(feedId, val, bytes32("ih"));
    }

    /// Drive a real Registry slash of `feedId` to completion, then reconcile.
    function _slashFeed(bytes32 feedId, address owner) internal {
        bytes32 attId = _attest(owner, feedId, int256(1));
        vm.startPrank(challenger);
        usdc.approve(address(dispute), type(uint256).max);
        bytes32 dId = dispute.challenge(attId, bytes32("ev"));
        vm.stopPrank();
        vm.prank(resolver);
        dispute.resolve(dId, Dispute.DisputeOutcome.AttestationInvalid);
        os.syncFeed(feedId);
    }

    function _solvent() internal view {
        // Free USDC owed to deployers must be physically present.
        assertLe(os.accountedDeposits() - os.accountedBonded(), usdc.balanceOf(address(os)), "insolvent");
    }

    // ───────────────────────── stake / tiers ─────────────────────────

    function test_stake_recordsDepositAndQuota() public {
        assertEq(os.quotaOf(dev), 0);
        _stake(dev, 125e6);
        assertEq(os.depositOf(dev), 125e6);
        assertEq(os.accountedDeposits(), 125e6);
        assertEq(os.quotaOf(dev), 5);
        _solvent();
    }

    function test_quota_tierBoundaries() public {
        _stake(dev, 124e6);
        assertEq(os.quotaOf(dev), 0, "below starter");
        _stake(dev, 1e6); // 125
        assertEq(os.quotaOf(dev), 5, "starter");
        _stake(dev, 875e6); // 1000
        assertEq(os.quotaOf(dev), 20, "builder");
        _stake(dev, 4000e6); // 5000
        assertEq(os.quotaOf(dev), 100, "pro");
    }

    function test_stake_zeroReverts() public {
        vm.startPrank(dev);
        usdc.approve(address(os), type(uint256).max);
        vm.expectRevert(OracleStake.ZeroAmount.selector);
        os.stake(0);
        vm.stopPrank();
    }

    // ───────────────────────── deploy ─────────────────────────

    function test_deploy_registersRealBond() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "btc-price");

        assertEq(os.ownerOf(feedId), dev);
        assertEq(os.bondedOf(dev), FLOOR);
        assertEq(os.accountedBonded(), FLOOR);
        assertEq(os.activeOf(dev), 1);
        assertEq(os.lastReserved(feedId), FLOOR);
        // The bond is a REAL per-(feedId, OracleStake) Registry bond.
        Registry.Agent memory a = registry.getAgent(feedId, address(os));
        assertEq(a.bond, FLOOR);
        assertTrue(registry.isActiveAgent(feedId, address(os)));
        // Resolver is forced to the neutral resolver, never the deployer.
        assertEq(registry.getFeed(feedId).resolver, resolver);
        _solvent();
    }

    function test_deploy_belowTierReverts() public {
        _stake(dev, 50e6); // quota 0
        vm.prank(dev);
        vm.expectRevert(OracleStake.QuotaExceeded.selector);
        os.deployFeed("x", keccak256("x"), MIN_BOND, DW);
    }

    function test_deploy_quotaExceeded() public {
        _stake(dev, 125e6); // quota 5
        for (uint256 i = 0; i < 5; i++) {
            _deploy(dev, string.concat("feed-", vm.toString(i)));
        }
        vm.prank(dev);
        vm.expectRevert(OracleStake.QuotaExceeded.selector);
        os.deployFeed("feed-overflow", keccak256("of"), MIN_BOND, DW);
    }

    function test_deploy_floorBreachWhenFreeTooLow() public {
        // Big per-feed minBond (30) so free runs out before quota does.
        _stake(dev, 125e6); // quota 5
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(dev);
            os.deployFeed(string.concat("hi-", vm.toString(i)), keccak256("h"), 30e6, DW);
        }
        // 4 * 30 = 120 bonded, free = 5 < 30 floor, but quota (5) still allows.
        assertEq(os.freeOf(dev), 5e6);
        vm.prank(dev);
        vm.expectRevert(OracleStake.FloorBreach.selector);
        os.deployFeed("hi-5", keccak256("h5"), 30e6, DW);
    }

    // ───────────────────────── attest ─────────────────────────

    function test_attest_relayedUnderOracleStakeAgent() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "eth-price");
        bytes32 id = _attest(dev, feedId, int256(4200));

        Attestation.AttestationData memory att = attestation.getAttestation(id);
        assertEq(att.agent, address(os), "agent of record is OracleStake");
        assertEq(att.value, int256(4200));
        (int256 v,) = attestation.valueAt(feedId, address(os), block.timestamp);
        assertEq(v, int256(4200));
    }

    function test_attest_onlyOwnerOrDelegate() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        vm.prank(dev2);
        vm.expectRevert(OracleStake.NotOwnerOrDelegate.selector);
        os.attest(feedId, int256(1), bytes32("ih"));

        vm.prank(dev);
        os.setDelegate(dev2);
        vm.prank(dev2);
        os.attest(feedId, int256(7), bytes32("ih")); // delegate works now
    }

    function test_attest_unknownFeedReverts() public {
        vm.prank(dev);
        vm.expectRevert(OracleStake.NotLiveFeed.selector);
        os.attest(bytes32("nope"), int256(1), bytes32("ih"));
    }

    function test_attest_blockedWhileBondLockedInDispute() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        bytes32 attId = _attest(dev, feedId, int256(1));
        // open a dispute → bond is locked → feed is under-backed for attest
        vm.startPrank(challenger);
        usdc.approve(address(dispute), type(uint256).max);
        dispute.challenge(attId, bytes32("ev"));
        vm.stopPrank();

        vm.prank(dev);
        vm.expectRevert(OracleStake.FeedUnderBacked.selector);
        os.attest(feedId, int256(2), bytes32("ih"));
    }

    function test_attest_deadFeedReverts() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        _slashFeed(feedId, dev);
        vm.prank(dev);
        vm.expectRevert(OracleStake.FeedIsDead.selector);
        os.attest(feedId, int256(1), bytes32("ih"));
    }

    // ───────────────────────── withdraw ─────────────────────────

    function test_withdraw_onlyFreeUSDC() public {
        _stake(dev, 125e6);
        _deploy(dev, "feed"); // bonded 20, free 105
        assertEq(os.freeOf(dev), 105e6);

        uint256 balBefore = usdc.balanceOf(dev);
        vm.prank(dev);
        os.withdraw(105e6);
        assertEq(usdc.balanceOf(dev) - balBefore, 105e6);
        assertEq(os.freeOf(dev), 0);
        _solvent();
    }

    function test_withdraw_cannotTakeBonded() public {
        _stake(dev, 125e6);
        _deploy(dev, "feed"); // bonded 20, free 105
        vm.prank(dev);
        vm.expectRevert(OracleStake.FloorBreach.selector);
        os.withdraw(106e6);
    }

    // ───────────────────────── slash isolation ─────────────────────────

    function test_slash_isolatedFromSiblingFeeds() public {
        _stake(dev, 125e6);
        bytes32 a = _deploy(dev, "feed-a");
        bytes32 b = _deploy(dev, "feed-b");
        assertEq(os.bondedOf(dev), 2 * FLOOR);

        _slashFeed(a, dev);

        // Feed A dead; feed B's REAL Registry bond is untouched.
        assertTrue(os.feedDead(a));
        assertFalse(os.feedDead(b));
        Registry.Agent memory ab = registry.getAgent(b, address(os));
        assertEq(ab.bond, FLOOR, "sibling bond intact");
        assertTrue(registry.isActiveAgent(b, address(os)));
        // Feed B is still attestable (decoupled per-feed gating).
        _attest(dev, b, int256(99));
        _solvent();
    }

    function test_selfSlash_penaltyMakesItNetNegative() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        uint256 depBefore = os.depositOf(dev);
        uint256 sinkBefore = usdc.balanceOf(feeSink);

        _slashFeed(feedId, dev);

        // lost the 20 bond (to challenger) + 50% penalty (10) routed to feeSink.
        assertEq(os.depositOf(dev), depBefore - FLOOR - 10e6, "deposit debited bond + penalty");
        assertEq(usdc.balanceOf(feeSink) - sinkBefore, 10e6, "penalty to feeSink");
        assertEq(os.activeOf(dev), 0);
        assertEq(os.bondedOf(dev), 0);
        _solvent();
    }

    function test_slash_reconcileIdempotent() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        _slashFeed(feedId, dev);
        uint256 dep = os.depositOf(dev);
        // calling sync again must not double-charge
        os.syncFeed(feedId);
        os.syncFeed(feedId);
        assertEq(os.depositOf(dev), dep);
        _solvent();
    }

    // ───────────────────────── exit ─────────────────────────

    function test_exitFeed_blockedDuringOpenWindow() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        _attest(dev, feedId, int256(1)); // opens dispute window
        vm.prank(dev);
        vm.expectRevert(OracleStake.CooldownOrWindowOpen.selector);
        os.exitFeed(feedId);
    }

    function test_exitFeed_blockedByRegistryCooldown() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        // no attestation → no dispute window, but Registry's 7-day cooldown
        // (anchored at registration) still applies on withdrawBond.
        vm.prank(dev);
        vm.expectRevert(Registry.CooldownActive.selector);
        os.exitFeed(feedId);
    }

    function test_exitFeed_succeedsAfterCooldown_reclaimsBond() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        vm.warp(block.timestamp + 8 days); // past registry cooldown, no open dispute

        uint256 freeBefore = os.freeOf(dev);
        vm.prank(dev);
        os.exitFeed(feedId);

        assertTrue(os.feedExited(feedId));
        assertEq(os.activeOf(dev), 0);
        assertEq(os.bondedOf(dev), 0);
        // reclaimed bond becomes free again (deposit is gross, unchanged).
        assertEq(os.freeOf(dev), freeBefore + FLOOR);
        _solvent();
    }

    function test_exitFeed_notOwnerReverts() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        vm.prank(dev2);
        vm.expectRevert(OracleStake.NotOwner.selector);
        os.exitFeed(feedId);
    }

    /// Capital + structural ops (topUp/exit) are OWNER-ONLY by design; a
    /// delegate may attest but never controls the bond. (audit finding fix)
    function test_delegate_cannotTopUpOrExit() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        vm.prank(dev);
        os.setDelegate(dev2);

        // delegate CAN attest
        vm.prank(dev2);
        os.attest(feedId, int256(1), bytes32("ih"));

        // but delegate CANNOT top up the bond...
        vm.startPrank(dev2);
        usdc.approve(address(os), type(uint256).max);
        vm.expectRevert(OracleStake.NotOwner.selector);
        os.topUpFeed(feedId, 5e6);
        vm.stopPrank();

        // ...nor tear down the feed.
        vm.warp(block.timestamp + 8 days);
        vm.prank(dev2);
        vm.expectRevert(OracleStake.NotOwner.selector);
        os.exitFeed(feedId);
    }

    // ───────────────────────── topUpFeed ─────────────────────────

    function test_topUpFeed_recoversAndGrowsBond() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "feed");
        vm.startPrank(dev);
        usdc.approve(address(os), type(uint256).max);
        os.topUpFeed(feedId, 15e6);
        vm.stopPrank();

        assertEq(os.lastReserved(feedId), FLOOR + 15e6);
        assertEq(registry.getAgent(feedId, address(os)).bond, FLOOR + 15e6);
        assertEq(os.bondedOf(dev), FLOOR + 15e6);
        _solvent();
    }

    // ───────────────────────── donation / fees ─────────────────────────

    function test_donationCannotInflateDeposit_skimRoutesToSink() public {
        _stake(dev, 125e6);
        _deploy(dev, "feed");
        uint256 depBefore = os.depositOf(dev);

        // Attacker donates raw USDC directly to the contract.
        vm.prank(challenger);
        usdc.transfer(address(os), 500e6);

        // No deposit inflation: ledger reads are internal accounting only.
        assertEq(os.depositOf(dev), depBefore);
        assertEq(os.freeOf(dev), depBefore - FLOOR);

        // The donation is skimmable to feeSink and nowhere else.
        uint256 sinkBefore = usdc.balanceOf(feeSink);
        os.skimFees();
        assertEq(usdc.balanceOf(feeSink) - sinkBefore, 500e6);
        _solvent();
    }

    function test_skim_nothingToSkimReverts() public {
        _stake(dev, 125e6);
        vm.expectRevert(OracleStake.ZeroAmount.selector);
        os.skimFees();
    }

    // ───────────────────────── governance gates ─────────────────────────

    function test_setTiers_rejectsNonAscending() public {
        OracleStake.Tier[] memory t = new OracleStake.Tier[](2);
        t[0] = OracleStake.Tier({minStake: 1000e6, maxOracles: 5});
        t[1] = OracleStake.Tier({minStake: 1000e6, maxOracles: 6}); // not strictly ascending
        vm.expectRevert(OracleStake.BadTierTable.selector);
        os.setTiers(t);
    }

    function test_setTiers_rejectsNoHeadroom() public {
        OracleStake.Tier[] memory t = new OracleStake.Tier[](1);
        // 100 <= 5 * 20e6 → exactly the knife-edge the founder floated; rejected.
        t[0] = OracleStake.Tier({minStake: 100e6, maxOracles: 5});
        vm.expectRevert(OracleStake.BadTierTable.selector);
        os.setTiers(t);
    }

    function test_governorOnly() public {
        vm.prank(dev);
        vm.expectRevert();
        os.setFloorConst(50e6);
        vm.prank(dev);
        vm.expectRevert();
        os.setSlashPenaltyBps(1000);
    }

    function test_setFloorConst_belowMinBondReverts() public {
        vm.expectRevert(OracleStake.BadParam.selector);
        os.setFloorConst(9e6);
    }

    // ───────────────────────── rate limit ─────────────────────────

    function test_deployRateLimit() public {
        os.setDeployRateLimit(2, 1 days);
        _stake(dev, 1000e6); // quota 20, plenty of free
        _deploy(dev, "r-0");
        _deploy(dev, "r-1");
        vm.prank(dev);
        vm.expectRevert(OracleStake.DeployRateLimited.selector);
        os.deployFeed("r-2", keccak256("r2"), MIN_BOND, DW);

        vm.warp(block.timestamp + 1 days + 1);
        _deploy(dev, "r-3"); // new epoch, allowed again
    }

    // ───────────────────────── end-to-end market ─────────────────────────

    function test_marketResolvesAgainstOracleStakeFeed() public {
        _stake(dev, 125e6);
        bytes32 feedId = _deploy(dev, "btc-gt-100k");

        // A market maker creates a market consuming agent = OracleStake.
        uint256 expiry = block.timestamp + 2 hours;
        vm.startPrank(trader);
        usdc.approve(address(markets), type(uint256).max);
        bytes32 marketId = markets.createMarket(
            feedId, address(os), int256(100_000), Markets.Comparator.GreaterOrEqual, expiry, 50e6
        );
        vm.stopPrank();

        // OracleStake (via the deployer) attests the truth before expiry.
        _attest(dev, feedId, int256(123_456));

        // Past expiry and past the dispute window → market resolves.
        vm.warp(expiry + DW + 1);
        markets.resolve(marketId);
        // YES wins (123456 >= 100000); no revert == feed was consumable.
        assertTrue(true);
        _solvent();
    }
}
