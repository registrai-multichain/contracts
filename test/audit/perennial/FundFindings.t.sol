// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../../src/perennial/SeasonPool.sol";
import {VerifiedBuilderBadge} from "../../../src/perennial/VerifiedBuilderBadge.sol";
import {WonderEscrow} from "../../../src/perennial/WonderEscrow.sol";
import {SourceKey} from "../../../src/perennial/SourceKey.sol";
import {LaunchSchedule} from "../../../script/lib/LaunchSchedule.sol";

/// Audit (BuilderFund + SeasonPool, phase 2): PoCs and fuzz properties.
/// The test contract is the Safe (every admin role) and plays the markets.
contract FundFindingsTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;
    BuilderRegistry builders;
    CaretakerRegistry caretakers;
    SeasonPool pool;
    BuilderFund fund;
    VerifiedBuilderBadge badge;
    WonderEscrow escrow;

    address treasury = makeAddr("protocolTreasury");
    address alice = makeAddr("alice");
    address releaser = makeAddr("releaser");
    uint256 aliceId;
    uint256 aliceProject;
    uint256 T0;

    uint256 constant EPOCH = 30 days;
    uint256 constant U = 1e6;

    function setUp() public {
        vm.warp(1_800_000_000);
        T0 = block.timestamp;
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        pool = new SeasonPool(ledger, builders, caretakers, address(this));
        fund = new BuilderFund(ledger, builders, caretakers, pool, treasury, address(this), EPOCH, LaunchSchedule.brackets());
        pool.grantRole(pool.FUNDER_ROLE(), address(fund));
        fund.grantRole(fund.MARKETS_ROLE(), address(this));
        badge = new VerifiedBuilderBadge(builders, address(this), address(this), "Local", "", "");
        escrow = new WonderEscrow(ledger, fund, badge, address(this), 180 days);
        fund.grantRole(fund.MARKETS_ROLE(), address(escrow));
        fund.grantRole(fund.LATE_ROLE(), address(escrow)); // releases credit the epochs earned
        escrow.grantRole(escrow.MARKETS_ROLE(), address(this));
        escrow.grantRole(escrow.RELEASER_ROLE(), releaser);

        vm.prank(alice);
        (aliceId, aliceProject) = builders.registerBuilderWithProject("", "github:alice/app");
        badge.issue(aliceId);

        usdc.mint(address(this), 100_000_000 * U);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000_000 * U);
    }

    function _earn(uint256 id, uint256 amount) internal {
        ledger.internalTransfer(address(fund), amount);
        fund.credit(id, amount);
    }

    function _tax(uint256 gross) internal view returns (uint256) {
        return fund.progressiveTax(gross, LaunchSchedule.brackets());
    }

    // ─────────────────────────── L-1: release bunching ───────────────────────────

    /// FIXED L-1 (owner: taxed per epoch earned): six months of a wonder market's
    /// builder leg held in escrow and released at once is credited to the epochs it
    /// was earned in, so it pays exactly the tax of six monthly payments
    /// ($5,400, not the $11,900 of one lump).
    function test_FIXED_L1_releasedEscrowTaxedAsIfPaidMonthly() public {
        string memory src = "github:alice/app";
        bytes32 key = SourceKey.keyOf(src);
        for (uint256 m; m < 6; m++) {
            vm.warp(T0 + m * EPOCH + 1 days);
            ledger.internalTransfer(address(escrow), 10_000 * U);
            escrow.credit(key, 10_000 * U);
        }
        vm.prank(releaser);
        escrow.queueRelease(src, aliceProject);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        escrow.executeRelease(key);
        for (uint256 m; m < 6; m++) {
            assertEq(fund.incomeOf(m, aliceId), 10_000 * U, "each month in its own epoch");
        }
        uint256 poolBefore = ledger.balanceOf(address(pool));
        vm.warp(fund.epochEnd(5));
        for (uint256 m; m < 6; m++) {
            fund.claimFor(m, aliceId);
        }
        uint256 taxSpread = 6 * _tax(10_000 * U);
        assertEq(taxSpread, 5_400 * U);
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, taxSpread, "no extra tax from the release");
    }

    // ─────────────────────────── I-1: schedule notice ───────────────────────────

    /// FIXED I-1: a schedule takes effect from currentEpoch + SCHEDULE_DELAY + 1, so
    /// even one replaced at the last second of an epoch still gives two FULL epochs
    /// of notice; once the next epoch starts it is final.
    function test_FIXED_I1_scheduleAlwaysTwoFullEpochsNotice() public {
        BuilderFund.Bracket[] memory mild = LaunchSchedule.brackets();
        fund.setSchedule(mild); // at the start of epoch 0: for epoch 3
        BuilderFund.Bracket[] memory harsh = new BuilderFund.Bracket[](2);
        harsh[0] = BuilderFund.Bracket(100e6, 0);
        harsh[1] = BuilderFund.Bracket(type(uint128).max, 4000);
        uint256 lastSecond = fund.epochEnd(0) - 1;
        vm.warp(lastSecond);
        fund.setSchedule(harsh); // replaces the pending one, still for epoch 3
        assertEq(fund.scheduleFor(2)[1].rateBps, 1000, "epoch 2 keeps the launch schedule");
        assertEq(fund.scheduleFor(3)[1].rateBps, 4000);
        assertGe(fund.epochEnd(2) - lastSecond, 2 * EPOCH, "binding notice: two full epochs");
        vm.warp(fund.epochEnd(0)); // epoch 1: the epoch-3 schedule is final
        fund.setSchedule(mild);
        assertEq(fund.scheduleFor(3)[1].rateBps, 4000);
        assertEq(fund.scheduleFor(4)[1].rateBps, 1000);
    }

    // ─────────────────────────── I-2: no skim in the fund ───────────────────────────

    /// FIXED I-2: a stray ledger balance in the fund (a donation, or a builder whose
    /// payout is the fund) is no longer stranded: anyone skims what exceeds
    /// `outstanding` to the season pool; builders' income is never touched.
    function test_FIXED_I2_strayBalanceSkimmedToTheSeasonPool() public {
        _earn(aliceId, 1_000 * U);
        vm.prank(alice);
        caretakers.setPayout(aliceId, address(fund)); // fat-finger
        vm.warp(fund.epochEnd(0));
        uint256 net = fund.claimFor(0, aliceId);
        assertEq(fund.outstanding(), 0);
        assertEq(ledger.balanceOf(address(fund)), net, "net landed in the fund");
        _earn(aliceId, 500 * U); // unpaid income stays put
        uint256 poolBefore = ledger.balanceOf(address(pool));
        vm.prank(makeAddr("anyone"));
        assertEq(fund.skim(), net);
        assertEq(ledger.balanceOf(address(pool)) - poolBefore, net);
        assertEq(ledger.balanceOf(address(fund)), fund.outstanding());
    }

    // ─────────────────────────── trust: Safe over builder income ───────────────────────────

    /// TRUST (by design, no timelock): the Safe (REGISTRAR + fund GOVERNOR +
    /// pool GOVERNOR) can atomically deactivate a builder, sweep every ended,
    /// unclaimed epoch of its income to the pool, reactivate it, and publish a
    /// root paying the pool to five addresses of its choosing (20% cap each).
    /// The only builder-side defence is claiming (permissionless) as soon as the
    /// epoch ends; the current epoch is never exposed.
    function test_TRUST_safeCanRedirectUnclaimedIncome_inOneBatch() public {
        _earn(aliceId, 100_000 * U);
        vm.warp(fund.epochEnd(0));
        // one Safe batch
        builders.setActive(aliceId, false);
        fund.sweepFrozen(0, aliceId);
        builders.setActive(aliceId, true);
        assertEq(pool.unallocated(), 100_000 * U);
        vm.expectRevert(BuilderFund.AlreadyClaimed.selector);
        fund.claimFor(0, aliceId);
        // sybils registered by anyone (registration is permissionless, active by default)
        uint256[5] memory ids;
        for (uint256 i; i < 5; i++) {
            address s = address(uint160(0xB000 + i));
            vm.prank(s);
            ids[i] = builders.registerBuilder("");
        }
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i; i < 5; i++) {
            leaves[i] = pool.leafOf(7, ids[i], 20_000 * U);
        }
        // 5-leaf tree via sorted pairs
        bytes32 root = _root(leaves);
        pool.publishSeason(7, root, 100_000 * U, uint64(block.timestamp + 1 days));
        for (uint256 i; i < 5; i++) {
            pool.claim(7, ids[i], 20_000 * U, _proof(leaves, i));
        }
        uint256 got;
        for (uint256 i; i < 5; i++) {
            got += ledger.balanceOf(address(uint160(0xB000 + i)));
        }
        assertEq(got, 100_000 * U, "whole unclaimed income redirected");
    }

    // ─────────────────────────── fuzz: tax math ───────────────────────────

    function _schedule(uint256 seed) internal pure returns (BuilderFund.Bracket[] memory b) {
        uint256 n = 1 + (seed % 8);
        b = new BuilderFund.Bracket[](n);
        uint256 upTo = 100e6 + (uint256(keccak256(abi.encode(seed, "f"))) % 1e15);
        uint256 rate;
        b[0] = BuilderFund.Bracket(uint128(upTo), 0);
        for (uint256 i = 1; i < n; i++) {
            upTo += 1 + (uint256(keccak256(abi.encode(seed, i))) % 1e24);
            rate += uint256(keccak256(abi.encode(seed, i, "r"))) % 1500;
            if (rate > 4000) rate = 4000;
            b[i] = BuilderFund.Bracket(uint128(upTo), uint16(rate));
        }
        b[n - 1].upTo = type(uint128).max;
    }

    /// Any schedule the Safe can set: the split never underflows, sums to
    /// gross, tax <= 40%, and take-home is monotonic in gross.
    function testFuzz_split_anyValidSchedule(uint256 seed, uint256 a, uint256 b) public {
        BuilderFund.Bracket[] memory s = _schedule(seed);
        fund.setSchedule(s); // must validate
        a = bound(a, 0, 1e30);
        b = bound(b, a, 1e30);
        uint256 ta = fund.progressiveTax(a, s);
        uint256 tb = fund.progressiveTax(b, s);
        assertLe(ta * 10_000, a * 4000, "tax > 40%");
        assertLe(ta, tb, "tax not monotonic");
        assertLe(a - ta, b - tb, "take-home decreased with income");
        uint256 fee = ((b - tb) * 100) / 10_000;
        assertEq(b - tb - fee + tb + fee, b);
    }

    /// Splitting income across k sybil builders (or across epochs) never costs
    /// more: tax is superadditive. The saving is bounded by the brackets
    /// (launch: at most $900 on the second bracket + ... per extra identity).
    function testFuzz_tax_splittingNeverCostsMore(uint256 a, uint256 b) public view {
        a = bound(a, 0, 1e18);
        b = bound(b, 0, 1e18);
        assertGe(_tax(a + b), _tax(a) + _tax(b), "splitting cost more");
    }

    /// Exact sybil saving at launch: k identities each earning g/k.
    function test_sybilSaving_launchSchedule() public {
        uint256 g = 60_000 * U;
        uint256 one = _tax(g);
        uint256 six = 6 * _tax(g / 6);
        emit log_named_decimal_uint("tax, 1 builder, $60k", one, 6);
        emit log_named_decimal_uint("tax, 6 sybils x $10k", six, 6);
        assertEq(one - six, 6_500 * U);
    }

    // ─────────────────────────── fuzz: epoch edges ───────────────────────────

    /// Income credited at any second t lands in epoch (t-START)/L and is claimable
    /// exactly from epochEnd(epoch), never earlier.
    function testFuzz_epochEdges(uint256 dt, uint256 amount) public {
        dt = bound(dt, 0, 50 * EPOCH);
        amount = bound(amount, 1, 1e12);
        vm.warp(T0 + dt);
        uint256 e = dt / EPOCH;
        _earn(aliceId, amount);
        assertEq(fund.incomeOf(e, aliceId), amount);
        uint256 end = fund.epochEnd(e);
        assertEq(end, T0 + (e + 1) * EPOCH);
        vm.warp(end - 1);
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.claimFor(e, aliceId);
        // a credit in the last second still goes to e
        _earn(aliceId, 1);
        vm.warp(end);
        _earn(aliceId, 1); // first second of e+1
        assertEq(fund.incomeOf(e + 1, aliceId), 1);
        uint256 net = fund.claimFor(e, aliceId);
        assertGt(net + 1, 0);
        vm.expectRevert(BuilderFund.AlreadyClaimed.selector);
        fund.claimFor(e, aliceId);
        vm.expectRevert(BuilderFund.EpochNotEnded.selector);
        fund.claimFor(e + 1, aliceId);
    }

    // ─────────────────────────── season pool edges ───────────────────────────

    /// FIXED I-3: a season's deadline is at most 365 days ahead, so a typo can no
    /// longer lock the allocation for ever.
    function test_FIXED_I3_seasonDeadlineCapped() public {
        _earn(aliceId, 50_000 * U);
        vm.warp(fund.epochEnd(0));
        fund.claimFor(0, aliceId); // tax -> pool
        uint256 un = pool.unallocated();
        assertGt(un, 0);
        vm.expectRevert(SeasonPool.BadDeadline.selector);
        pool.publishSeason(1, bytes32(uint256(1)), un, type(uint64).max);
        pool.publishSeason(1, bytes32(uint256(1)), un, uint64(vm.getBlockTimestamp() + 365 days));
        vm.warp(vm.getBlockTimestamp() + 366 days);
        pool.reclaim(1);
        assertEq(pool.unallocated(), un, "reclaimed after the deadline");
    }

    /// Holds: no role but a merkle claimant moves pool funds; FUNDER can only
    /// account balance already present (same as the permissionless sync).
    function test_OK_rogueFunderCannotInflateOrTake() public {
        address rogue = makeAddr("rogue");
        pool.grantRole(pool.FUNDER_ROLE(), rogue);
        vm.prank(rogue);
        vm.expectRevert(SeasonPool.Unfunded.selector);
        pool.fund(1);
    }

    /// Holds: a rogue MARKETS holder can only attribute ledger balance the fund
    /// already holds above `outstanding` (never builders' income).
    function test_OK_rogueMarketsCannotCreditUnbacked() public {
        address rogue = makeAddr("rogueMarkets");
        fund.grantRole(fund.MARKETS_ROLE(), rogue);
        _earn(aliceId, 1_000 * U);
        vm.startPrank(rogue);
        vm.expectRevert(BuilderFund.Unfunded.selector);
        fund.credit(aliceId, 1);
        vm.expectRevert(BuilderFund.Unfunded.selector);
        fund.creditSeason(1);
        vm.stopPrank();
    }

    // ─────────────────────────── merkle helpers ───────────────────────────

    function _hp(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _up(bytes32[] memory l) internal pure returns (bytes32[] memory n) {
        n = new bytes32[]((l.length + 1) / 2);
        for (uint256 i; i < n.length; i++) {
            n[i] = 2 * i + 1 < l.length ? _hp(l[2 * i], l[2 * i + 1]) : l[2 * i];
        }
    }

    function _root(bytes32[] memory l) internal pure returns (bytes32) {
        while (l.length > 1) l = _up(l);
        return l[0];
    }

    function _proof(bytes32[] memory l, uint256 idx) internal pure returns (bytes32[] memory p) {
        bytes32[] memory buf = new bytes32[](16);
        uint256 n;
        while (l.length > 1) {
            uint256 sib = idx ^ 1;
            if (sib < l.length) buf[n++] = l[sib];
            l = _up(l);
            idx /= 2;
        }
        p = new bytes32[](n);
        for (uint256 i; i < n; i++) {
            p[i] = buf[i];
        }
    }
}
