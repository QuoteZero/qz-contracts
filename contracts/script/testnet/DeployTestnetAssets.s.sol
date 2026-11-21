// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {QZAddresses} from "../../src/lib/QZAddresses.sol";
import {QZConstants as C} from "../../src/lib/QZConstants.sol";
import {TestnetBootstrap} from "./TestnetBootstrap.sol";

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
    /// @dev Robinhood testnet WETH9 (`symbol() == "WETH"`, 18 decimals; checked on chain 2026-11-16).
    address internal constant TESTNET_WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    function run() external {
        require(block.chainid == C.CHAIN_ID_ROBINHOOD_TESTNET, "DeployTestnetAssets: not the Robinhood testnet");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address weth = vm.envOr("QZ_WETH", TESTNET_WETH);
        IPoolManager pm = IPoolManager(QZAddresses.POOL_MANAGER);
        require(address(pm).code.length != 0, "DeployTestnetAssets: no PoolManager on this chain");
        require(weth.code.length != 0, "DeployTestnetAssets: no WETH at QZ_WETH");
        require(IWETH9Min(weth).decimals() == 18, "DeployTestnetAssets: WETH is not 18 decimals");

        vm.startBroadcast(pk);
        TestnetBootstrap.Assets memory x = TestnetBootstrap.deploy(pm, weth, vm.addr(pk), vm.split(TestnetBootstrap.TICKERS, ","));
        vm.stopBroadcast();
        address[10] memory stocks = x.stocks;
        address usdg = x.usdg;
        address v3Pool = x.v3Pool;
        address router = x.v3Router;

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
                vm.toString(usdg),
                "\",\"v3Pool\":\"",
                vm.toString(v3Pool),
                "\",\"v3Router\":\"",
                vm.toString(router),
                "\",\"stocks\":[",
                list,
                "]}"
            )
        );
    }
}
