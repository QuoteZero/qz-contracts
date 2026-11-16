// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {QZAddresses} from "../../src/lib/QZAddresses.sol";
import {QZRoutes} from "../../src/reward/QZRoutes.sol";
import {QZConstants as C} from "../../src/lib/QZConstants.sol";
import {StockRoute} from "../../src/lib/QZTypes.sol";
import {MockStock, MockUSDG, MockV3Pool, MockV3Factory, MockV3Router, MockLiquiditySeeder} from "./TestnetMocks.sol";

interface IWETH9Min {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title DeployTestnetAssets
/// @notice The third-party assets the testnet deployment needs on the Robinhood testnet (chain 46630), deployed from the deployer
///         EOA: ten mock stock tokens (track order of `QZAddresses`), a mock USDG, a v3 factory + router
///         stand-in (priced at an owner-settable WETH/USDG rate, see `TestnetMocks.sol`), and the ten USDG/stock v4 pools
///         of `QZRoutes` initialised at 100 USDG per stock on the real PoolManager and seeded with full-range liquidity,
///         so `QZConverter.convert` trades for real (`sealRoutes` requires `sqrtPrice != 0`). The testnet's real WETH9
///         (`QZ_WETH`, default `TESTNET_WETH`) is reused after checking it is there. Prints one `QZ_ASSETS_JSON:{...}` line that `deploy-testnet-assets.sh` stores.
///
///         Environment: `DEPLOYER_PRIVATE_KEY`; optional `QZ_WETH`.
contract DeployTestnetAssets is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Robinhood testnet WETH9 (`symbol() == "WETH"`, 18 decimals; checked on chain 2026-11-16).
    address internal constant TESTNET_WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    /// @dev Mock prices: 1 WETH = 2000 USDG (owner-settable on `MockV3Pool`), every stock = 100 USDG (the v4 pools start
    ///      there). USDG has 6 decimals, a stock 18: raw price USDG/stock is 1e10 at 100 USDG.
    uint256 internal constant USDG_PER_WETH = 2000e6;
    uint160 internal constant SQRT_STOCK_PER_USDG = uint160(100_000 << 96);
    uint160 internal constant SQRT_USDG_PER_STOCK = 792281625142643375935439;
    /* 2^96 / 1e5, rounded down */

    /// @dev Full-range liquidity per pool: virtual reserves of about 2,000,000 USDG and 20,000 stock tokens, deep enough
    ///      that the largest `maxChunk` (0.5 WETH = 1,000 USDG) moves the price by about 0.05%.
    uint256 internal constant LIQUIDITY = 2e17;
    string internal constant TICKERS = "NVDA,AAPL,TSLA,GME,SPY,PLTR,NFLX,RDDT,MSTR,SPCX";

    function run() external {
        require(block.chainid == C.CHAIN_ID_ROBINHOOD_TESTNET, "DeployTestnetAssets: not the Robinhood testnet");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address weth = vm.envOr("QZ_WETH", TESTNET_WETH);
        IPoolManager pm = IPoolManager(QZAddresses.POOL_MANAGER);
        require(address(pm).code.length != 0, "DeployTestnetAssets: no PoolManager on this chain");
        require(weth.code.length != 0, "DeployTestnetAssets: no WETH at QZ_WETH");
        require(IWETH9Min(weth).decimals() == 18, "DeployTestnetAssets: WETH is not 18 decimals");

        vm.startBroadcast(pk);
        MockUSDG usdg = new MockUSDG();
        MockV3Pool v3Pool = new MockV3Pool(weth, address(usdg), vm.addr(pk), USDG_PER_WETH);
        MockV3Router router = new MockV3Router(address(new MockV3Factory(address(v3Pool))));
        MockLiquiditySeeder seeder = new MockLiquiditySeeder(pm);
        address[] memory stocks = new address[](C.TRACK_COUNT);
        string[] memory tickers = vm.split(TICKERS, ",");
        for (uint8 t; t < C.TRACK_COUNT; ++t) {
            stocks[t] = address(new MockStock(tickers[t]));
            StockRoute memory r = QZRoutes.route(t, stocks[t]);
            bool usdgFirst = address(usdg) < stocks[t];
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(usdgFirst ? address(usdg) : stocks[t]),
                currency1: Currency.wrap(usdgFirst ? stocks[t] : address(usdg)),
                fee: r.poolFee,
                tickSpacing: r.tickSpacing,
                hooks: IHooks(address(0))
            });
            uint160 sqrtP = usdgFirst ? SQRT_STOCK_PER_USDG : SQRT_USDG_PER_STOCK;
            pm.initialize(key, sqrtP);
            seeder.seed(key, LIQUIDITY);
            // seeding does not move the price: the pool must sit at 100 USDG per stock
            (uint160 now_,,,) = pm.getSlot0(key.toId());
            require(now_ == sqrtP, "DeployTestnetAssets: pool price moved");
        }
        vm.stopBroadcast();

        string memory list;
        for (uint256 t; t < stocks.length; ++t) {
            list = string.concat(list, t == 0 ? '"' : ',"', vm.toString(stocks[t]), '"');
        }
        console2.log(
            string.concat(
                "QZ_ASSETS_JSON:{\"chainId\":",
                vm.toString(block.chainid),
                ",\"weth\":\"",
                vm.toString(weth),
                "\",\"usdg\":\"",
                vm.toString(address(usdg)),
                "\",\"v3Pool\":\"",
                vm.toString(address(v3Pool)),
                "\",\"v3Router\":\"",
                vm.toString(address(router)),
                "\",\"stocks\":[",
                list,
                "]}"
            )
        );
    }
}
