// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockRoute} from "../lib/QZTypes.sol";
import {QZAddresses} from "../lib/QZAddresses.sol";
import {QZConstants} from "../lib/QZConstants.sol";

/// @title QZRoutes
/// @notice The ten reward-track routes `QZConverter.setRoute` is fed with at deploy time (C9 reads this table).
///         The v4 USDG/stock pool of each track (hooks = none, fee, tickSpacing) is the one the Quotrons converter
///         `0x24e62Dd5C7058CC41ad9c5375C137460ea1Da2FE` uses on Robinhood Chain, read on chain with
///         `routes(uint256)` on 16 Nov 2026 and re-mapped to the QuoteZero track order (NVDA, AAPL, TSLA, GME, SPY, PLTR,
///         NFLX, RDDT, MSTR, SPCX). Leg 1 is the v3 WETH/USDG 0.01% pool (`wethUsdgFee() == 100` there too).
///         Chunk and daily-cap sizes are C5's recomputation of SPEC §3.2 point 4 against pool depth
///         (`test/reward/ConverterFork.t.sol` prints the measured price impact per track).
library QZRoutes {
    error BadTrack(uint8 track);

    uint24 internal constant WETH_USDG_V3_FEE = 100;
    /// @dev Floors are gross (97% of the reference), so the pool fee and the price impact share one 3% budget.
    ///      Chunk = the size whose average price impact is about 1% of the pool's virtual USDG reserve R
    ///      (R = L / sqrtP if USDG is currency0, L * sqrtP if currency1; L = in-range liquidity at fork block 115470000;
    ///      WETH ~ $1822), which leaves 3% - fee - 1% for the spot/median gap: 0.3% tiers 1.7%, 1% tiers 1%.
    ///      RDDT (1% tier) R ~ $23.6k: 0.15 WETH ~ $273 ~ 1.2% impact. GME (0.212% tier) R ~ $2.3k: 0.015 WETH ~ $27 ~ 1.2%.
    ///      MSTR has a 3% tier: the fee alone is the whole budget, so `convert` always reverts `BelowFloor` for it and its
    ///      pot stays (the 0.15 WETH chunk only bounds the price impact if the route is ever changed before sealing).
    uint128 internal constant THIN_POOL_MAX_CHUNK = 0.15 ether;
    uint128 internal constant GME_MAX_CHUNK = 0.015 ether;

    /// @notice The Robinhood mainnet table: stock tokens from `QZAddresses`.
    function route(uint8 track) internal pure returns (StockRoute memory) {
        return route(track, QZAddresses.stockOf(track));
    }

    /// @notice The same table for a chain whose stock tokens live elsewhere (the Robinhood testnet has its own): only
    ///         `stock` is the caller's, pool parameters and caps are the mainnet ones. `DeployR1` passes the testnet
    ///         addresses from `QZ_STOCKS`.
    function route(uint8 track, address stock) internal pure returns (StockRoute memory r) {
        r.stock = stock;
        r.hooks = address(0);
        r.v3Fee = WETH_USDG_V3_FEE;
        r.maxChunk = uint128(QZConstants.DEFAULT_MAX_CHUNK);
        r.fallbackDailyCap = uint128(QZConstants.DEFAULT_FALLBACK_DAILY_CAP);
        if (track == 0) {
            (r.poolFee, r.tickSpacing) = (3000, 60); // NVDA
        } else if (track == 1) {
            (r.poolFee, r.tickSpacing) = (3000, 60); // AAPL
        } else if (track == 2) {
            (r.poolFee, r.tickSpacing) = (3000, 60); // TSLA
        } else if (track == 3) {
            (r.poolFee, r.tickSpacing) = (2120, 42); // GME
            r.maxChunk = GME_MAX_CHUNK;
        } else if (track == 4) {
            (r.poolFee, r.tickSpacing) = (500, 5); // SPY
        } else if (track == 5) {
            (r.poolFee, r.tickSpacing) = (10_000, 200); // PLTR
        } else if (track == 6) {
            (r.poolFee, r.tickSpacing) = (10_000, 100); // NFLX
            r.maxChunk = uint128(QZConstants.NFLX_MAX_CHUNK);
        } else if (track == 7) {
            (r.poolFee, r.tickSpacing) = (10_000, 200); // RDDT
            r.maxChunk = THIN_POOL_MAX_CHUNK;
        } else if (track == 8) {
            (r.poolFee, r.tickSpacing) = (30_000, 600); // MSTR
            r.maxChunk = THIN_POOL_MAX_CHUNK;
        } else if (track == 9) {
            (r.poolFee, r.tickSpacing) = (3000, 60); // SPCX
        } else {
            revert BadTrack(track);
        }
    }
}
