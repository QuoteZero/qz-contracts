// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Minimal view of a Uniswap v3 pool oracle (the converter reads the WETH/USDG TWAP of leg 1, §3.2).
interface IUniswapV3PoolOracle {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IUniswapV3FactoryMin {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Uniswap v3 SwapRouter02 (the router named in §3.2). `exactInputSingle` has no `deadline` field.
interface ISwapRouter02Min {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title QZPriceMath
/// @notice Price helpers of `QZConverter` (§3.2). Prices are token1/token0 in raw units, `priceX128 = sqrtP^2 / 2^64`.
///         Everything rounds down: a lower floor never costs the user, but a quote only ever feeds a floor.
library QZPriceMath {
    uint256 internal constant Q128 = 1 << 128;

    /// @notice `quote`, rounded up. Used where a size is charged against a limit: the charge never undershoots.
    function quoteRoundingUp(uint256 amountIn, uint256 pX128, bool inIsToken0) internal pure returns (uint256) {
        return inIsToken0
            ? FullMath.mulDivRoundingUp(amountIn, pX128, Q128)
            : FullMath.mulDivRoundingUp(amountIn, Q128, pX128);
    }

    /// @dev `sqrtP^2 / 2^64`. `sqrtP < 2^160` so the result fits in 256 bits.
    function priceX128(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
    }

    /// @notice Output of `amountIn` at `pX128`. `inIsToken0`: the input is the pool's currency0.
    function quote(uint256 amountIn, uint256 pX128, bool inIsToken0) internal pure returns (uint256) {
        return inIsToken0 ? FullMath.mulDiv(amountIn, pX128, Q128) : FullMath.mulDiv(amountIn, Q128, pX128);
    }

    /// @notice Mean tick of a v3 pool over the last `window` seconds, rounded to negative infinity (OracleLibrary).
    function twapTick(address pool, uint32 window) internal view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        (int56[] memory cumulatives,) = IUniswapV3PoolOracle(pool).observe(ago);
        int56 delta = cumulatives[1] - cumulatives[0];
        tick = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) tick--;
    }

    function priceAtTick(int24 tick) internal pure returns (uint256) {
        return priceX128(TickMath.getSqrtPriceAtTick(tick));
    }

    /// @notice Median of `a[0..n)` (sorts that prefix in place). Even `n`: mean of the two middle values.
    function median(uint256[] memory a, uint256 n) internal pure returns (uint256) {
        for (uint256 i = 1; i < n; ++i) {
            uint256 v = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > v) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = v;
        }
        if (n % 2 == 1) return a[n / 2];
        return (a[n / 2 - 1] + a[n / 2]) / 2;
    }
}
