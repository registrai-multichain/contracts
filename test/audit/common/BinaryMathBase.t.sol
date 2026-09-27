// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../../MockUSDC.sol";
import {Registry} from "../../../src/Registry.sol";
import {Attestation} from "../../../src/Attestation.sol";
import {Dispute} from "../../../src/Dispute.sol";
import {NanoLedger} from "../../../src/nanopay/NanoLedger.sol";
import {MarketsV4} from "../../../src/nanopay/MarketsV4.sol";
import {BinaryMarket} from "../../../src/nanopay/BinaryMarket.sol";

/// Shared full-stack deployment for the BinaryMarket math audit (MarketsV4 as the
/// concrete market). Audit-only helper, no tests of its own.
abstract contract BinaryMathBase is Test {
    MockUSDC usdc;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    NanoLedger ledger;
    MarketsV4 markets;

    address agent = address(0x0AC1E);
    address resolver = address(0xBEEF);
    address treasury = address(0x7AEA);
    address creator = address(0xC0FFEE);

    bytes32 feedId;
    uint256 constant DW = 1 hours; // feed dispute window
    uint256 constant WINDOW = 1 hours; // settlement window
    uint256 constant GRACE = 1 days;

    function _deploy() internal {
        vm.warp(3600);
        usdc = new MockUSDC();
        registry = new Registry(usdc, 10e6);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));
        ledger = new NanoLedger(usdc, address(this));
        markets = new MarketsV4(ledger, registry, attestation, address(this), treasury, WINDOW, GRACE);
        markets.setApprovedResolver(resolver, true);
        markets.setApprovedAgent(agent, true);
        markets.setApprovedCreator(creator, true);

        usdc.mint(agent, 1_000e6);
        vm.startPrank(agent);
        usdc.approve(address(registry), type(uint256).max);
        feedId = registry.createFeed("BTC/USD", keccak256("m"), 10e6, DW, resolver);
        registry.registerAgent(feedId, keccak256("m"), 100e6);
        vm.stopPrank();
        _fund(creator, 1e15);
    }

    function _fund(address a, uint256 amt) internal {
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(ledger), type(uint256).max);
        ledger.deposit(amt);
        ledger.approveSpender(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function _market(uint256 liq, uint256 ttl) internal returns (bytes32 id) {
        uint256 expiry = ((block.timestamp + ttl) / 5 minutes + 1) * 5 minutes;
        vm.prank(creator);
        id = markets.createMarket(feedId, agent, int256(100), BinaryMarket.Comparator.GreaterOrEqual, expiry, liq);
    }

    function _expiry(bytes32 id) internal view returns (uint256) {
        return markets.getMarket(id).expiry;
    }

    /// Warp to expiry, attest (yesWon when `yes`), let it finalize, resolve.
    function _resolve(bytes32 id, bool yes) internal {
        vm.warp(_expiry(id) + 1);
        vm.prank(agent);
        attestation.attest(feedId, yes ? int256(1000) : int256(0), keccak256(abi.encode(id, block.timestamp)));
        vm.warp(block.timestamp + DW);
        markets.resolve(id);
    }

    /// Warp past the settlement window with no reading; void.
    function _void(bytes32 id) internal {
        vm.warp(_expiry(id) + WINDOW + 1);
        markets.voidMarket(id);
    }

    function _buy(address who, bytes32 id, bool yes, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return markets.buy(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, amt, 0, type(uint256).max);
    }

    function _sell(address who, bytes32 id, bool yes, uint256 shares) internal returns (uint256) {
        vm.prank(who);
        return markets.sell(id, yes ? BinaryMarket.Outcome.Yes : BinaryMarket.Outcome.No, shares, 0, type(uint256).max);
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "ledger insolvent");
    }
}
