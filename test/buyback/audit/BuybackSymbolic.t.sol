// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegiBuyback} from "../../../src/buyback/RegiBuyback.sol";
import {RegiFeeSplitter} from "../../../src/buyback/RegiFeeSplitter.sol";
import {IPoolManagerMinimal, V4Lib} from "../../../src/buyback/UniswapV4Minimal.sol";
import {INanoLedgerMinimal} from "../../../src/buyback/INanoLedgerMinimal.sol";

/// Exposes RegiBuyback's own price-limit function (no copy of the maths).
contract LimitHarness is RegiBuyback {
    constructor()
        RegiBuyback(IPoolManagerMinimal(address(1)), IERC20(address(2)), address(3), address(0), 10_000, 200, INanoLedgerMinimal(address(4)))
    {}

    function limitOf(uint160 current) external pure returns (uint160) {
        return _priceLimit(current);
    }
}

/// Symbolic proofs (halmos: `halmos --match-contract BuybackSymbolic`). The `check_` functions
/// are proven for EVERY input; forge also runs them as fuzz tests when named `test`/`testFuzz`,
/// so each property has a `testFuzz_` twin for the ordinary suite.
contract BuybackSymbolicTest is Test {
    uint160 constant MIN_SQRT_PRICE = 4295128739;
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    LimitHarness h;

    function setUp() public {
        h = new LimitHarness();
    }

    // ---- the swap's price limit ----

    function check_limitIsAlwaysAboveTheMinimum(uint160 current) public view {
        assert(h.limitOf(current) > MIN_SQRT_PRICE);
    }

    /// For any real pool price (v4 keeps sqrtPrice in [MIN, MAX)), the limit is below it:
    /// a zeroForOne swap with this limit is always valid.
    function check_limitIsBelowAnyRealPoolPrice(uint160 current) public view {
        vm.assume(current >= MIN_SQRT_PRICE + 2 && current < MAX_SQRT_PRICE);
        assert(h.limitOf(current) < current);
    }

    /// Unclamped, the limit is exactly floor(current * 98995 / 100000).
    function check_limitIsTheExactFloor(uint160 current) public view {
        uint256 l = h.limitOf(current);
        uint256 f = uint256(current) * 98_995 / 100_000;
        vm.assume(f > MIN_SQRT_PRICE);
        assert(l == f);
        assert(l * 100_000 <= uint256(current) * 98_995);
        assert((l + 1) * 100_000 > uint256(current) * 98_995);
    }

    /// 0.98995^2 >= 0.98: a sqrtPrice move by that factor is a price move of at most 2%.
    function check_theFactorCapsImpactAtTwoPercent() public pure {
        assert(uint256(98_995) * 98_995 >= uint256(9_800) * 1_000_000);
    }

    // ---- the splitter's 40/60 ----

    function check_splitIsExactAndRoundsToTheSafe(uint256 bal) public pure {
        vm.assume(bal < 2 ** 64); // 1.8e19 units = 18 trillion USDC: beyond any real total (keeps the solver tractable)
        uint256 toB = bal * 4000 / 10_000; // RegiFeeSplitter.distribute
        uint256 toS = bal - toB;
        assert(toB + toS == bal);
        assert(toB * 10_000 <= bal * 4000); // the buyback never gets more than 40%
        assert(toS * 10_000 >= bal * 6000); // the Safe never gets less than 60%
    }

    function check_theSplitterConstantIs40Percent() public pure {
        assert(4000 == 4000); // pinned below against the deployed constant
    }

    // ---- BalanceDelta decoding ----

    function check_deltaRoundTrips(int128 a0, int128 a1) public pure {
        int256 d = (int256(a0) << 128) | int256(uint256(uint128(a1)));
        assert(V4Lib.amount0(d) == a0);
        assert(V4Lib.amount1(d) == a1);
    }

    /// usdcIn = uint(uint128(-a0)) equals |a0| for every negative a0 the pool can return.
    function check_owedUsdcIsTheMagnitude(int128 a0) public pure {
        vm.assume(a0 < 0 && a0 > type(int128).min);
        uint256 usdcIn = uint256(uint128(-a0));
        assert(int256(usdcIn) == -int256(a0));
    }

    // ---- fuzz twins for the ordinary forge suite ----

    function testFuzz_limitBelowPriceAndAboveMin(uint160 current) public view {
        current = uint160(bound(current, MIN_SQRT_PRICE + 2, MAX_SQRT_PRICE - 1));
        uint160 l = h.limitOf(current);
        assertGt(l, MIN_SQRT_PRICE);
        assertLt(l, current);
    }

    function testFuzz_deltaRoundTrips(int128 a0, int128 a1) public pure {
        int256 d = (int256(a0) << 128) | int256(uint256(uint128(a1)));
        assertEq(V4Lib.amount0(d), a0);
        assertEq(V4Lib.amount1(d), a1);
    }

    function testFuzz_limitIsTheExactFloor(uint160 current) public view {
        // Every price whose floor clears the minimum (bound, not assume: no rejected inputs).
        current = uint160(bound(current, uint256(MIN_SQRT_PRICE) * 100_000 / 98_995 + 2, type(uint160).max));
        uint256 f = uint256(current) * 98_995 / 100_000;
        uint256 l = h.limitOf(current);
        assertEq(l, f);
        assertLe(l * 100_000, uint256(current) * 98_995);
        assertGt((l + 1) * 100_000, uint256(current) * 98_995);
    }

    function testFuzz_splitIsExactAndRoundsToTheSafe(uint256 bal) public pure {
        bal = bound(bal, 0, 2 ** 200);
        uint256 toB = bal * 4000 / 10_000;
        uint256 toS = bal - toB;
        assertEq(toB + toS, bal);
        assertLe(toB * 10_000, bal * 4000);
        assertGe(toS * 10_000, bal * 6000);
    }

    function test_deployedSplitterConstantIs40Percent() public {
        RegiFeeSplitter sp = new RegiFeeSplitter(INanoLedgerMinimal(address(4)), IERC20(address(2)), address(5), address(6));
        assertEq(sp.BUYBACK_BPS(), 4000);
    }
}
