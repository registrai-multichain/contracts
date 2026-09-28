// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {BuilderRegistry} from "../../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../../src/perennial/CaretakerRegistry.sol";
import {BuilderFund} from "../../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../../src/perennial/SeasonPool.sol";
import {LaunchSchedule} from "../../../script/lib/LaunchSchedule.sol";

/// Audit (BuilderFund + SeasonPool): stateful fuzzing of the income stack with
/// independent ghosts. The handler plays the markets (MARKETS_ROLE), the Safe
/// (GOVERNOR / REGISTRAR), builder owners and strangers.
contract FundHandler is Test {
    MockUSDC public usdc;
    NanoLedger public ledger;
    BuilderRegistry public builders;
    CaretakerRegistry public caretakers;
    SeasonPool public pool;
    BuilderFund public fund;
    address public treasury = makeAddr("fundTreasury");

    uint256 public constant NB = 4;
    uint256 public constant EPOCH = 7 days;

    // ghosts ─────────────────────────────────────────────
    mapping(uint256 => mapping(uint256 => uint256)) public gIncome; // epoch => id => credited
    mapping(uint256 => mapping(uint256 => uint256)) public gPaid; // epoch => id => gross paid out (claims + sweeps)
    uint256 public gLate; // through creditLate (released escrow)
    uint256 public paidWithoutNewIncome; // a claim/sweep that paid income already paid
    uint256 public gOutstanding;
    uint256 public gCredited; // through credit
    uint256 public gSeasonCredited; // through creditSeason
    uint256 public gNet;
    uint256 public gFee;
    uint256 public gToPoolFromFund;
    uint256 public gFundDonations;
    uint256 public gPoolDonations; // sent to the pool and not yet synced
    uint256 public gSeasonPaid;
    uint256 public gSynced;
    mapping(address => uint256) public gReceived; // net + season payouts per address

    // independent ownership / payout model
    mapping(uint256 => address) public gOwner;
    mapping(uint256 => address) public gPayout; // 0 = none valid for current owner
    uint256 public walletNonce;

    // schedule immutability: epoch => hash of its schedule once final
    mapping(uint256 => bytes32) public gSchedHash;
    uint256 public gSchedMaxSnap; // epochs [0, gSchedMaxSnap) snapshotted
    bool public schedChanged;

    uint256[] public credE;
    uint256[] public credId;

    // season model
    uint256 public nextSeason = 1;
    uint256[] public seasonIds;
    mapping(uint256 => uint256) public sBuilder;
    mapping(uint256 => uint256) public sAmount;

    // violations recorded in handlers (asserted by invariants)
    uint256 public badPayout;
    uint256 public badSplit;
    uint256 public earlyClaimOk;
    uint256 public calls;
    mapping(bytes32 => uint256) public ok;

    address public markets = address(this);

    constructor() {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this));
        builders = new BuilderRegistry(address(this));
        caretakers = new CaretakerRegistry(builders, address(this));
        pool = new SeasonPool(ledger, builders, caretakers, address(this));
        fund = new BuilderFund(
            ledger, builders, caretakers, pool, treasury, address(this), EPOCH, 0, LaunchSchedule.brackets()
        );
        pool.grantRole(pool.FUNDER_ROLE(), address(fund));
        fund.grantRole(fund.MARKETS_ROLE(), address(this));
        fund.grantRole(fund.LATE_ROLE(), address(this)); // plays the WonderEscrow's releases too
        for (uint256 i; i < NB; i++) {
            address o = _fresh();
            vm.prank(o);
            uint256 id = builders.registerBuilder("");
            gOwner[id] = o;
        }
        usdc.mint(address(this), type(uint128).max);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(type(uint128).max);
        _snapSchedules();
    }

    function _fresh() internal returns (address a) {
        a = address(uint160(uint256(keccak256(abi.encode("wallet", walletNonce++)))));
    }

    function _id(uint256 s) internal pure returns (uint256) {
        return 1 + (s % NB);
    }

    function _expectedPayout(uint256 id) internal view returns (address) {
        return gPayout[id] != address(0) ? gPayout[id] : gOwner[id];
    }

    function _schedHash(uint256 e) internal view returns (bytes32) {
        return keccak256(abi.encode(fund.scheduleFor(e)));
    }

    /// Every epoch <= current + 1 has a final schedule: snapshot new ones, and
    /// flag any already-final schedule that changed.
    function _snapSchedules() internal {
        uint256 upto = fund.currentEpoch() + 2; // [0, current+1]
        uint256 from = upto > 6 ? upto - 6 : 0; // only the latest history entry is ever replaced
        for (uint256 e = from; e < gSchedMaxSnap && e < upto; e++) {
            if (_schedHash(e) != gSchedHash[e]) schedChanged = true;
        }
        for (uint256 e = gSchedMaxSnap; e < upto; e++) {
            gSchedHash[e] = _schedHash(e);
        }
        if (upto > gSchedMaxSnap) gSchedMaxSnap = upto;
    }

    modifier tick() {
        calls++;
        _;
        _snapSchedules();
    }

    // ───────────────────────────── markets ─────────────────────────────

    function credit(uint256 idSeed, uint256 amount) external tick {
        uint256 id = idSeed % (NB + 2); // include 0 and an unregistered id
        amount = bound(amount, 0, 200_000e6);
        uint256 e = fund.currentEpoch();
        if (amount > 0) ledger.internalTransfer(address(fund), amount);
        fund.credit(id, amount);
        gIncome[e][id] += amount;
        gOutstanding += amount;
        gCredited += amount;
        if (amount > 0) {
            credE.push(e);
            credId.push(id);
        }
        ok["credit"]++;
    }

    /// The WonderEscrow releasing escrow into an ENDED epoch (late income), possibly
    /// one already claimed: the rest is claimable again, taxed at the margin.
    function creditLate(uint256 epochSeed, uint256 idSeed, uint256 amount) external tick {
        uint256 cur = fund.currentEpoch();
        if (cur == 0) return;
        uint256 e = bound(epochSeed, 0, cur - 1);
        uint256 id = idSeed % (NB + 2);
        amount = bound(amount, 1, 100_000e6);
        ledger.internalTransfer(address(fund), amount);
        fund.creditLate(id, e, amount);
        gIncome[e][id] += amount;
        gOutstanding += amount;
        gCredited += amount;
        gLate += amount;
        credE.push(e);
        credId.push(id);
        ok["creditLate"]++;
    }

    /// A MARKETS holder crediting without paying first (surplus only).
    function creditUnpaid(uint256 idSeed, uint256 amount) external tick {
        uint256 id = _id(idSeed);
        amount = bound(amount, 1, 1_000e6);
        uint256 e = fund.currentEpoch();
        try fund.credit(id, amount) {
            // only possible out of donated surplus
            require(gFundDonations >= amount, "credited out of thin air");
            gFundDonations -= amount;
            gIncome[e][id] += amount;
            gOutstanding += amount;
            gCredited += amount;
            ok["creditUnpaid"]++;
        } catch {}
    }

    function creditSeason(uint256 amount) external tick {
        amount = bound(amount, 0, 50_000e6);
        if (amount > 0) ledger.internalTransfer(address(fund), amount);
        fund.creditSeason(amount);
        gSeasonCredited += amount;
        gToPoolFromFund += amount;
        ok["creditSeason"]++;
    }

    function donateFund(uint256 amount) external tick {
        amount = bound(amount, 1, 10_000e6);
        ledger.internalTransfer(address(fund), amount);
        gFundDonations += amount;
    }

    function donatePool(uint256 amount) external tick {
        amount = bound(amount, 1, 10_000e6);
        ledger.internalTransfer(address(pool), amount);
        gPoolDonations += amount;
    }

    function syncPool() external tick {
        try pool.sync() returns (uint256 a) {
            require(a == gPoolDonations, "sync moved other than the donations");
            gSynced += a;
            gPoolDonations = 0;
            ok["sync"]++;
        } catch {}
    }

    function warp(uint256 dt) external tick {
        dt = bound(dt, 1, 20 days);
        vm.warp(block.timestamp + dt);
    }

    /// Land exactly on an epoch boundary (or one second before).
    function warpToBoundary(bool before) external tick {
        uint256 end = fund.epochEnd(fund.currentEpoch());
        vm.warp(before ? end - 1 : end);
    }

    // ───────────────────────────── claims ─────────────────────────────

    function _refTax(uint256 gross, BuilderFund.Bracket[] memory b) internal pure returns (uint256 tax) {
        // independent reference: sum over slices, the last open-ended
        uint256 prev;
        for (uint256 i; i < b.length; i++) {
            uint256 hi = i + 1 == b.length ? type(uint256).max : uint256(b[i].upTo);
            if (gross <= prev) break;
            uint256 slice = (gross < hi ? gross : hi) - prev;
            tax += slice * b[i].rateBps / 10_000;
            prev = hi;
        }
    }

    function _pick(uint256 epochSeed, uint256 idSeed) internal view returns (uint256 e, uint256 id) {
        uint256 cur = fund.currentEpoch();
        if (credE.length > 0 && idSeed % 4 != 0) {
            uint256 k = epochSeed % credE.length;
            return (credE[k], credId[k]);
        }
        return (bound(epochSeed, 0, cur + 1), idSeed % (NB + 2));
    }

    function claim(uint256 epochSeed, uint256 idSeed, address caller) external tick {
        (uint256 e, uint256 id) = _pick(epochSeed, idSeed);
        // half the time, wait for the epoch to end (exactly at the boundary)
        if ((idSeed >> 16) % 2 == 0 && block.timestamp < fund.epochEnd(e)) vm.warp(fund.epochEnd(e));
        uint256 cur = fund.currentEpoch();
        address payout = _expectedPayout(id);
        uint256 before = ledger.balanceOf(payout);
        uint256 tBefore = ledger.balanceOf(treasury);
        uint256 pBefore = pool.unallocated();
        BuilderFund.Bracket[] memory sched = fund.scheduleFor(e);
        vm.prank(caller);
        try fund.claimFor(e, id) returns (uint256 net) {
            if (e >= cur) earlyClaimOk++;
            uint256 income = gIncome[e][id];
            uint256 paid = gPaid[e][id];
            if (income <= paid) paidWithoutNewIncome++;
            gPaid[e][id] = income;
            // the unpaid part, taxed incrementally: tax(income) - tax(paid)
            uint256 gross = income - paid;
            uint256 tax = _refTax(income, sched) - _refTax(paid, sched);
            uint256 fee = (gross - tax) / 100;
            if (net != gross - tax - fee) badSplit++;
            if (payout == treasury || payout == address(pool)) {
                // degenerate routing; skip exact deltas
            } else {
                if (ledger.balanceOf(payout) - before != net) badPayout++;
                if (ledger.balanceOf(treasury) - tBefore != fee) badSplit++;
            }
            if (pool.unallocated() - pBefore != tax) badSplit++;
            gReceived[payout] += net;
            gNet += net;
            gFee += fee;
            gToPoolFromFund += tax;
            gOutstanding -= gross;
            ok["claim"]++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == BuilderFund.EpochNotEnded.selector) ok["c:notEnded"]++;
            else if (sel == BuilderFund.AlreadyClaimed.selector) ok["c:already"]++;
            else if (sel == BuilderFund.NoIncome.selector) ok["c:noIncome"]++;
            else if (sel == BuilderFund.BuilderInactive.selector) ok["c:inactive"]++;
            else ok["c:other"]++;
        }
    }

    function sweepFrozen(uint256 epochSeed, uint256 idSeed) external tick {
        uint256 cur = fund.currentEpoch();
        (uint256 e, uint256 id) = _pick(epochSeed, idSeed);
        try fund.sweepFrozen(e, id) {
            if (e >= cur) earlyClaimOk++;
            uint256 income = gIncome[e][id];
            if (income <= gPaid[e][id]) paidWithoutNewIncome++;
            uint256 gross = income - gPaid[e][id]; // only the unpaid part moves
            gPaid[e][id] = income;
            gToPoolFromFund += gross;
            gOutstanding -= gross;
            ok["sweep"]++;
        } catch {}
    }

    // ───────────────────────────── registry ─────────────────────────────

    function toggleActive(uint256 idSeed) external tick {
        uint256 id = _id(idSeed);
        builders.setActive(id, (idSeed >> 8) % 4 != 0); // mostly (re)activate
        ok["toggle"]++;
    }

    function setPayout(uint256 idSeed, uint256 whoSeed) external tick {
        uint256 id = _id(idSeed);
        address to = address(uint160(bound(whoSeed, 1, 1000)) + 0xA000);
        address o = gOwner[id];
        vm.prank(o);
        caretakers.setPayout(id, to);
        gPayout[id] = to;
        ok["setPayout"]++;
    }

    function transferOwner(uint256 idSeed) external tick {
        uint256 id = _id(idSeed);
        address o = gOwner[id];
        address n = _fresh();
        vm.prank(o);
        builders.proposeOwner(n);
        vm.prank(n);
        builders.acceptOwnership(id);
        gOwner[id] = n;
        gPayout[id] = address(0); // falls back to the new owner
        ok["transfer"]++;
    }

    function recover(uint256 idSeed) external tick {
        uint256 id = _id(idSeed);
        address n = _fresh();
        builders.startRecovery(id, n);
        vm.warp(block.timestamp + 7 days);
        builders.finishRecovery(id);
        gOwner[id] = n;
        gPayout[id] = address(0);
        ok["recover"]++;
    }

    // ───────────────────────────── schedule ─────────────────────────────

    function setSchedule(uint256 seed) external tick {
        uint256 n = 1 + (seed % 8);
        BuilderFund.Bracket[] memory b = new BuilderFund.Bracket[](n);
        uint128 upTo = uint128(100e6 + (seed >> 8) % 5_000e6);
        uint16 rate;
        b[0] = BuilderFund.Bracket(upTo, 0);
        for (uint256 i = 1; i < n; i++) {
            upTo += uint128(1 + (uint256(keccak256(abi.encode(seed, i))) % 50_000e6));
            rate = uint16(rate + (uint256(keccak256(abi.encode(seed, i, 1))) % 1001));
            if (rate > 4000) rate = 4000;
            b[i] = BuilderFund.Bracket(upTo, rate);
        }
        b[n - 1].upTo = type(uint128).max;
        fund.setSchedule(b);
        ok["setSchedule"]++;
    }

    // ───────────────────────────── season pool ─────────────────────────────

    function publishSeason(uint256 idSeed, uint256 frac, uint256 dur) external tick {
        uint256 un = pool.unallocated();
        if (un < 5) return;
        uint256 total = bound(frac, 5, un);
        uint256 amount = total / 5; // the 20% cap
        uint256 id = _id(idSeed);
        uint256 sid = nextSeason++;
        bytes32 leaf = pool.leafOf(sid, id, amount);
        uint64 deadline = uint64(block.timestamp + bound(dur, 1, 30 days));
        pool.publishSeason(sid, leaf, total, deadline);
        seasonIds.push(sid);
        sBuilder[sid] = id;
        sAmount[sid] = amount;
        ok["publish"]++;
    }

    function claimSeason(uint256 k) external tick {
        if (seasonIds.length == 0) return;
        uint256 sid = k % 2 == 0 ? seasonIds[seasonIds.length - 1] : seasonIds[k % seasonIds.length];
        uint256 id = sBuilder[sid];
        address payout = _expectedPayout(id);
        uint256 before = ledger.balanceOf(payout);
        try pool.claim(sid, id, sAmount[sid], new bytes32[](0)) returns (uint256 amt) {
            if (ledger.balanceOf(payout) - before != amt) badPayout++;
            gReceived[payout] += amt;
            gSeasonPaid += amt;
            ok["seasonClaim"]++;
        } catch {}
    }

    function reclaim(uint256 k) external tick {
        if (seasonIds.length == 0) return;
        uint256 sid = seasonIds[k % seasonIds.length];
        try pool.reclaim(sid) {
            ok["reclaim"]++;
        } catch {}
    }

    function sumUnclaimedIncome() external view returns (uint256 s) {
        uint256 cur = fund.currentEpoch();
        for (uint256 e; e <= cur; e++) {
            for (uint256 id; id < NB + 2; id++) {
                s += gIncome[e][id] - gPaid[e][id];
            }
        }
    }

    /// (epoch, builder) pairs paid more than they earned (must stay 0).
    function overpaid() external view returns (uint256 n) {
        uint256 cur = fund.currentEpoch();
        for (uint256 e; e <= cur + 1; e++) {
            for (uint256 id; id < NB + 2; id++) {
                if (gPaid[e][id] > gIncome[e][id]) n++;
                if (gPaid[e][id] != 0 && fund.paidGross(e, id) != gPaid[e][id]) n++;
            }
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 120
/// forge-config: default.invariant.fail-on-revert = true
contract FundInvariantTest is StdInvariant, Test {
    FundHandler h;

    function setUp() public {
        h = new FundHandler();
        targetContract(address(h));
        bytes4[] memory s = new bytes4[](26);
        s[0] = h.credit.selector;
        s[1] = h.creditUnpaid.selector;
        s[2] = h.creditSeason.selector;
        s[3] = h.donateFund.selector;
        s[4] = h.donatePool.selector;
        s[5] = h.syncPool.selector;
        s[6] = h.warp.selector;
        s[7] = h.warpToBoundary.selector;
        s[8] = h.claim.selector;
        s[9] = h.claim.selector;
        s[10] = h.sweepFrozen.selector;
        s[11] = h.toggleActive.selector;
        s[12] = h.setPayout.selector;
        s[13] = h.transferOwner.selector;
        s[14] = h.recover.selector;
        s[15] = h.setSchedule.selector;
        s[16] = h.publishSeason.selector;
        s[17] = h.claimSeason.selector;
        s[18] = h.reclaim.selector;
        s[19] = h.credit.selector;
        s[20] = h.claim.selector;
        s[21] = h.claim.selector;
        s[22] = h.warpToBoundary.selector;
        s[23] = h.claimSeason.selector;
        s[24] = h.creditLate.selector;
        s[25] = h.creditLate.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    /// Fund ledger balance == outstanding + stray donations (exact), so it
    /// always covers every unclaimed income.
    function invariant_fundSolventExact() public view {
        NanoLedger l = h.ledger();
        BuilderFund f = h.fund();
        assertEq(f.outstanding(), h.gOutstanding(), "outstanding != ghost");
        assertEq(f.outstanding(), h.sumUnclaimedIncome(), "outstanding != sum of unclaimed income");
        assertEq(l.balanceOf(address(f)), f.outstanding() + h.gFundDonations(), "fund balance drift");
    }

    function invariant_poolAccountedExact() public view {
        NanoLedger l = h.ledger();
        SeasonPool p = h.pool();
        assertEq(l.balanceOf(address(p)), p.unallocated() + p.reserved() + h.gPoolDonations(), "pool balance drift");
        assertEq(h.gToPoolFromFund() + h.gSynced(), p.unallocated() + p.reserved() + h.gSeasonPaid(), "pool flow");
    }

    /// Everything the markets put in is either outstanding, paid, fee'd, or in the pool.
    function invariant_conservation() public view {
        BuilderFund f = h.fund();
        assertEq(
            h.gCredited() + h.gSeasonCredited(),
            f.outstanding() + h.gNet() + h.gFee() + h.gToPoolFromFund(),
            "fund conservation"
        );
        NanoLedger l = h.ledger();
        assertEq(h.usdc().balanceOf(address(l)), l.totalOwed(), "ledger solvency");
    }

    /// Income is paid at most once (late income: only the new part, once), never
    /// more than earned, and never for a current or future epoch.
    function invariant_singlePaymentAndTiming() public view {
        assertEq(h.overpaid(), 0, "an (epoch, builder) paid more than it earned");
        assertEq(h.paidWithoutNewIncome(), 0, "paid income that was already paid");
        assertEq(h.earlyClaimOk(), 0, "claimed/swept a current or future epoch");
    }

    function invariant_rightPayoutRightSplit() public view {
        assertEq(h.badPayout(), 0, "paid a wrong address / amount");
        assertEq(h.badSplit(), 0, "split != reference tax/fee");
    }

    function invariant_finalSchedulesNeverChange() public view {
        assertFalse(h.schedChanged(), "a final (current/next-epoch or past) schedule changed");
    }

    function afterInvariant() public view {
        // coverage: which handler paths actually succeeded in this run
        bytes32[18] memory k = [
            bytes32("credit"), "creditLate", "creditUnpaid", "creditSeason", "claim", "sweep", "toggle", "transfer", "recover",
            "setSchedule", "publish", "seasonClaim", "reclaim", "c:notEnded", "c:already", "c:noIncome", "c:inactive",
            "c:other"
        ];
        for (uint256 i; i < k.length; i++) {
            console2.log(string(abi.encodePacked(k[i])), h.ok(k[i]));
        }
    }
}
