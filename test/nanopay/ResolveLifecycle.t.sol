// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsPerennial} from "../../src/nanopay/MarketsPerennial.sol";
import {BinaryMarket} from "../../src/nanopay/BinaryMarket.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {BuilderFund} from "../../src/perennial/BuilderFund.sol";
import {SeasonPool} from "../../src/perennial/SeasonPool.sol";
import {FundKit} from "../perennial/FundKit.sol";
import {MarketsKit} from "../perennial/MarketsKit.sol";
import {BuilderRegistry} from "../../src/perennial/BuilderRegistry.sol";
import {CaretakerRegistry} from "../../src/perennial/CaretakerRegistry.sol";

/// @notice The RESOLVE path under interleaved buys and sells: after a random
/// trading history the agent attests, the market resolves, every holder
/// redeems, the LP claims — the market's ledger balance must cover all of it,
/// leave only rounding dust, and the agent's escrow must be released in full.
/// (The reviewer's testFuzz_lifecycleSolvent covered the void path.)
contract ResolveLifecycleTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    NanoLedger ledger;
    MarketsPerennial perennial;
    MarketsV4 v4;
    BuilderFund fund;
    SeasonPool pool;
    address treasury = address(0x7EA);

    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address[4] traders = [address(0x7A1), address(0x7A2), address(0x7A3), address(0x7A4)];
    bytes32 feedId;

    uint256 constant DW = 1 hours;
    uint256 constant LIFE = 10 hours;
    uint256 constant DUST = 10;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        Dispute dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        BuilderRegistry builders = new BuilderRegistry(address(this));
        CaretakerRegistry caretakers = new CaretakerRegistry(builders, address(this));
        builders.registerFor(address(0xB111), "b1");
        (pool, fund) = FundKit.deploy(ledger, builders, caretakers, address(0x7EA5), 1 days);
        perennial =
            MarketsKit.perennial(ledger, registry, attestation, builders, address(this), fund, 24 hours, 7 days);
        FundKit.wire(fund, address(perennial));
        v4 = new MarketsV4(ledger, registry, attestation, address(this), treasury, 24 hours, 7 days);
        perennial.setApprovedAgent(agent, true);
        perennial.setApprovedResolver(resolver, true);
        v4.setApprovedResolver(resolver, true);

        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("f", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 100e6);
        vm.stopPrank();

        _fund(creator);
        for (uint256 i; i < traders.length; i++) {
            _fund(traders[i]);
        }
        MarketsKit.certify(perennial, 1);
        MarketsKit.bindBuilder(perennial, feedId, 1);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(500_000e6);
        ledger.approveSpender(address(perennial), type(uint256).max);
        ledger.approveSpender(address(v4), type(uint256).max);
        vm.stopPrank();
    }

    function _solventLedger() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger insolvent");
    }

    function testFuzz_perennial_resolveSolvent(uint256 seed, uint8 n, int256 value, uint256 liq) public {
        n = uint8(bound(n, 1, 40));
        liq = bound(liq, 5e6, 50_000e6);
        value = bound(value, -1, 2);
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(creator);
        bytes32 id =
            perennial.createMarket(1, feedId, agent, 1, BinaryMarket.Comparator.GreaterOrEqual, t0 + LIFE, liq);

        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = traders[r % traders.length];
            BinaryMarket.Outcome o = (r >> 8) % 2 == 0 ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No;
            if ((r >> 16) % 3 == 0) {
                uint256 bal = o == BinaryMarket.Outcome.Yes ? perennial.yesBalance(id, who) : perennial.noBalance(id, who);
                if (bal == 0) continue;
                vm.prank(who);
                try perennial.sell(id, o, bound(r >> 32, 1, bal), 0, type(uint256).max) {} catch {}
            } else {
                vm.prank(who);
                try perennial.buy(id, o, bound(r >> 32, 1, 20_000e6), 0, type(uint256).max) {} catch {}
            }
        }

        uint256 c = perennial.collateralOf(id);
        uint256 escrow = perennial.agentEscrow(id);
        assertEq(ledger.balanceOf(address(perennial)), c + escrow, "the market holds C plus the agent's escrow");
        vm.warp(t0 + LIFE);
        vm.prank(agent);
        attestation.attest(feedId, value, keccak256("v"));
        vm.warp(t0 + LIFE + DW);
        uint256 agentBefore = ledger.balanceOf(agent);
        uint256 fundBefore = ledger.balanceOf(address(fund));
        uint256 poolBefore = ledger.balanceOf(address(pool));
        perennial.resolve(id);
        bool yesWon = perennial.getMarket(id).yesWon;
        assertEq(yesWon, value >= 1);
        assertEq(perennial.agentEscrow(id), 0, "escrow released");
        assertEq(ledger.balanceOf(agent) - agentBefore, escrow, "agent paid its escrow");
        assertEq(ledger.balanceOf(address(fund)), fundBefore, "nothing charged at settlement");
        assertEq(ledger.balanceOf(address(pool)), poolBefore, "nothing to the season pool on resolve");
        assertEq(ledger.balanceOf(address(perennial)), c, "exactly the escrow left the market");

        // everything owed to winners and the LP is covered by the market's balance
        uint256 owed = perennial.lpPotAtResolution(id);
        for (uint256 i; i < traders.length; i++) {
            owed += perennial.redeemable(id, traders[i]);
        }
        assertGe(ledger.balanceOf(address(perennial)), owed, "market cannot cover its winners + LP");

        for (uint256 i; i < traders.length; i++) {
            uint256 win = yesWon ? perennial.yesBalance(id, traders[i]) : perennial.noBalance(id, traders[i]);
            if (win == 0) continue;
            uint256 before = ledger.balanceOf(traders[i]);
            vm.prank(traders[i]);
            assertEq(perennial.redeem(id), win);
            assertEq(ledger.balanceOf(traders[i]) - before, win, "winner paid 1 per share");
        }
        vm.prank(creator);
        perennial.claimLP(id);
        assertLe(ledger.balanceOf(address(perennial)), DUST, "only dust left");
        _solventLedger();
    }

    function testFuzz_v4_resolveSolvent(uint256 seed, uint8 n, int256 value, uint256 liq) public {
        n = uint8(bound(n, 1, 40));
        liq = bound(liq, 5e6, 50_000e6);
        value = bound(value, -1, 2);
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(creator);
        bytes32 id = v4.createMarket(feedId, agent, 1, BinaryMarket.Comparator.GreaterOrEqual, t0 + LIFE, liq);

        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = traders[r % traders.length];
            BinaryMarket.Outcome o = (r >> 8) % 2 == 0 ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No;
            if ((r >> 16) % 3 == 0) {
                uint256 bal = o == BinaryMarket.Outcome.Yes ? v4.yesBalance(id, who) : v4.noBalance(id, who);
                if (bal == 0) continue;
                vm.prank(who);
                try v4.sell(id, o, bound(r >> 32, 1, bal), 0, type(uint256).max) {} catch {}
            } else {
                vm.prank(who);
                try v4.buy(id, o, bound(r >> 32, 1, 20_000e6), 0, type(uint256).max) {} catch {}
            }
        }

        uint256 c = v4.collateralOf(id);
        uint256 escrow = v4.agentEscrow(id);
        assertEq(ledger.balanceOf(address(v4)), c + escrow, "the market holds C plus the agent's escrow");
        vm.warp(t0 + LIFE);
        vm.prank(agent);
        attestation.attest(feedId, value, keccak256("v"));
        vm.warp(t0 + LIFE + DW);
        uint256 treasuryBefore = ledger.balanceOf(treasury);
        v4.resolve(id);
        bool yesWon = v4.getMarket(id).yesWon;
        assertEq(v4.agentEscrow(id), 0, "escrow released");
        assertEq(ledger.balanceOf(treasury), treasuryBefore, "nothing charged at settlement");
        assertEq(ledger.balanceOf(address(v4)), c, "exactly the escrow left the market");

        uint256 owed = v4.lpPotAtResolution(id);
        for (uint256 i; i < traders.length; i++) {
            owed += v4.redeemable(id, traders[i]);
        }
        assertGe(ledger.balanceOf(address(v4)), owed, "market cannot cover its winners + LP");

        for (uint256 i; i < traders.length; i++) {
            uint256 win = yesWon ? v4.yesBalance(id, traders[i]) : v4.noBalance(id, traders[i]);
            if (win == 0) continue;
            vm.prank(traders[i]);
            assertEq(v4.redeem(id), win);
        }
        vm.prank(creator);
        v4.claimLP(id);
        assertLe(ledger.balanceOf(address(v4)), DUST, "only dust left");
        _solventLedger();
    }
}
