// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {Markets} from "../src/Markets.sol";
import {MarketMakerVault} from "../src/MarketMakerVault.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract MarketMakerVaultTest is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    Markets markets;
    MarketMakerVault vault;

    address creator = makeAddr("creator");
    // v2 rule: feed creator and agent are the same wallet.
    address agent = creator;
    address resolver = makeAddr("resolver");
    address marketCreator = makeAddr("marketCreator");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    bytes32 constant METHODOLOGY = keccak256("ipfs://methodology");
    bytes32 constant AGENT_METHODOLOGY = keccak256("ipfs://agent-methodology");
    uint256 constant DISPUTE_WINDOW = 1 days;
    uint256 constant MIN_BOND = 100e6;

    bytes32 feedId;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        markets = new Markets(attestation, registry, usdc, treasury);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        vault = new MarketMakerVault(usdc, markets, operator);

        usdc.mint(agent, 10_000e6);
        usdc.mint(marketCreator, 100_000e6);
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        vm.prank(creator);
        feedId = registry.createFeed(
            "Warsaw resi PLN/sqm", METHODOLOGY, MIN_BOND, DISPUTE_WINDOW, resolver
        );
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgent(feedId, AGENT_METHODOLOGY, MIN_BOND);
        vm.stopPrank();
    }

    function _attest(int256 value) internal {
        vm.prank(agent);
        attestation.attest(feedId, value, keccak256(abi.encode(value, block.timestamp)));
    }

    function _createMarket(int256 threshold, uint256 expiry, uint256 liquidity)
        internal
        returns (bytes32 marketId)
    {
        vm.startPrank(marketCreator);
        usdc.approve(address(markets), liquidity);
        marketId = markets.createMarket(
            feedId, agent, threshold, Markets.Comparator.GreaterThan, expiry, liquidity
        );
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount);
        vm.stopPrank();
    }

    function test_firstDeposit_mintsOneToOne() public {
        uint256 shares = _deposit(alice, 100e6);
        assertEq(shares, 100e6);
        assertEq(vault.totalShares(), 100e6);
        assertEq(vault.sharesOf(alice), 100e6);
        assertEq(vault.nav(), 100e6);
    }

    function test_secondDeposit_proRataAtUnchangedNav() public {
        _deposit(alice, 100e6);
        uint256 bobShares = _deposit(bob, 50e6);
        // NAV doubled-and-a-half; shares should track 1:1 since price is unchanged.
        assertApproxEqAbs(bobShares, 50e6, 2);
        assertApproxEqAbs(vault.totalShares(), 150e6, 2);
    }

    function test_withdraw_proRata() public {
        _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        // No trading happens — both withdrawals return roughly their stakes.
        uint256 aliceShares = vault.sharesOf(alice);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.withdraw(aliceShares);
        assertApproxEqAbs(out, 100e6, 2);
        assertEq(usdc.balanceOf(alice), aliceBefore + out);
        assertEq(vault.sharesOf(alice), 0);
    }

    function test_inflationAttack_neutered() public {
        // Attacker deposits the dust then donates a large sum directly.
        _deposit(alice, 1);
        // Direct ERC20 transfer — bypasses deposit(), simulates donation.
        vm.prank(bob);
        usdc.transfer(address(vault), 50_000e6);

        // Honest user deposits a normal amount.
        uint256 bobShares = _deposit(bob, 100e6);
        // With the +1 virtual offset, Bob still receives a positive share
        // count well above zero — attacker can't price him out.
        assertGt(bobShares, 0);
        // Withdrawals should return a positive amount of USDC for Bob.
        vm.prank(bob);
        uint256 out = vault.withdraw(bobShares);
        assertGt(out, 0);
    }

    function test_operatorOnly_revertsForOthers() public {
        _deposit(alice, 1000e6);
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);

        vm.expectRevert(MarketMakerVault.NotOperator.selector);
        vm.prank(alice);
        vault.executeBuy(mid, Markets.Outcome.Yes, 10e6, 0);
    }

    function test_executeBuy_movesVaultUsdcAndAcquiresShares() public {
        _deposit(alice, 1000e6);
        bytes32 mid = _createMarket(17_000, block.timestamp + 7 days, 1000e6);

        uint256 navBefore = vault.nav();
        vm.prank(operator);
        uint256 sharesOut = vault.executeBuy(mid, Markets.Outcome.Yes, 100e6, 0);

        assertGt(sharesOut, 0);
        assertEq(vault.nav(), navBefore - 100e6);
        assertEq(markets.yesBalance(mid, address(vault)), sharesOut);
    }

    function test_fullCycle_winningTradeProfitsDepositors() public {
        // Alice and Bob each deposit 500 USDC.
        _deposit(alice, 500e6);
        _deposit(bob, 500e6);
        assertEq(vault.nav(), 1000e6);

        // Operator opens a YES position on a market that will ultimately resolve YES.
        bytes32 mid = _createMarket(17_000, block.timestamp + 2 days, 1000e6);
        vm.prank(operator);
        vault.executeBuy(mid, Markets.Outcome.Yes, 300e6, 0);

        // Market resolves YES.
        vm.warp(block.timestamp + 1 days);
        _attest(17_500);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        markets.resolve(mid);

        // Anyone can pull the winnings into the vault.
        vault.redeem(mid);

        // Vault NAV should now exceed 1000 — YES shares purchased at < $1
        // each settled at $1 each.
        assertGt(vault.nav(), 1000e6);

        // Both depositors withdraw and profit pro-rata.
        uint256 aliceShares = vault.sharesOf(alice);
        uint256 bobShares = vault.sharesOf(bob);
        vm.prank(alice);
        uint256 alicePayout = vault.withdraw(aliceShares);
        vm.prank(bob);
        uint256 bobPayout = vault.withdraw(bobShares);

        assertGt(alicePayout, 500e6);
        assertGt(bobPayout, 500e6);
        // And pro-rata since they deposited the same amount.
        assertApproxEqAbs(alicePayout, bobPayout, 2);
    }

    function test_rotateOperator() public {
        address newOp = makeAddr("newOp");

        vm.expectRevert(MarketMakerVault.NotOwner.selector);
        vm.prank(alice);
        vault.rotateOperator(newOp);

        vault.rotateOperator(newOp);
        assertEq(vault.operator(), newOp);
    }

    function test_pricePerShare_initiallyOneUsdc() public view {
        assertEq(vault.pricePerShare(), 1e6);
    }
}
