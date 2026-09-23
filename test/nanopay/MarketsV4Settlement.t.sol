// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {SettlementPolicy} from "../../src/nanopay/SettlementPolicy.sol";

/// The common markets share the settlement policy. The V4-specific part is the
/// fee: it flows through a NanoLedger pool claimable at any time, so the agent's
/// cut has to be carved out of the pool and escrowed rather than accrued.
contract MarketsV4SettlementTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsV4 markets;

    address oracle = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address treasury = address(0x7AEA);
    address sink = address(0x51F);
    address creator = address(0xC0FFEE);
    address yesTaker = address(0x7A4E);
    address noTaker = address(0x7A4F);
    address sniper = address(0x5419E);
    address challenger = address(0xC4A1);
    bytes32 feedId;

    uint256 constant DW = 1 hours;
    uint256 constant WINDOW = 1 hours;
    uint256 constant GRACE = 1 days;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        markets = new MarketsV4(ledger, registry, attestation, treasury, sink, WINDOW, GRACE);
        ledger.setSource(address(markets), true);

        usdc.mint(oracle, 10_000e6);
        vm.startPrank(oracle);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("BTC/USD", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 1_000e6);
        vm.stopPrank();

        _fund(creator);
        _fund(yesTaker);
        _fund(noTaker);
        _fund(sniper);
        usdc.mint(challenger, 10_000e6);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _market() internal returns (bytes32 id) {
        vm.prank(creator);
        id = markets.createMarket(feedId, oracle, int256(100_000), MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 1_000e6);
    }

    function _attest(int256 v) internal returns (bytes32) {
        vm.prank(oracle);
        return attestation.attest(feedId, v, keccak256(abi.encode(v, block.timestamp)));
    }

    function _expiry(bytes32 id) internal view returns (uint256) {
        return markets.getMarket(id).expiry;
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger solvent");
    }

    function _trade(bytes32 id) internal {
        vm.prank(yesTaker);
        markets.buy(id, MarketsV4.Outcome.Yes, 1_000e6, 0);
        vm.prank(noTaker);
        markets.buy(id, MarketsV4.Outcome.No, 700e6, 0);
    }

    // ───────────── settlement rule ─────────────

    function test_settlesOnThePostExpiryReading() public {
        bytes32 id = _market();
        _trade(id);
        vm.warp(_expiry(id) + 1);
        _attest(120_000);
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertTrue(markets.getMarket(id).yesWon);
        _solvent();
    }

    function test_lastLookClosed_preExpiryReadingCannotSettle() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) - 30 minutes);
        _attest(120_000); // public while trading is open
        vm.prank(sniper);
        markets.buy(id, MarketsV4.Outcome.Yes, 500e6, 0);
        vm.warp(_expiry(id) + WINDOW + DW + 1);
        vm.expectRevert(SettlementPolicy.SettlementPending.selector);
        markets.resolve(id);
    }

    function test_silentAgent_voids_andPaysHalfPerShare() public {
        bytes32 id = _market();
        _trade(id);
        uint256 y = markets.yesBalance(id, yesTaker);
        uint256 n = markets.noBalance(id, noTaker);
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        vm.prank(yesTaker);
        assertEq(markets.redeem(id), y / 2);
        vm.prank(noTaker);
        assertEq(markets.redeem(id), n / 2);
        vm.prank(creator);
        markets.claimLP(id);
        _solvent();
        assertLe(ledger.balanceOf(address(markets)), 2, "only rounding dust remains");
    }

    function test_stuckDispute_voidsOnlyAfterTheHardDeadline() public {
        bytes32 id = _market();
        vm.warp(_expiry(id) + 1);
        bytes32 att = _attest(120_000);
        Registry.Agent memory a = registry.getAgent(feedId, oracle);
        vm.startPrank(challenger);
        usdc.approve(address(dispute), a.bond - a.lockedBond);
        dispute.challenge(att, keccak256("e"));
        vm.stopPrank();

        vm.warp(_expiry(id) + WINDOW + 1);
        vm.expectRevert(SettlementPolicy.NotVoidable.selector);
        markets.voidMarket(id);
        vm.warp(_expiry(id) + WINDOW + GRACE + 1);
        markets.voidMarket(id);
    }

    function test_refusesAnUnsettleableFeed() public {
        vm.startPrank(oracle);
        bytes32 slow = registry.createFeed("slow", keccak256("m"), 10e6, GRACE, resolver);
        registry.registerAgent(slow, keccak256("m"), 10e6);
        vm.stopPrank();
        vm.prank(creator);
        vm.expectRevert(SettlementPolicy.FeedUnsettleable.selector);
        markets.createMarket(slow, oracle, 1, MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 1_000e6);
    }

    function test_constructorRejectsBadParams() public {
        vm.expectRevert(SettlementPolicy.BadSettlementParams.selector);
        new MarketsV4(ledger, registry, attestation, treasury, sink, 0, GRACE);
    }

    function test_constructorRejectsZeroSink() public {
        vm.expectRevert(MarketsV4.ZeroAddress.selector);
        new MarketsV4(ledger, registry, attestation, treasury, address(0), WINDOW, GRACE);
    }

    // ───────────── the fee, carved out of the pool ─────────────

    /// 70 bps total: creator 40, agent 20, treasury 10. The pool now carries
    /// only creator and treasury; the agent's 20 is escrowed.
    function test_agentCutIsEscrowed_andThePoolPaysOnlyCreatorAndTreasury() public {
        bytes32 id = _market();
        vm.prank(yesTaker);
        markets.buy(id, MarketsV4.Outcome.Yes, 7_000e6, 0); // fee 49 USDC

        assertEq(markets.agentEscrow(id), 14e6, "20/70 of 49");
        assertEq(ledger.claimablePool(id, oracle), 0, "the agent has no share in the pool");

        uint256 c0 = ledger.balanceOf(creator);
        vm.prank(creator);
        ledger.claim(id);
        assertApproxEqAbs(ledger.balanceOf(creator) - c0, 28e6, 1, "creator 40/70 of 49");
        uint256 t0 = ledger.balanceOf(treasury);
        vm.prank(treasury);
        ledger.claim(id);
        assertApproxEqAbs(ledger.balanceOf(treasury) - t0, 7e6, 1, "treasury 10/70 of 49");
        _solvent();
    }

    function test_agentPaidOnResolve() public {
        bytes32 id = _market();
        _trade(id);
        uint256 escrow = markets.agentEscrow(id);
        uint256 before = ledger.balanceOf(oracle);
        vm.warp(_expiry(id) + 1);
        _attest(120_000);
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertEq(ledger.balanceOf(oracle) - before, escrow);
        _solvent();
    }

    function test_agentForfeitsOnVoid() public {
        bytes32 id = _market();
        _trade(id);
        uint256 escrow = markets.agentEscrow(id);
        uint256 before = ledger.balanceOf(oracle);
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        assertEq(ledger.balanceOf(oracle), before);
        assertEq(ledger.balanceOf(sink), escrow);
    }

    /// Creator and agent the same wallet: previously their shares were summed in
    /// the pool. Now the creator part pools and the agent part escrows, so the
    /// total is unchanged when the market settles.
    function test_creatorIsAgent_totalUnchangedWhenSettled() public {
        _fundAs(oracle);
        vm.prank(oracle);
        bytes32 id = markets.createMarket(feedId, oracle, int256(100_000), MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 1_000e6);
        vm.prank(yesTaker);
        markets.buy(id, MarketsV4.Outcome.Yes, 7_000e6, 0); // fee 49
        vm.warp(_expiry(id) + 1);
        _attest(120_000);
        vm.warp(block.timestamp + DW);
        uint256 b0 = ledger.balanceOf(oracle);
        markets.resolve(id);
        vm.prank(oracle);
        ledger.claim(id);
        assertApproxEqAbs(ledger.balanceOf(oracle) - b0, 42e6, 2, "40 + 20 of 70, as before");
    }

    function _fundAs(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(100_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function testFuzz_voidIsSolvent(uint96 a, uint96 b, uint96 c) public {
        bytes32 id = _market();
        vm.prank(yesTaker);
        markets.buy(id, MarketsV4.Outcome.Yes, bound(uint256(a), 1e6, 5_000e6), 0);
        vm.prank(noTaker);
        markets.buy(id, MarketsV4.Outcome.No, bound(uint256(b), 1e6, 5_000e6), 0);
        vm.prank(sniper);
        markets.buy(id, MarketsV4.Outcome.Yes, bound(uint256(c), 1e6, 5_000e6), 0);
        uint256 held = ledger.balanceOf(address(markets));
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        uint256 paid;
        address[3] memory who = [yesTaker, noTaker, sniper];
        for (uint256 i; i < 3; i++) {
            if (markets.yesBalance(id, who[i]) + markets.noBalance(id, who[i]) > 1) {
                vm.prank(who[i]);
                paid += markets.redeem(id);
            }
        }
        vm.prank(creator);
        paid += markets.claimLP(id);
        assertLe(paid, held);
        _solvent();
    }
}
