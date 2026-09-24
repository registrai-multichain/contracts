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

/// The common markets share the settlement policy (and the fee model) with
/// MarketsPerennial. The V4-specific part: the 50% leg of every trading fee goes
/// to the Registrai TREASURY, which also takes the agent's escrowed 20% on a void
/// nobody successfully challenged.
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
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        markets = new MarketsV4(ledger, registry, attestation, address(this), treasury, WINDOW, GRACE);
        markets.setApprovedResolver(resolver, true);

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

    function test_silentAgent_voids_andRefundsNetCost() public {
        bytes32 id = _market();
        _trade(id);
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        vm.prank(yesTaker);
        assertEq(markets.redeem(id), 990e6, "1000 in, 10 paid in fees, 990 back");
        vm.prank(noTaker);
        assertEq(markets.redeem(id), 693e6, "700 in, 7 paid in fees, 693 back");
        vm.prank(creator);
        assertEq(markets.claimLP(id), 1_000e6, "the LP seed, whole");
        _solvent();
        assertEq(ledger.balanceOf(address(markets)), 0, "nothing remains");
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
        new MarketsV4(ledger, registry, attestation, address(this), treasury, 0, GRACE);
    }

    /// L7: a zero treasury is a ZeroAddress error, not AmountTooLow.
    function test_constructorRejectsZeroTreasury() public {
        vm.expectRevert(MarketsV4.ZeroAddress.selector);
        new MarketsV4(ledger, registry, attestation, address(this), address(0), WINDOW, GRACE);
    }

    /// The split is fixed in code (no deploy input): 1% of each trade, 30 / 20 / 50.
    function test_feeIsFixedInCode() public view {
        assertEq(markets.TRADE_FEE_BPS(), 100);
        assertEq(markets.CREATOR_SHARE_BPS(), 3000);
        assertEq(markets.AGENT_SHARE_BPS(), 2000);
        assertEq(markets.TREASURY_SHARE_BPS(), 5000);
        assertEq(markets.BPS(), 10_000);
        assertEq(markets.TREASURY(), treasury);
    }

    // ───────────── the fee: per trade, the agent's share escrowed ─────────────

    /// Creator and treasury are paid on each trade; the agent's 20% is held and
    /// released at resolve (nothing else is charged then).
    function test_agentPaidOnResolve() public {
        bytes32 id = _market();
        _trade(id); // fees 10 + 7 = 17
        assertEq(ledger.balanceOf(oracle), 0);
        assertEq(ledger.balanceOf(treasury), 85e5, "50% of 17, paid per trade");
        assertEq(markets.agentEscrow(id), 34e5, "20% of 17, held");
        vm.warp(_expiry(id) + 1);
        _attest(120_000);
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertEq(ledger.balanceOf(oracle), 34e5, "escrow released");
        assertEq(markets.agentEscrow(id), 0);
        assertEq(ledger.balanceOf(treasury), 85e5, "nothing charged at settlement");
        _solvent();
    }

    /// Void with no successful challenge: the escrowed 20% goes to the treasury.
    function test_silentAgentVoid_agentLegToTreasury() public {
        bytes32 id = _market();
        _trade(id);
        uint256 c0 = ledger.balanceOf(creator);
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
        assertEq(ledger.balanceOf(oracle), 0, "the agent keeps nothing for a market it failed");
        assertEq(ledger.balanceOf(treasury), 85e5 + 34e5, "treasury: its 50% plus the escrow");
        assertEq(ledger.balanceOf(creator), c0, "nothing charged at void");
    }

    /// Creator and agent the same wallet: it collects both legs once it settles.
    function test_creatorIsAgent_collectsBothLegsWhenSettled() public {
        _fundAs(oracle);
        vm.prank(oracle);
        bytes32 id = markets.createMarket(feedId, oracle, int256(100_000), MarketsV4.Comparator.GreaterOrEqual, block.timestamp + 2 hours, 1_000e6);
        uint256 b0 = ledger.balanceOf(oracle);
        vm.prank(yesTaker);
        markets.buy(id, MarketsV4.Outcome.Yes, 9_000e6, 0); // fee 90
        assertEq(ledger.balanceOf(oracle) - b0, 27e6, "creator leg now");
        vm.warp(_expiry(id) + 1);
        _attest(120_000);
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
        assertEq(ledger.balanceOf(oracle) - b0, 45e6, "30 + 20 of 90");
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
            if (markets.redeemable(id, who[i]) > 0) {
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
