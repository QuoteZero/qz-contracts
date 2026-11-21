// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {QZConverter} from "../../src/reward/QZConverter.sol";
import {QZRewardVault} from "../../src/reward/QZRewardVault.sol";
import {QZPriceMath} from "../../src/reward/QZPriceMath.sol";
import {StockRoute} from "../../src/lib/QZTypes.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MockERC20, MockWETH, MockStock, MockMachine, MockV3, MockPoolManager} from "./mocks/RewardMocks.sol";

/// @notice Local (non-fork) world for `QZConverter`: a constant-liquidity mock v4 `PoolManager` with ten USDG/stock pools (both token
///         orders), mock v3 router/pool, a WETH9 stand-in, the real `QZRewardVault`. The test contract is the forge.
abstract contract ConverterFixture is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint64 internal constant T0 = 1_800_000_000;
    /// @dev ~2060 USDG per WETH, 1.0001^-200000
    int24 internal constant WETH_USDG_TICK = -200_000;
    /// @dev stock ~ $200: 1e18 raw stock = 200e6 raw USDG
    int24 internal constant STOCK_TICK = 223_320;
    uint128 internal constant LIQUIDITY = 2e16;

    MockPoolManager internal pm;

    MockWETH internal weth;
    MockERC20 internal usdg;
    MockStock[10] internal stocks;
    MockV3 internal v3;
    MockMachine internal machine;
    QZRewardVault internal vault;
    QZConverter internal conv;

    address internal owner = makeAddr("owner");
    address internal pauser = makeAddr("pauser");
    address internal keeper = makeAddr("keeper");
    address internal executor = makeAddr("executor");
    address internal attacker = makeAddr("attacker");
    address internal alice = makeAddr("alice");

    uint64 internal lightingOpensAt;

    function setUp() public virtual {
        vm.warp(T0);
        pm = new MockPoolManager();

        // WETH below USDG (token0 = WETH on the v3 pool); stocks alternate below / above USDG
        address usdgAddr = address(uint160(0x8000000000000000000000000000000000000001));
        deployCodeTo("RewardMocks.sol:MockERC20", abi.encode("USDG", "USDG", uint8(6)), usdgAddr);
        usdg = MockERC20(usdgAddr);
        weth = MockWETH(address(uint160(0x4000000000000000000000000000000000000001)));
        deployCodeTo("RewardMocks.sol:MockWETH", address(weth));
        for (uint256 i; i < 10; ++i) {
            address a =
                i % 2 == 0 ? address(uint160((uint256(1) << 156) + i)) : address(uint160((uint256(15) << 156) + i));
            deployCodeTo("RewardMocks.sol:MockStock", a);
            stocks[i] = MockStock(a);
        }

        v3 = new MockV3(MockERC20(address(weth)), usdg, WETH_USDG_TICK);
        machine = new MockMachine();
        lightingOpensAt = T0 + 1 hours;

        uint256 nonce = vm.getNonce(address(this));
        address predictedConverter = vm.computeCreateAddress(address(this), nonce + 1);
        vault = new QZRewardVault(address(this), address(machine), predictedConverter);
        conv = new QZConverter(
            QZConverter.Config({
                owner: owner,
                pauser: pauser,
                keeper: keeper,
                executor: executor,
                weth: address(weth),
                usdg: address(usdg),
                v3Factory: address(v3),
                v3Router: address(v3),
                poolManager: address(pm),
                vault: address(vault),
                lightingOpensAt: lightingOpensAt
            })
        );
        assertEq(address(conv), predictedConverter, "converter address prediction");

        for (uint8 t; t < 10; ++t) {
            _initPool(t);
        }
    }

    // ───────────── world building ─────────────

    function _route(uint8 t) internal view returns (StockRoute memory r) {
        r = StockRoute({
            stock: address(stocks[t]),
            hooks: address(0),
            poolFee: 3000,
            tickSpacing: 60,
            v3Fee: 100,
            maxChunk: uint128(QZConstants.DEFAULT_MAX_CHUNK),
            fallbackDailyCap: uint128(QZConstants.DEFAULT_FALLBACK_DAILY_CAP)
        });
    }

    function _key(uint8 t) internal view returns (PoolKey memory) {
        bool usdgIs0 = address(usdg) < address(stocks[t]);
        return PoolKey({
            currency0: Currency.wrap(usdgIs0 ? address(usdg) : address(stocks[t])),
            currency1: Currency.wrap(usdgIs0 ? address(stocks[t]) : address(usdg)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _usdgIs0(uint8 t) internal view returns (bool) {
        return address(usdg) < address(stocks[t]);
    }

    function _initPool(uint8 t) internal {
        int24 tick = _usdgIs0(t) ? STOCK_TICK : -STOCK_TICK;
        pm.initialize(_key(t), TickMath.getSqrtPriceAtTick(tick), LIQUIDITY);
        usdg.mint(address(pm), 1e15);
        stocks[t].mint(address(pm), 1e27);
    }

    function _setRoutesAndSeal() internal {
        vm.startPrank(owner);
        for (uint8 t; t < 10; ++t) {
            conv.setRoute(t, _route(t));
        }
        conv.sealRoutes();
        vm.stopPrank();
    }

    /// @dev Lights one tier-I machine on each of the given tracks (ids 100 + track).
    function _lightTracks(uint8[] memory tracks) internal {
        for (uint256 i; i < tracks.length; ++i) {
            machine.set(100 + tracks[i], alice, 1, tracks[i], false);
            vault.register(100 + tracks[i]);
        }
    }

    function _lightTrack(uint8 t) internal {
        uint8[] memory a = new uint8[](1);
        a[0] = t;
        _lightTracks(a);
    }

    // ───────────── pool price manipulation ─────────────

    function _spot(uint8 t) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = IPoolManager(address(pm)).getSlot0(_key(t).toId());
    }

    function _setSpot(uint8 t, uint160 sqrtP) internal {
        pm.setSqrtPrice(_key(t), sqrtP);
    }

    /// @dev Moves the pool so that it pays `bps` more (positive) or less (negative) stock per USDG than before.
    ///      First order in sqrt space, exact enough for a few percent.
    function _shiftStockPerUsdg(uint8 t, int256 bps) internal {
        uint256 s = _spot(t);
        // price (token1/token0) up => stock per usdg up iff usdg is currency0
        int256 signed_ = _usdgIs0(t) ? bps : -bps;
        int256 half = signed_ / 2;
        _setSpot(t, uint160(uint256(int256(s) + int256(s) * half / 10_000)));
    }

    // ───────────── flow helpers ─────────────

    function _poke(uint8 t) internal {
        vm.prank(keeper);
        conv.poke(t);
    }

    /// @dev `n` keeper observations of track `t`, 100 s apart.
    function _pokeKeeper(uint8 t, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _poke(t);
            vm.warp(block.timestamp + 100);
        }
    }

    /// @dev Lands just after `firstEpochAt` with `n` fresh keeper observations on every track in `tracks`.
    ///      The keeper starts poking inside the first day, as in production (its liveness clock starts when lighting opens).
    function _readyForConvert(uint8[] memory tracks, uint256 n) internal {
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours - 20 minutes);
        for (uint256 i; i < tracks.length; ++i) {
            _pokeKeeper(tracks[i], n);
        }
        vm.warp(lightingOpensAt + 24 hours + 1);
    }

    /// @dev The splitter sends `ethAmt` ETH; the machine mint sends `usdgAmt` USDG. Neither is assigned to a track yet.
    function _fundPots(uint256 ethAmt, uint256 usdgAmt) internal {
        if (ethAmt != 0) {
            vm.deal(address(this), address(this).balance + ethAmt);
            (bool ok,) = address(conv).call{value: ethAmt}("");
            assertTrue(ok, "conv receives ETH");
        }
        if (usdgAmt != 0) usdg.mint(address(conv), usdgAmt);
    }

    function _potWeth(uint8 t) internal view returns (uint256 w) {
        (w,) = conv.trackPot(t);
    }

    function _potUsdg(uint8 t) internal view returns (uint256 u) {
        (, u) = conv.trackPot(t);
    }

    function _open() internal {
        vm.prank(executor);
        conv.openEpoch();
    }

    function _convert(uint8 t, uint256 wethIn) internal {
        vm.prank(executor);
        conv.convert(t, wethIn, 1, 1, block.timestamp + 1);
    }

    /// @dev Stock a fair pool pays for `usdgIn` before fee and impact.
    function _fairStock(uint8 t, uint256 usdgIn) internal view returns (uint256) {
        return QZPriceMath.quote(usdgIn, QZPriceMath.priceX128(_spot(t)), _usdgIs0(t));
    }
}
