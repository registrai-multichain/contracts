// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../src/Registry.sol";
import {Attestation} from "../src/Attestation.sol";
import {Dispute} from "../src/Dispute.sol";
import {Markets} from "../src/Markets.sol";
import {CirqueLending, IBTCPriceOracle} from "../src/CirqueLending.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract MockCirBTC is ERC20 {
    constructor() ERC20("Mock cirBTC", "cirBTC") {}
    function decimals() public pure override returns (uint8) { return 8; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockBtcOracle is IBTCPriceOracle {
    uint256 p; uint256 t;
    constructor(uint256 initial) { p = initial; t = block.timestamp; }
    function getBTCPrice() external view returns (uint256, uint256) { return (p, t); }
    function setPrice(uint256 np) external { p = np; t = block.timestamp; }
}

/// Full-stack leveraged-bet tests: real Registry/Attestation/Dispute/Markets +
/// CirqueLending. cirBTC (8dp) collateral, USDC (6dp) debt + market currency.
contract CirqueLeveragedTest is Test {
    MockUSDC usdc;
    MockCirBTC cirbtc;
    MockBtcOracle oracle;
    Registry registry;
    Attestation attestation;
    Dispute dispute;
    Markets markets;
    CirqueLending lending;

    address deployer = address(this);
    address agent = makeAddr("agent");        // feed creator + agent
    address resolver = makeAddr("resolver");
    address mm = makeAddr("marketCreator");   // seeds market liquidity
    address alice = makeAddr("alice");        // leveraged bettor
    address lola = makeAddr("lola");          // USDC supplier
    address liquidator = makeAddr("liquidator");
    address treasury = makeAddr("treasury");

    bytes32 constant METH = keccak256("ipfs://m");
    uint256 constant DW = 1 days;
    uint256 constant MIN_BOND = 100e6;
    uint256 constant BTC_45K = 45_000e18;

    bytes32 feedId;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        cirbtc = new MockCirBTC();
        oracle = new MockBtcOracle(BTC_45K);

        registry = new Registry(usdc);
        attestation = new Attestation(registry);
        dispute = new Dispute(registry, attestation, usdc);
        markets = new Markets(attestation, registry, usdc, treasury);
        registry.wire(address(attestation), address(dispute));
        attestation.wire(address(dispute));

        lending = new CirqueLending(
            IERC20(address(cirbtc)),
            IERC20(address(usdc)),
            markets,
            IBTCPriceOracle(address(oracle)),
            deployer,   // owner
            treasury    // forfeited positions route here
        );

        // Fund actors.
        usdc.mint(agent, 10_000e6);
        usdc.mint(mm, 1_000_000e6);
        usdc.mint(lola, 1_000_000e6);
        usdc.mint(alice, 100_000e6);
        usdc.mint(liquidator, 100_000e6);
        cirbtc.mint(alice, 5e8);

        // Feed + agent.
        vm.prank(agent);
        feedId = registry.createFeed("Warsaw resi", METH, MIN_BOND, DW, resolver);
        vm.startPrank(agent);
        usdc.approve(address(registry), MIN_BOND);
        registry.registerAgent(feedId, METH, MIN_BOND);
        vm.stopPrank();

        // Supplier seeds the lending pool with 1,000 USDC (the cap).
        vm.startPrank(lola);
        usdc.approve(address(lending), 1_000e6);
        lending.supplyUSDC(1_000e6);
        vm.stopPrank();
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _market(int256 threshold, uint256 expiry) internal returns (bytes32 mid) {
        vm.startPrank(mm);
        usdc.approve(address(markets), 1_000e6);
        mid = markets.createMarket(feedId, agent, threshold, Markets.Comparator.GreaterThan, expiry, 1_000e6);
        vm.stopPrank();
    }

    function _resolve(bytes32 mid, int256 attestValue, uint256 marketExpiry) internal {
        // Attest before expiry so valueAt(feedId, agent, expiry) finds it.
        vm.warp(marketExpiry - 1 hours);
        vm.prank(agent);
        attestation.attest(feedId, attestValue, keccak256(abi.encode(attestValue, block.timestamp)));
        // Warp past both market expiry and the attestation's dispute window.
        vm.warp(marketExpiry + DW + 1);
        markets.resolve(mid);
    }

    // ─────────────────────────── tests ───────────────────────────

    function test_leverageAndBet_opensPositionAndHoldsShares() public {
        bytes32 mid = _market(17_000, block.timestamp + 30 days);

        vm.startPrank(alice);
        cirbtc.approve(address(lending), 1e8);
        (uint256 health, uint256 sharesOut) =
            lending.leverageAndBet(1e8, 200e6, mid, true, 0);
        vm.stopPrank();

        // 1 cirBTC ($45k), 200 USDC borrow → 200/45000 ≈ 44 bps. Safe.
        assertApproxEqAbs(health, 44, 2);
        assertGt(sharesOut, 0);

        // Shares held by the lending contract, not alice.
        assertEq(markets.yesBalance(mid, address(lending)), sharesOut);
        assertEq(markets.yesBalance(mid, alice), 0);

        // Loan records the position.
        ( , uint256 prin, , bool active, bytes32 m, bool betYes, uint256 bs) = lending.loans(alice);
        assertEq(prin, 200e6);
        assertTrue(active);
        assertEq(m, mid);
        assertTrue(betYes);
        assertEq(bs, sharesOut);

        // Borrowed USDC went into the market, not alice's wallet.
        assertEq(usdc.balanceOf(alice), 100_000e6);
        assertEq(lending.totalBorrowedPrincipal(), 200e6);
    }

    function test_plainRepay_onLeveraged_reverts() public {
        bytes32 mid = _market(17_000, block.timestamp + 30 days);
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 1e8);
        lending.leverageAndBet(1e8, 200e6, mid, true, 0);
        vm.expectRevert(CirqueLending.HasLeveragedPosition.selector);
        lending.repay();
        vm.stopPrank();
    }

    function test_closePosition_returnsCollateralAndSettles() public {
        bytes32 mid = _market(17_000, block.timestamp + 30 days);
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 1e8);
        lending.leverageAndBet(1e8, 200e6, mid, true, 0);

        uint256 cirBefore = cirbtc.balanceOf(alice);
        // Close immediately — the round-trip sell returns slightly less than
        // owed (AMM fees), so _settle pulls the small shortfall from alice.
        usdc.approve(address(lending), 500e6);
        lending.closePosition(0);
        vm.stopPrank();

        // Loan cleared, collateral returned.
        ( , , , bool active, , ,) = lending.loans(alice);
        assertFalse(active);
        assertEq(cirbtc.balanceOf(alice) - cirBefore, 1e8);
        assertEq(lending.totalBorrowedPrincipal(), 0);
    }

    function test_redeemAtExpiry_winningBet_profitsBorrower() public {
        uint256 expiry = block.timestamp + 2 days;
        bytes32 mid = _market(17_000, expiry);
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 1e8);
        lending.leverageAndBet(1e8, 200e6, mid, true, 0);
        vm.stopPrank();

        // YES wins (attested 17,500 > 17,000 threshold).
        _resolve(mid, 17_500, expiry);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 cirBefore = cirbtc.balanceOf(alice);
        vm.prank(alice);
        lending.redeemAtExpiry();

        // Winning shares redeem at 1 USDC each = sharesOut USDC. Owed ≈ 200
        // USDC + tiny interest. Borrower nets (sharesOut − owed) USDC + cirBTC.
        assertEq(cirbtc.balanceOf(alice) - cirBefore, 1e8);
        // sharesOut > 200e6 (bought YES below 50¢-ish), so profit is positive.
        assertGt(usdc.balanceOf(alice), usdcBefore);
        ( , , , bool active, , ,) = lending.loans(alice);
        assertFalse(active);
    }

    function test_redeemAtExpiry_losingBet_borrowerCoversDebt() public {
        uint256 expiry = block.timestamp + 2 days;
        bytes32 mid = _market(17_000, expiry);
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 1e8);
        lending.leverageAndBet(1e8, 200e6, mid, false, 0); // bet NO
        vm.stopPrank();

        // YES wins → alice's NO bet loses, shares worthless.
        _resolve(mid, 17_500, expiry);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 cirBefore = cirbtc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(lending), 500e6); // cover owed
        lending.redeemAtExpiry();
        vm.stopPrank();

        // Borrower paid the full debt out of pocket, got cirBTC back.
        assertEq(cirbtc.balanceOf(alice) - cirBefore, 1e8);
        assertLt(usdc.balanceOf(alice), usdcBefore); // paid debt, no payout
        ( , , , bool active, , ,) = lending.loans(alice);
        assertFalse(active);
    }

    function test_liquidate_leveraged_forfeitsPositionToTreasury() public {
        bytes32 mid = _market(17_000, block.timestamp + 30 days);
        // 0.05 cirBTC ($2,250 at $45k) collateral, borrow 900 USDC (40% LTV,
        // fits the 1,000-USDC pool).
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 5e6);
        ( , uint256 sharesOut) = lending.leverageAndBet(5e6, 900e6, mid, true, 0);
        vm.stopPrank();

        // BTC crashes 45k → 18k. 0.05×18000 = $900 collateral, 900/900 = 100%
        // LTV > 65% → liquidatable.
        oracle.setPrice(18_000e18);
        assertGt(lending.healthBps(alice), lending.LIQ_LTV_BPS());

        vm.startPrank(liquidator);
        usdc.approve(address(lending), 30_000e6);
        lending.liquidate(alice);
        vm.stopPrank();

        // Position forfeited to treasury ledger; loan cleared.
        assertEq(lending.treasuryYesShares(mid), sharesOut);
        ( , , , bool active, , ,) = lending.loans(alice);
        assertFalse(active);
        // The shares still physically sit in the lending contract's balance.
        assertEq(markets.yesBalance(mid, address(lending)), sharesOut);
    }

    function test_sweepToTreasury_resolvedWinner_paysTreasury() public {
        uint256 expiry = block.timestamp + 2 days;
        bytes32 mid = _market(17_000, expiry);
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 5e6);
        ( , uint256 sharesOut) = lending.leverageAndBet(5e6, 900e6, mid, true, 0);
        vm.stopPrank();

        oracle.setPrice(18_000e18);
        vm.startPrank(liquidator);
        usdc.approve(address(lending), 30_000e6);
        lending.liquidate(alice);
        vm.stopPrank();

        // YES wins; sweep redeems the forfeited shares to the treasury.
        _resolve(mid, 17_500, expiry);

        uint256 treasBefore = usdc.balanceOf(treasury);
        lending.sweepToTreasury(mid, true); // permissionless
        // Winning shares = 1 USDC each.
        assertEq(usdc.balanceOf(treasury) - treasBefore, sharesOut);
        assertEq(lending.treasuryYesShares(mid), 0);
    }

    function test_sweep_nothing_reverts() public {
        bytes32 mid = _market(17_000, block.timestamp + 2 days);
        vm.expectRevert(CirqueLending.NothingToSweep.selector);
        lending.sweepToTreasury(mid, true);
    }

    function test_sweep_whileTrading_reverts() public {
        // Forfeited positions can only be swept after resolution (no thin-AMM
        // forced sell). Set up a forfeit, then try to sweep while still trading.
        bytes32 mid = _market(17_000, block.timestamp + 30 days);
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 5e6);
        lending.leverageAndBet(5e6, 900e6, mid, true, 0);
        vm.stopPrank();
        oracle.setPrice(18_000e18);
        vm.startPrank(liquidator);
        usdc.approve(address(lending), 30_000e6);
        lending.liquidate(alice);
        vm.stopPrank();

        vm.expectRevert(CirqueLending.MarketNotResolved.selector);
        lending.sweepToTreasury(mid, true); // market still trading
    }

    // ─── Regression: multi-claimant redeem must not over-credit suppliers
    //     or strand a second winner (the redeemPot escrow fix). ───
    function test_multiClaimant_redeem_noOverdrawNoStrand() public {
        address bob2 = makeAddr("bob2");
        cirbtc.mint(bob2, 5e8);
        usdc.mint(bob2, 100_000e6);

        uint256 expiry = block.timestamp + 2 days;
        bytes32 mid = _market(17_000, expiry);

        // Two bettors, same market, both YES.
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 1e8);
        ( , uint256 sA) = lending.leverageAndBet(1e8, 200e6, mid, true, 0);
        vm.stopPrank();
        vm.startPrank(bob2);
        cirbtc.approve(address(lending), 1e8);
        ( , uint256 sB) = lending.leverageAndBet(1e8, 200e6, mid, true, 0);
        vm.stopPrank();

        _resolve(mid, 17_500, expiry); // YES wins; both win

        // Claimant 1 (alice) redeems — this pulls BOTH winners' USDC into the
        // contract. The pot must keep bob2's slice escrowed (out of pool value).
        vm.prank(alice);
        lending.redeemAtExpiry();
        assertEq(lending.redeemPot(mid), sB);
        assertEq(lending.totalRedeemPot(), sB);

        // A supplier withdraws in the window. With the fix, pool value excludes
        // bob2's escrowed winning USDC, so lola can't overdraw it.
        uint256 lolaShares = lending.shares(lola);
        vm.prank(lola);
        lending.withdrawUSDC(lolaShares / 2);

        // Claimant 2 (bob2) must still be fully paid — not stranded.
        uint256 bob2Before = usdc.balanceOf(bob2);
        uint256 owedB = 200e6 + lending.interestOwed(bob2); // principal + accrued
        vm.prank(bob2);
        lending.redeemAtExpiry();
        // bob2's winning shares (sB) − owed = profit, paid in full from the
        // escrow that alice's redeem pulled in (proves no stranding).
        assertGt(usdc.balanceOf(bob2), bob2Before);
        assertEq(usdc.balanceOf(bob2) - bob2Before, sB - owedB);

        // Escrow fully drained.
        assertEq(lending.redeemPot(mid), 0);
        assertEq(lending.totalRedeemPot(), 0);
    }

    // ─── Regression: borrower not trapped if a market expires but never
    //     resolves (agent inactive). Escape hatch settles + forfeits. ───
    function test_redeemAtExpiry_deadZone_escapeHatch() public {
        uint256 expiry = block.timestamp + 2 days;
        bytes32 mid = _market(17_000, expiry);
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 1e8);
        ( , uint256 sharesOut) = lending.leverageAndBet(1e8, 200e6, mid, true, 0);
        vm.stopPrank();

        // Warp past expiry WITHOUT ever attesting/resolving → stuck dead zone.
        vm.warp(expiry + 1);

        uint256 cirBefore = cirbtc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(lending), 500e6); // cover owed from wallet
        lending.redeemAtExpiry();
        vm.stopPrank();

        // cirBTC reclaimed, loan cleared, position forfeited to treasury.
        assertEq(cirbtc.balanceOf(alice) - cirBefore, 1e8);
        ( , , , bool active, , ,) = lending.loans(alice);
        assertFalse(active);
        assertEq(lending.treasuryYesShares(mid), sharesOut);
    }

    function test_redeemAtExpiry_beforeExpiry_reverts() public {
        bytes32 mid = _market(17_000, block.timestamp + 30 days);
        vm.startPrank(alice);
        cirbtc.approve(address(lending), 1e8);
        lending.leverageAndBet(1e8, 200e6, mid, true, 0);
        // Market live, not resolved → must use closePosition, not redeem.
        vm.expectRevert(CirqueLending.MarketStillTrading.selector);
        lending.redeemAtExpiry();
        vm.stopPrank();
    }
}
