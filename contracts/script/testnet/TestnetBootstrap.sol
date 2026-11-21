// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {QZRoutes} from "../../src/reward/QZRoutes.sol";
import {QZConstants as C} from "../../src/lib/QZConstants.sol";
import {StockRoute} from "../../src/lib/QZTypes.sol";
import {MockStock, MockUSDG, MockV3Pool, MockV3Factory, MockV3Router, MockLiquiditySeeder} from "./TestnetMocks.sol";

/// @notice The third-party assets the Robinhood testnet lacks, deployed from the calling account in one pass: a USDG
///         stand-in, a v3 factory + pool + router stand-in (one owner-settable WETH/USDG rate), ten stock tokens in
///         track order, and the ten USDG/stock v4 pools of `QZRoutes` initialised at 100 USDG per stock on the given
///         PoolManager with full-range liquidity, so `QZConverter.sealRoutes` and `convert` work unmodified.
///         Used by `DeployTestnetAssets`; the test suite runs it on a local
///         PoolManager.
library TestnetBootstrap {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Mock prices: 1 WETH = 2000 USDG (owner-settable on `MockV3Pool`), every stock = 100 USDG.
    uint256 internal constant USDG_PER_WETH = 2000e6;
    uint160 internal constant SQRT_STOCK_PER_USDG = uint160(100_000 << 96);
    /// @dev 2^96 / 1e5, rounded down
    uint160 internal constant SQRT_USDG_PER_STOCK = 792281625142643375935439;
    /// @dev Full-range liquidity per pool: about 2,000,000 USDG and 20,000 stock tokens of virtual depth.
    uint256 internal constant LIQUIDITY = 2e17;
    string internal constant TICKERS = "NVDA,AAPL,TSLA,GME,SPY,PLTR,NFLX,RDDT,MSTR,SPCX";

    struct Assets {
        address usdg;
        address v3Pool;
        address v3Factory;
        address v3Router;
        address seeder;
        address[10] stocks;
    }

    /// @param tickers the ten symbols in track order (`TICKERS` split by the caller, which owns the cheatcodes)
    /// @param rateOwner owner of the mock v3 rate (the deployer)
    function deploy(IPoolManager pm, address weth, address rateOwner, string[] memory tickers)
        internal
        returns (Assets memory a)
    {
        require(tickers.length == C.TRACK_COUNT, "TestnetBootstrap: ten tickers");
        MockUSDG usdg = new MockUSDG();
        MockV3Pool v3Pool = new MockV3Pool(weth, address(usdg), rateOwner, USDG_PER_WETH);
        MockV3Factory v3Factory = new MockV3Factory(address(v3Pool));
        MockV3Router router = new MockV3Router(address(v3Factory));
        MockLiquiditySeeder seeder = new MockLiquiditySeeder(pm);
        a.usdg = address(usdg);
        a.v3Pool = address(v3Pool);
        a.v3Factory = address(v3Factory);
        a.v3Router = address(router);
        a.seeder = address(seeder);
        for (uint8 t; t < C.TRACK_COUNT; ++t) {
            address stock = address(new MockStock(tickers[t]));
            a.stocks[t] = stock;
            _pool(pm, address(usdg), stock, t, seeder);
        }
    }

    function _pool(IPoolManager pm, address usdg, address stock, uint8 t, MockLiquiditySeeder seeder) private {
        StockRoute memory r = QZRoutes.route(t, stock);
        bool usdgFirst = usdg < stock;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdgFirst ? usdg : stock),
            currency1: Currency.wrap(usdgFirst ? stock : usdg),
            fee: r.poolFee,
            tickSpacing: r.tickSpacing,
            hooks: IHooks(address(0))
        });
        uint160 sqrtP = usdgFirst ? SQRT_STOCK_PER_USDG : SQRT_USDG_PER_STOCK;
        pm.initialize(key, sqrtP);
        seeder.seed(key, LIQUIDITY);
        (uint160 now_,,,) = pm.getSlot0(key.toId());
        require(now_ == sqrtP, "TestnetBootstrap: pool price moved");
    }
}
