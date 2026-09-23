// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../MockUSDC.sol";
import {NanoLedger} from "../../src/nanopay/NanoLedger.sol";

contract NanoLedgerTest is Test {
    MockUSDC usdc;
    NanoLedger ledger;

    address alice = address(0xA11);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    function setUp() public {
        usdc = new MockUSDC();
        ledger = new NanoLedger(usdc, address(this)); // this = admin + governor
        for (uint256 i; i < 3; i++) {
            address a = [alice, bob, carol][i];
            usdc.mint(a, 1_000_000e6);
            vm.prank(a);
            usdc.approve(address(ledger), type(uint256).max);
        }
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(ledger)), ledger.totalOwed(), "insolvent");
    }

    function _dep(address a, uint256 amt) internal {
        vm.prank(a);
        ledger.deposit(amt);
    }

    // ───────────── deposit / withdraw ─────────────

    function test_deposit_withdraw_roundtrip() public {
        _dep(alice, 100e6);
        assertEq(ledger.balanceOf(alice), 100e6);
        assertEq(ledger.totalOwed(), 100e6);
        _solvent();

        uint256 walletBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ledger.withdraw(40e6);
        assertEq(usdc.balanceOf(alice) - walletBefore, 40e6);
        assertEq(ledger.balanceOf(alice), 60e6);
        assertEq(ledger.totalOwed(), 60e6);
        _solvent();
    }

    function test_withdraw_overBalanceReverts() public {
        _dep(alice, 10e6);
        vm.prank(alice);
        vm.expectRevert(NanoLedger.InsufficientBalance.selector);
        ledger.withdraw(11e6);
    }

    function test_deposit_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(NanoLedger.ZeroAmount.selector);
        ledger.deposit(0);
    }

    // ───────────── internal payments ─────────────

    function test_internalTransfer_isAccountingOnly() public {
        _dep(alice, 100e6);
        uint256 ledgerUsdcBefore = usdc.balanceOf(address(ledger));
        vm.prank(alice);
        ledger.internalTransfer(bob, 1); // sub-cent: 1 unit (0.000001 USDC)
        assertEq(ledger.balanceOf(alice), 100e6 - 1);
        assertEq(ledger.balanceOf(bob), 1);
        // no USDC moved: pure accounting
        assertEq(usdc.balanceOf(address(ledger)), ledgerUsdcBefore);
        assertEq(ledger.totalOwed(), 100e6);
        _solvent();
    }

    function test_internalTransfer_overBalanceReverts() public {
        _dep(alice, 5e6);
        vm.prank(alice);
        vm.expectRevert(NanoLedger.InsufficientBalance.selector);
        ledger.internalTransfer(bob, 6e6);
    }

    function test_batchPay() public {
        _dep(alice, 100e6);
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        to[0] = bob; amt[0] = 3e6;
        to[1] = carol; amt[1] = 2e6;
        vm.prank(alice);
        ledger.batchPay(to, amt);
        assertEq(ledger.balanceOf(bob), 3e6);
        assertEq(ledger.balanceOf(carol), 2e6);
        assertEq(ledger.balanceOf(alice), 95e6);
        _solvent();
    }

    function test_batchPay_lengthMismatchReverts() public {
        _dep(alice, 100e6);
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](1);
        vm.prank(alice);
        vm.expectRevert(NanoLedger.LengthMismatch.selector);
        ledger.batchPay(to, amt);
    }

    // ───────────── allowance / transferFromInternal ─────────────

    function test_transferFromInternal_withApproval() public {
        _dep(alice, 100e6);
        vm.prank(alice);
        ledger.approveSpender(bob, 30e6);
        vm.prank(bob); // bob is the spender (e.g. MarketsV4)
        ledger.transferFromInternal(alice, carol, 25e6);
        assertEq(ledger.balanceOf(alice), 75e6);
        assertEq(ledger.balanceOf(carol), 25e6);
        assertEq(ledger.allowance(alice, bob), 5e6);
        _solvent();
    }

    function test_transferFromInternal_overAllowanceReverts() public {
        _dep(alice, 100e6);
        vm.prank(alice);
        ledger.approveSpender(bob, 10e6);
        vm.prank(bob);
        vm.expectRevert(NanoLedger.InsufficientAllowance.selector);
        ledger.transferFromInternal(alice, carol, 11e6);
    }

    function test_transferFromInternal_infiniteAllowance() public {
        _dep(alice, 100e6);
        vm.prank(alice);
        ledger.approveSpender(bob, type(uint256).max);
        vm.prank(bob);
        ledger.transferFromInternal(alice, carol, 40e6);
        assertEq(ledger.allowance(alice, bob), type(uint256).max, "infinite allowance not decremented");
        _solvent();
    }

    function test_transferFromInternal_noAllowanceReverts() public {
        _dep(alice, 100e6);
        vm.prank(bob);
        vm.expectRevert(NanoLedger.InsufficientAllowance.selector);
        ledger.transferFromInternal(alice, carol, 1);
    }

    // ───────────── streams ─────────────

    function test_openStream_reservesFromFreeBalance() public {
        _dep(alice, 100e6);
        vm.prank(alice);
        uint256 id = ledger.openStream(bob, 1e6, 10e6); // 1 USDC/sec, cap 10
        assertEq(ledger.balanceOf(alice), 90e6, "reserved 10 from free");
        assertEq(ledger.totalOwed(), 100e6, "totalOwed unchanged by reservation");
        assertEq(id, 0);
        _solvent();
    }

    function test_openStream_overBalanceReverts() public {
        _dep(alice, 5e6);
        vm.prank(alice);
        vm.expectRevert(NanoLedger.InsufficientBalance.selector);
        ledger.openStream(bob, 1e6, 6e6);
    }

    function test_stream_accruesLinearlyAndSettles() public {
        _dep(alice, 100e6);
        vm.prank(alice);
        uint256 id = ledger.openStream(bob, 1e6, 10e6);

        vm.warp(block.timestamp + 4);
        assertEq(ledger.streamedSoFar(id), 4e6);
        ledger.settleStream(id); // permissionless poke
        assertEq(ledger.balanceOf(bob), 4e6);
        _solvent();

        // idempotent within same timestamp
        assertEq(ledger.settleStream(id), 0);

        vm.warp(block.timestamp + 100); // far past cap
        assertEq(ledger.streamedSoFar(id), 10e6, "capped at cap");
        ledger.settleStream(id);
        assertEq(ledger.balanceOf(bob), 10e6);
        (, , , , , , bool closed) = ledger.streams(id);
        assertTrue(closed, "auto-closed when fully streamed");
        _solvent();
    }

    function test_cancelStream_returnsUnstreamedRemainder() public {
        _dep(alice, 100e6);
        vm.prank(alice);
        uint256 id = ledger.openStream(bob, 1e6, 10e6);
        vm.warp(block.timestamp + 3);

        vm.prank(alice);
        ledger.cancelStream(id);
        assertEq(ledger.balanceOf(bob), 3e6, "accrued settled to receiver");
        assertEq(ledger.balanceOf(alice), 90e6 + 7e6, "remainder returned");
        assertEq(ledger.totalOwed(), 100e6);
        _solvent();
    }

    function test_cancelStream_onlySender() public {
        _dep(alice, 100e6);
        vm.prank(alice);
        uint256 id = ledger.openStream(bob, 1e6, 10e6);
        vm.prank(bob);
        vm.expectRevert(NanoLedger.NotStreamOwner.selector);
        ledger.cancelStream(id);
    }

    /// Audit HIGH regression: a maliciously huge ratePerSec must not overflow
    /// streamedSoFar and brick settle/cancel (which would lock the reserve).
    function test_stream_hugeRateDoesNotBrick() public {
        // Absolute warp targets: the test frame's own block.timestamp does not
        // reflect a prior vm.warp within the same function, so warp to fixed
        // values rather than block.timestamp + N.
        _dep(alice, 100e6);
        vm.prank(alice);
        uint256 id = ledger.openStream(bob, type(uint256).max, 10e6); // start = 1
        vm.warp(100);
        // would overflow under naive rate*elapsed; must just cap at cap.
        assertEq(ledger.streamedSoFar(id), 10e6);
        ledger.settleStream(id); // must not revert
        assertEq(ledger.balanceOf(bob), 10e6);
        _solvent();

        // a second huge-rate stream, cancelled, must also not revert.
        vm.prank(alice);
        uint256 id2 = ledger.openStream(carol, type(uint256).max, 5e6); // start = 100
        vm.warp(200);
        assertEq(ledger.streamedSoFar(id2), 5e6); // capped, no overflow
        vm.prank(alice);
        ledger.cancelStream(id2); // must not revert
        assertEq(ledger.balanceOf(carol), 5e6);
        _solvent();
    }

    function test_cancelStream_afterCloseReverts() public {
        _dep(alice, 100e6);
        vm.prank(alice);
        uint256 id = ledger.openStream(bob, 1e6, 10e6);
        vm.warp(block.timestamp + 100);
        ledger.settleStream(id); // fully streams + closes
        vm.prank(alice);
        vm.expectRevert(NanoLedger.StreamIsClosed.selector);
        ledger.cancelStream(id);
    }

    // ───────────── accrual pools ─────────────

    function _pool() internal returns (bytes32 pid) {
        ledger.setSource(address(this), true);
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(ledger), type(uint256).max);
        pid = keccak256("market-1");
        ledger.createPool(pid);
        ledger.setShares(pid, alice, 40);
        ledger.setShares(pid, bob, 20);
        ledger.setShares(pid, carol, 10);
    }

    function test_accrue_distributesByShareLazily() public {
        bytes32 pid = _pool();
        ledger.deposit(70e6); // source funds itself
        ledger.accrue(pid, 70e6); // 1 write distributes to all 3

        assertEq(ledger.claimablePool(pid, alice), 40e6);
        assertEq(ledger.claimablePool(pid, bob), 20e6);
        assertEq(ledger.claimablePool(pid, carol), 10e6);

        vm.prank(alice);
        ledger.claim(pid);
        assertEq(ledger.balanceOf(alice), 40e6);
        assertEq(ledger.claimablePool(pid, alice), 0, "claimed checkpoint advances");
        _solvent();
    }

    function test_accrue_dustStrandedNeverOverCredits() public {
        bytes32 pid = _pool(); // totalShares 70
        ledger.deposit(100);
        ledger.accrue(pid, 100); // 100 / 70 has dust
        uint256 sum = ledger.claimablePool(pid, alice)
            + ledger.claimablePool(pid, bob)
            + ledger.claimablePool(pid, carol);
        assertLe(sum, 100, "never distributes more than accrued");
        assertGe(sum, 97, "dust is small"); // 57+28+14 = 99
        _solvent();
    }

    function test_setShares_settlesBeforeReweight() public {
        bytes32 pid = _pool();
        ledger.deposit(70e6);
        ledger.accrue(pid, 70e6); // alice owed 40e6 at 40 shares
        // raise alice to 400 shares: must NOT retroactively pay the old accrual at the new weight
        ledger.setShares(pid, alice, 400);
        // alice's pre-existing 40e6 was banked to her balance on reweight
        assertEq(ledger.balanceOf(alice), 40e6);
        assertEq(ledger.claimablePool(pid, alice), 0);
        _solvent();
    }

    function test_createPool_onlySource() public {
        vm.prank(alice);
        vm.expectRevert(NanoLedger.NotSource.selector);
        ledger.createPool(keccak256("x"));
    }

    function test_accrue_onlyPoolSource() public {
        bytes32 pid = _pool();
        ledger.deposit(10e6);
        vm.prank(alice);
        vm.expectRevert(NanoLedger.NotPoolSource.selector);
        ledger.accrue(pid, 1e6);
    }

    // ───────────── governance / surplus ─────────────

    function test_skimSurplus_donationOnly() public {
        _dep(alice, 100e6);
        usdc.mint(address(ledger), 5e6); // donation / stray
        uint256 owedBefore = ledger.totalOwed();
        uint256 got = ledger.skimSurplus(carol);
        assertEq(got, 5e6);
        assertEq(usdc.balanceOf(carol) , 1_000_000e6 + 5e6);
        assertEq(ledger.totalOwed(), owedBefore, "owed untouched");
        assertEq(ledger.balanceOf(alice), 100e6, "balances untouched");
        _solvent();
    }

    function test_skimSurplus_nothingReverts() public {
        _dep(alice, 100e6);
        vm.expectRevert(NanoLedger.ZeroAmount.selector);
        ledger.skimSurplus(carol);
    }

    function test_setSource_onlyGovernor() public {
        vm.prank(alice);
        vm.expectRevert();
        ledger.setSource(bob, true);
    }

    // ───────────── gas: the real nanopayment properties ─────────────

    /// The core enabler: an internal payment costs the SAME whether it moves
    /// one unit (0.000001 USDC) or 50,000 USDC. Cost is decoupled from value,
    /// which is exactly what makes sub-cent flows economic.
    function test_gas_internalTransferIndependentOfAmount() public {
        _dep(alice, 200e6);
        vm.prank(alice); ledger.internalTransfer(bob, 1); // warm bob + alice slots

        vm.prank(alice);
        uint256 g0 = gasleft();
        ledger.internalTransfer(bob, 1); // 0.000001 USDC
        uint256 tiny = g0 - gasleft();

        vm.prank(alice);
        uint256 g1 = gasleft();
        ledger.internalTransfer(bob, 100e6); // 100 USDC
        uint256 large = g1 - gasleft();

        emit log_named_uint("internal transfer gas (1 unit)", tiny);
        emit log_named_uint("internal transfer gas (100 USDC)", large);
        // Storage cost is identical; the only delta is calldata/log byte encoding
        // (100e6 has more non-zero bytes than 1), which is a handful of gas.
        assertApproxEqAbs(tiny, large, 64, "gas independent of amount (modulo calldata bytes)");
    }

    /// Today's per-trade fee = three ERC20 pushes. With the ledger it is one
    /// accrue write (recipients claim lazily). Steady-state (warm) comparison.
    function test_gas_feeAccrualCheaperThan3Transfers() public {
        bytes32 pid = _pool();
        ledger.deposit(1_000e6);
        ledger.accrue(pid, 1e6); // warm accPerShare + source balance slots

        uint256 g0 = gasleft();
        ledger.accrue(pid, 1e6); // one write distributes to all 3 recipients
        uint256 accrueGas = g0 - gasleft();

        usdc.transfer(alice, 1e6); usdc.transfer(bob, 1e6); usdc.transfer(carol, 1e6); // warm
        uint256 g1 = gasleft();
        usdc.transfer(alice, 1e6); usdc.transfer(bob, 1e6); usdc.transfer(carol, 1e6); // today's 3 pushes
        uint256 threeTransfers = g1 - gasleft();

        emit log_named_uint("fee accrual gas (1 write)", accrueGas);
        emit log_named_uint("3 ERC20 fee transfers gas", threeTransfers);
        assertLt(accrueGas, threeTransfers, "accrual beats per-trade pushes");
    }
}
