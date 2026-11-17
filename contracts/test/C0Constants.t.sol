// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {QZConstants as C} from "../src/lib/QZConstants.sol";
import {QZCurveMath} from "../src/lib/QZCurveMath.sol";

/// @notice Every relation the spec states between its numbers, proven on `QZConstants`.
contract C0ConstantsTest is Test {
    // §1.3 supply, tiers, weights
    function test_supplyAndTiers() public pure {
        assertEq(C.TOTAL_SUPPLY, 2222 * C.UNIT);
        assertEq(C.TIER_I_COUNT + C.TIER_II_COUNT + C.TIER_III_COUNT + C.TIER_IV_COUNT, C.STANDARD_MACHINES);
        assertEq(C.STANDARD_MACHINES + C.RELIC_COUNT, C.TOTAL_MACHINES);
        assertEq(C.LAST_RELIC_ID, C.TOTAL_MACHINES);
        assertEq(C.FIRST_RELIC_ID, C.STANDARD_MACHINES + 1);
        assertEq(C.LAST_RELIC_ID - C.FIRST_RELIC_ID + 1, C.RELIC_COUNT);
        // §1.3 "1200/650/280/90 divisible by 10 tracks, 222 per track"
        assertEq(C.TIER_I_COUNT, C.TIER_I_PER_TRACK * C.TRACK_COUNT);
        assertEq(C.TIER_II_COUNT, C.TIER_II_PER_TRACK * C.TRACK_COUNT);
        assertEq(C.TIER_III_COUNT, C.TIER_III_PER_TRACK * C.TRACK_COUNT);
        assertEq(C.TIER_IV_COUNT, C.TIER_IV_PER_TRACK * C.TRACK_COUNT);
        assertEq(
            C.TIER_I_PER_TRACK + C.TIER_II_PER_TRACK + C.TIER_III_PER_TRACK + C.TIER_IV_PER_TRACK, C.MACHINES_PER_TRACK
        );
        assertEq(C.MACHINES_PER_TRACK * C.TRACK_COUNT, C.STANDARD_MACHINES);
    }

    // §2.5 integer weights (x10 of 1 / 1.5 / 2.5 / 4), §1.3 total 3235
    function test_weights() public pure {
        assertEq(C.WEIGHT_TIER_I, 10);
        assertEq(C.WEIGHT_TIER_II, 15);
        assertEq(C.WEIGHT_TIER_III, 25);
        assertEq(C.WEIGHT_TIER_IV, 40);
        assertEq(C.weightOf(1), 10);
        assertEq(C.weightOf(4), 40);
        uint256 total = C.TIER_I_COUNT * C.WEIGHT_TIER_I + C.TIER_II_COUNT * C.WEIGHT_TIER_II + C.TIER_III_COUNT
            * C.WEIGHT_TIER_III + C.TIER_IV_COUNT * C.WEIGHT_TIER_IV;
        assertEq(total, C.TOTAL_STANDARD_WEIGHT);
        assertEq(total / 10, 3235);
        assertEq(C.RELIC_SHARE_BPS, 1000); // 10% of each track, 5% per relic
        assertEq(C.RELIC_SHARE_BPS / C.RELIC_COUNT, 500);
    }

    // §1.4 fee splits
    function test_feeSplits() public pure {
        assertEq(C.HOOK_FEE_BPS, 300);
        assertEq(C.HOOK_REWARD_BPS + C.HOOK_LP_BPS + C.HOOK_CIRCUIT_BPS + C.HOOK_TREASURY_BPS, C.HOOK_FEE_BPS);
        assertEq(C.HOOK_REWARD_BPS, 200);
        assertEq(C.HOOK_LP_BPS, 50);
        assertEq(C.HOOK_CIRCUIT_BPS, 25);
        assertEq(C.HOOK_TREASURY_BPS, 25);
        assertEq(C.CURVE_FEE_BPS, 100);
        assertEq(C.CURVE_REWARD_BPS + C.CURVE_TREASURY_BPS, C.CURVE_FEE_BPS);
        assertEq(C.CURVE_REWARD_BPS, 75);
        assertEq(C.CURVE_TREASURY_BPS, 25);
        assertEq(C.ROYALTY_REWARD_BPS + C.ROYALTY_TREASURY_BPS, C.ROYALTY_BPS);
        assertEq(C.ROYALTY_BPS, 500);
    }

    // §1.5 phases and limits
    function test_phasesAndLimits() public pure {
        assertEq(C.F0_DURATION, 30 minutes);
        assertEq(C.F1_END, 120 minutes);
        assertEq(C.F0_MAX_PER_WALLET, 2e18);
        assertEq(C.F1_MAX_PER_TX, 2e18);
        assertEq(C.F1_MAX_PER_WALLET, 10e18);
        assertEq(C.F2_MAX_PER_TX, 20e18);
    }

    // §1.6 curve parameters and their relations
    function test_curveParameters() public pure {
        assertEq(C.CURVE_SUPPLY, 1777.6e18);
        assertEq(C.POOL_SUPPLY, 444.4e18);
        assertEq(C.CURVE_SUPPLY + C.POOL_SUPPLY, C.TOTAL_SUPPLY); // G = 2222 - S
        assertEq(C.CURVE_SUPPLY * 100 / C.TOTAL_SUPPLY, 80); // 80/20
        assertEq(C.X0, 733_333_333_333_333_334); // E / 3 = 0.7333... ETH, rounded up to a whole wei
        assertEq(C.TARGET_ETH, 2.2 ether);
        assertEq(C.CURVE_K, C.X0 * C.Y0);
    }

    /// @dev Y0 ~ S^2 / (S - G) = 2370.1333...e18. X0 = E/3 is not a whole wei, so Y0 is the round-up that keeps
    ///      `E = X0 x S / (Y0 - S)` exact: `Y0 = S + S x X0 / E` (documented in QZConstants).
    function test_Y0IsTheRoundUpThatKeepsETargetExact() public pure {
        uint256 num = C.CURVE_SUPPLY * C.CURVE_SUPPLY;
        uint256 den = C.CURVE_SUPPLY - C.POOL_SUPPLY;
        uint256 idealCeil = (num + den - 1) / den;
        assertGt(num % den, 0); // not exact in wei: 2370.1333...e18
        assertEq(idealCeil, 2_370_133_333_333_333_333_334);
        assertGe(C.Y0, idealCeil); // rounded up, never down
        assertEq(C.Y0 - idealCeil, 538); // 538 wei above the ideal, 2.3e-19 relative
        assertEq(C.CURVE_SUPPLY % C.TARGET_ETH, 0); // S / E = 808 exactly
        assertEq(C.Y0, C.CURVE_SUPPLY + C.CURVE_SUPPLY / C.TARGET_ETH * C.X0);
        assertEq(C.Y0, 2_370_133_333_333_333_333_872);
        assertEq(3 * C.X0 - C.TARGET_ETH, 2); // X0 = ceil(E / 3)
    }

    /// @dev §1.6 "E = X0 x S / (Y0 - S)": the constant 2.2 ETH equals the formula exactly (0 wei).
    function test_targetEquationHoldsExactly() public pure {
        uint256 d = C.Y0 - C.CURVE_SUPPLY;
        assertEq(C.TARGET_ETH * d, C.X0 * C.CURVE_SUPPLY); // E * d == X0 * S, 0 wei off
        // and the curve reserve at s = S is exactly E (I9 cap)
        assertEq(QZCurveMath.reserveAt(C.CURVE_SUPPLY), C.TARGET_ETH);
    }

    /// @dev §1.6 "graduation pool price == final curve price": E/G == (X0+E)/(Y0-S) within 1e-18 relative (X0 is not
    ///      a whole wei: the gap is 6.8e-19), and both v4 sqrt prices agree to 1e-18 relative.
    function test_graduationPoolPriceEqualsFinalCurvePrice() public pure {
        uint256 d = C.Y0 - C.CURVE_SUPPLY;
        uint256 lhs = C.TARGET_ETH * d; // E/G = (X0+E)/d  <=>  E*d = (X0+E)*G
        uint256 rhs = (C.X0 + C.TARGET_ETH) * C.POOL_SUPPLY;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        assertLt(diff * 1e18, lhs);

        for (uint256 i = 0; i < 2; i++) {
            bool qzIsCurrency0 = i == 0;
            uint256 fromPool = QZCurveMath.graduationSqrtPriceX96(qzIsCurrency0);
            // curve price in the same orientation: WETH per QZ = (X0+E)/d; inverted when QZ is currency1.
            uint256 ratioX192 = qzIsCurrency0
                ? FullMath.mulDiv(C.X0 + C.TARGET_ETH, 1 << 192, d)
                : FullMath.mulDiv(d, 1 << 192, C.X0 + C.TARGET_ETH);
            uint256 fromCurve = FixedPointMathLib.sqrt(ratioX192);
            uint256 sqrtDiff = fromPool > fromCurve ? fromPool - fromCurve : fromCurve - fromPool;
            assertLt(sqrtDiff * 1e18, fromPool);
        }
    }

    /// @dev §1.6 price table: start 0.000309 ETH/QZ (X0/Y0), final 0.00495 ETH/QZ (E/G), 16x.
    function test_priceTable() public pure {
        uint256 start = QZCurveMath.priceAt(0, 0);
        uint256 end = QZCurveMath.priceAt(C.CURVE_SUPPLY, C.TARGET_ETH);
        assertApproxEqAbs(start, 0.000309 ether, 0.000001 ether);
        assertApproxEqAbs(end, 0.00495 ether, 0.000001 ether);
        assertEq(end * 1e18 / start / 1e14, 160_000); // 16.0000x (4 decimals)
        assertEq(end, C.TARGET_ETH * 1e18 / C.POOL_SUPPLY); // E/G
    }

    // §4.3 / §2.5 / §3.2 times
    function test_timesAndConverter() public pure {
        assertEq(C.EPOCH_DURATION, 120);
        assertEq(C.REVEAL_ROLLOVER, 3600);
        assertEq(C.ONION_LENGTH, 2_630_160);
        assertEq(C.ONION_LENGTH, 3653 days / C.EPOCH_DURATION);
        // One link per epoch covers 10 years, leap days included (any 10 calendar years span at most 3653 days).
        assertGe(C.ONION_LENGTH * C.EPOCH_DURATION, 3653 days);
        assertEq(C.FIRST_OPEN_EPOCH_DELAY, 24 hours);
        assertEq(C.OPEN_EPOCH_INTERVAL, 60);
        assertEq(C.CONVERT_FLOOR_BPS, 9700);
        assertEq(C.MAX_SPOT_DEVIATION_BPS, 300);
        assertEq(C.MIN_OBSERVATIONS, 9);
        assertEq(C.MEDIAN_WINDOW, 30 minutes);
        assertEq(C.FALLBACK_MIN_OBSERVATIONS, 25);
        assertEq(C.FALLBACK_MIN_OBSERVATION_SPACING, 5 minutes);
        assertEq(C.FALLBACK_WINDOW, 2 hours);
        assertGe(C.FALLBACK_MIN_OBSERVATIONS * C.FALLBACK_MIN_OBSERVATION_SPACING, C.FALLBACK_WINDOW);
        assertEq(C.DEFAULT_MAX_CHUNK, 0.5 ether);
        assertEq(C.NFLX_MAX_CHUNK, 0.1 ether);
        assertEq(C.DEFAULT_FALLBACK_DAILY_CAP, 0.05 ether);
        assertEq(C.CIRCUIT_WEEK, 7 days);
        assertEq(C.REDIRECT_DELAY, 180 days);
    }

    // §5.2 LayerZero
    function test_layerZero() public pure {
        assertEq(C.EID_ROBINHOOD, 30416);
        assertEq(C.EID_INK, 30339);
        assertEq(C.EID_BASE, 30184);
        assertEq(C.MAX_UNITS_PER_MESSAGE, 10);
        assertEq(C.OFT_SHARED_DECIMALS, 6);
        assertEq(C.LZ_CONFIRMATIONS, 30);
        assertEq(C.GAS_ONFT_HOME_TO_SPOKE, 120_000);
        assertEq(C.GAS_ONFT_SPOKE_TO_HOME, 190_000);
        assertEq(C.GAS_OFT_HOME_TO_SPOKE, 100_000);
        assertEq(C.GAS_OFT_SPOKE_TO_HOME, 1_200_000);
        assertEq(C.LZ_REQUIRED_DVN_COUNT + C.LZ_OPTIONAL_DVN_THRESHOLD, 3); // 3 attestations per message
    }

    // §5.1 hook permissions
    function test_hookFlags() public pure {
        uint160 f = C.HOOK_FLAGS;
        assertTrue(f & Hooks.BEFORE_INITIALIZE_FLAG != 0);
        assertTrue(f & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0);
        assertTrue(f & Hooks.BEFORE_SWAP_FLAG != 0);
        assertTrue(f & Hooks.AFTER_SWAP_FLAG != 0);
        assertTrue(f & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0);
        assertTrue(f & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG == 0);
        assertTrue(f & Hooks.AFTER_ADD_LIQUIDITY_FLAG == 0);
        assertTrue(f & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG == 0);
    }

    function test_poolTickBounds() public pure {
        assertEq(C.POOL_MIN_TICK % C.POOL_TICK_SPACING, 0);
        assertEq(C.POOL_MAX_TICK % C.POOL_TICK_SPACING, 0);
        assertEq(C.POOL_MIN_TICK, -C.POOL_MAX_TICK);
    }
}
