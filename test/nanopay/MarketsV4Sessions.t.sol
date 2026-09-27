// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {Registry} from "../../src/Registry.sol";
import {Attestation} from "../../src/Attestation.sol";
import {Dispute} from "../../src/Dispute.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../../src/nanopay/MarketsV4.sol";
import {BinaryMarket} from "../../src/nanopay/BinaryMarket.sol";

/// Sessions on MarketsV4: an owner lets a delegate key trade for it (buyFor /
/// sellFor / redeemFor) within a spend cap and until an expiry. Everything moves
/// the OWNER's balance and positions; the delegate never holds anything.
contract MarketsV4SessionsTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    NanoLedger ledger;
    MarketsV4 markets;

    address oracle = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address treasury = address(0x7AEA);
    address creator = address(0xC0FFEE);
    address owner = address(0x0DD);
    address delegate = address(0xDE1E);
    address stranger = address(0x5EE);

    bytes32 feedId;
    bytes32 id;
    uint256 constant DW = 10 minutes;
    uint256 expiry;

    event Bought(bytes32 indexed marketId, address indexed buyer, BinaryMarket.Outcome outcome, uint256 collateralIn, uint256 sharesOut, uint256 fee);
    event SessionSet(address indexed owner, address indexed delegate, uint256 spendCap, uint256 expiry);

    function setUp() public {
        vm.warp(1_790_000_100);
        usdc = new MockUSDC();
        registry = new Registry(usdc, 1e6);
        attestation = new Attestation(registry);
        Dispute dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        markets = new MarketsV4(ledger, registry, attestation, address(this), treasury, 1 hours, 1 days);
        markets.setApprovedResolver(resolver, true);
        markets.setApprovedAgent(oracle, true);
        markets.setApprovedCreator(creator, true);
        usdc.mint(oracle, 1_000e6);
        vm.startPrank(oracle);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("registrai-data:btc-usd-5m-change-0", keccak256("m"), 1e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 1e6);
        vm.stopPrank();
        _fund(creator);
        _fund(owner);
        expiry = block.timestamp + 300;
        vm.prank(creator);
        id = markets.createMarket(feedId, oracle, 0, BinaryMarket.Comparator.GreaterThan, expiry, 5e6);
    }

    function _fund(address a) internal {
        usdc.mint(a, 10_000e6);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(1_000e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _session(uint128 cap) internal {
        vm.prank(owner);
        markets.setSession(delegate, cap, uint64(block.timestamp + 1 days));
    }

    function _settleUp() internal {
        vm.warp(expiry + 300);
        vm.prank(oracle);
        attestation.attest(feedId, 1234, bytes32("up"));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
    }

    function test_buyFor_movesTheOwnersBalanceAndPosition_notTheDelegates() public {
        _session(20e6);
        uint256 before = ledger.balanceOf(owner);
        vm.expectEmit(true, true, false, false);
        emit Bought(id, owner, BinaryMarket.Outcome.Yes, 0, 0, 0);
        vm.prank(delegate);
        uint256 shares = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 8e6, 0, block.timestamp);
        assertEq(ledger.balanceOf(owner), before - 8e6, "the owner pays");
        assertEq(markets.yesBalance(id, owner), shares, "the owner holds the shares");
        assertEq(markets.yesBalance(id, delegate), 0);
        assertEq(ledger.balanceOf(delegate), 0);
        (uint128 left,) = markets.sessions(owner, delegate);
        assertEq(left, 12e6, "the cap is spent down");
    }

    function test_buyFor_isExactlyABuyByTheOwner() public {
        _session(20e6);
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        uint256 direct = markets.buy(id, BinaryMarket.Outcome.No, 7e6, 0, block.timestamp);
        uint256 costDirect = markets.netCost(id, owner);
        vm.revertToState(snap);
        vm.prank(delegate);
        uint256 viaSession = markets.buyFor(owner, id, BinaryMarket.Outcome.No, 7e6, 0, block.timestamp);
        assertEq(viaSession, direct);
        assertEq(markets.netCost(id, owner), costDirect);
    }

    function test_theSpendCapBinds() public {
        _session(10e6);
        vm.startPrank(delegate);
        markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 6e6, 0, block.timestamp);
        vm.expectRevert(MarketsV4.SessionSpendExceeded.selector);
        markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 4e6 + 1, 0, block.timestamp);
        markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 4e6, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_noSession_expiredSession_revokedSession_allRevert() public {
        vm.prank(stranger);
        vm.expectRevert(MarketsV4.SessionInvalid.selector);
        markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 1e6, 0, block.timestamp);

        vm.prank(owner);
        markets.setSession(delegate, 100e6, uint64(block.timestamp + 60));
        vm.warp(block.timestamp + 60);
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionInvalid.selector);
        markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 1e6, 0, block.timestamp);

        _session(100e6);
        vm.prank(owner);
        markets.revokeSession(delegate);
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionInvalid.selector);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, 1, 0, block.timestamp);
    }

    function test_sessionBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(MarketsV4.SessionInvalid.selector);
        markets.setSession(delegate, 1e6, uint64(block.timestamp + 7 days + 1));
        vm.expectRevert(MarketsV4.SessionInvalid.selector);
        markets.setSession(delegate, 1e6, uint64(block.timestamp));
        vm.expectRevert(BinaryMarket.ZeroAddress.selector);
        markets.setSession(owner, 1e6, uint64(block.timestamp + 1 days));
        vm.expectRevert(BinaryMarket.ZeroAddress.selector);
        markets.setSession(address(0), 1e6, uint64(block.timestamp + 1 days));
        vm.expectEmit(true, true, false, true);
        emit SessionSet(owner, delegate, 5e6, block.timestamp + 7 days);
        markets.setSession(delegate, 5e6, uint64(block.timestamp + 7 days));
        vm.stopPrank();
    }

    function test_setSession_forwardsGasMoneyToTheDelegate() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        markets.setSession{value: 0.2 ether}(delegate, 5e6, uint64(block.timestamp + 1 days));
        assertEq(delegate.balance, 0.2 ether);
        assertEq(address(markets).balance, 0);
    }

    function test_sellFor_paysTheOwner() public {
        _session(20e6);
        vm.startPrank(delegate);
        uint256 shares = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 8e6, 0, block.timestamp);
        uint256 before = ledger.balanceOf(owner);
        uint256 out = markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, shares, 0, block.timestamp);
        vm.stopPrank();
        assertEq(ledger.balanceOf(owner), before + out, "proceeds to the owner");
        assertEq(ledger.balanceOf(delegate), 0, "nothing to the delegate");
        assertEq(markets.yesBalance(id, owner), 0);
    }

    function test_aDelegateSellsOnlyTheSharesItBought() public {
        // the owner's own position, bought with the wallet
        vm.prank(owner);
        uint256 own = markets.buy(id, BinaryMarket.Outcome.Yes, 10e6, 0, block.timestamp);
        _session(20e6);
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionSharesExceeded.selector);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, 1, 0, block.timestamp);
        // a dust buy (the old bypass) unlocks only the dust it bought, not the owner's shares
        vm.prank(delegate);
        uint256 dust = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 1, 0, block.timestamp);
        assertEq(markets.sessionShares(owner, delegate, id, BinaryMarket.Outcome.Yes), dust);
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionSharesExceeded.selector);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, own, 0, block.timestamp);
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionSharesExceeded.selector);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, dust + 1, 0, block.timestamp);
        // what it bought, it may sell back; then nothing more
        vm.prank(delegate);
        uint256 bought = markets.buyFor(owner, id, BinaryMarket.Outcome.No, 2e6, 0, block.timestamp);
        vm.prank(delegate);
        markets.sellFor(owner, id, BinaryMarket.Outcome.No, bought, 0, block.timestamp);
        assertEq(markets.sessionShares(owner, delegate, id, BinaryMarket.Outcome.No), 0);
        assertEq(markets.yesBalance(id, owner), own + dust, "the owner's own shares are untouched");
    }

    function test_revokingEndsTheOldSellRights_evenForTheSameDelegate() public {
        _session(20e6);
        vm.prank(delegate);
        uint256 shares = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 5e6, 0, block.timestamp);
        vm.prank(owner);
        markets.revokeSession(delegate);
        vm.prank(owner);
        markets.setSession(delegate, 0, uint64(block.timestamp + 1 days)); // a new session, cap 0
        assertEq(markets.sessionShares(owner, delegate, id, BinaryMarket.Outcome.Yes), 0);
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionSharesExceeded.selector);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, shares, 0, block.timestamp);
        assertEq(markets.yesBalance(id, owner), shares, "the owner keeps them (sells with the wallet)");
    }

    function test_renewingKeepsTheSellRights() public {
        _session(20e6);
        vm.prank(delegate);
        uint256 shares = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 5e6, 0, block.timestamp);
        _session(20e6); // setSession again (renewal) is not a revocation
        vm.prank(delegate);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, shares, 0, block.timestamp);
    }

    /// Buys after a revoke-and-renew belong to the NEW epoch: the delegate can sell
    /// them (audit mutation gap: crediting epoch 0 went undetected).
    function test_afterRevokeAndRenew_newBuysAreSellable() public {
        _session(20e6);
        vm.prank(delegate);
        uint256 old = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 2e6, 0, block.timestamp);
        vm.prank(owner);
        markets.revokeSession(delegate);
        _session(20e6);
        vm.prank(delegate);
        uint256 fresh = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 3e6, 0, block.timestamp);
        assertEq(markets.sessionShares(owner, delegate, id, BinaryMarket.Outcome.Yes), fresh, "only the new epoch's buys");
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionSharesExceeded.selector);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, fresh + old, 0, block.timestamp);
        vm.prank(delegate);
        markets.sellFor(owner, id, BinaryMarket.Outcome.Yes, fresh, 0, block.timestamp);
        assertEq(markets.yesBalance(id, owner), old, "the pre-revoke shares stay, sellable by the owner only");
    }

    function test_aStrangerCannotOpenAMarketOnTheAgentsFeed() public {
        // the decoy of the audit (C-1): another expiry on our feed would get our
        // agent's reading first inside a real market's window
        address stranger_ = address(0xBAD);
        usdc.mint(stranger_, 100e6);
        vm.startPrank(stranger_);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(50e6);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.expectRevert(MarketsV4.NotTheAgent.selector);
        markets.createMarket(feedId, oracle, 0, BinaryMarket.Comparator.GreaterThan, expiry - 300, 5e6);
        vm.stopPrank();
        // the agent itself may; only the governor approves other creator keys
        vm.prank(stranger_);
        vm.expectRevert();
        markets.setApprovedCreator(stranger_, true);
    }

    function test_tradingStopsOnceTheAgentIsInactive() public {
        // a market far out, so the agent's bond cooldown can pass before it closes
        uint256 far = (block.timestamp + 8 days) / 300 * 300;
        vm.prank(creator);
        bytes32 m = markets.createMarket(feedId, oracle, 0, BinaryMarket.Comparator.GreaterThan, far, 5e6);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(oracle);
        registry.withdrawBond(feedId); // the agent leaves the feed: the market can only void
        vm.prank(owner);
        vm.expectRevert(BinaryMarket.AgentInactive.selector);
        markets.buy(m, BinaryMarket.Outcome.Yes, 1e6, 0, block.timestamp);
    }

    function test_aDelegateCannotTouchSomeoneElse() public {
        _fund(stranger);
        vm.prank(stranger);
        markets.buy(id, BinaryMarket.Outcome.Yes, 5e6, 0, block.timestamp);
        _session(20e6); // a session from `owner`, not from `stranger`
        vm.prank(delegate);
        vm.expectRevert(MarketsV4.SessionInvalid.selector);
        markets.sellFor(stranger, id, BinaryMarket.Outcome.Yes, 1e6, 0, block.timestamp);
    }

    function test_redeemFor_paysTheOwner() public {
        _session(20e6);
        vm.prank(delegate);
        uint256 shares = markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 8e6, 0, block.timestamp);
        _settleUp();
        uint256 before = ledger.balanceOf(owner);
        vm.prank(delegate);
        uint256 paid = markets.redeemFor(owner, id);
        assertEq(paid, shares);
        assertEq(ledger.balanceOf(owner), before + shares);
        assertEq(ledger.balanceOf(delegate), 0);
    }

    function test_theOwnersLedgerAllowanceStillApplies() public {
        vm.prank(owner);
        ledger.approveSpender(address(markets), 3e6);
        _session(100e6);
        vm.prank(delegate);
        vm.expectRevert();
        markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 4e6, 0, block.timestamp);
    }

    function test_bettingClosesForDelegatesToo() public {
        _session(20e6);
        vm.warp(expiry);
        vm.prank(delegate);
        vm.expectRevert(BinaryMarket.MarketExpired.selector);
        markets.buyFor(owner, id, BinaryMarket.Outcome.Yes, 1e6, 0, block.timestamp);
    }
}
