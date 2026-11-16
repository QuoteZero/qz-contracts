// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockRoute} from "../lib/QZTypes.sol";
import {IQZPausable} from "./IQZCommon.sol";

/// @title IQZConverter
/// @notice Turns the reward-pot WETH into stock tokens, outside any swap callback (§2.5, §3.2, T15).
///         `openEpoch()` pulls the reward pots (`QZHook.pullRewardPot`, `QZCurve.pullRewardPot`), splits the WETH equally
///         over tracks with `W[t] > 0` (the relic share rides along, §2.5) and reverts if no machine is lit; first call
///         allowed `launchAt + 24 h`, later calls every 60 s. `convert` swaps WETH -> USDG (v3, floor 97% x TWAP 10 min)
///         -> stock (v4, floor 97% x median of the converter's own observations) and calls `QZRewardVault.notify`.
///         The caller's `minOut` can only raise the floor. Spot deviating > 3% from the median reverts.
///         Normal mode: `poke(track)` keeper only, random times, median of >= 9 observations in 30 min.
///         Fallback (keeper silent > 24 h): `poke` and `convert` are permissionless, median of >= 25 observations spaced
///         >= 5 min over >= 2 h, per-track `fallbackDailyCap`. Per-call size <= `maxChunk`.
///         A paused/blocked stock freezes only that track (`TrackFrozen` on the vault). `pause()` stops `openEpoch` and `convert` (§4.2 scope `convert`).
interface IQZConverter is IQZPausable {
    // ───────────── events (SPEC §5.1) ─────────────

    /// @param amount WETH distributed this epoch
    /// @param activeTracks bitmask, bit t set = track t received a share
    event EpochOpened(uint256 amount, uint16 activeTracks);
    event Converted(uint8 indexed track, uint256 wethIn, uint256 usdgOut, uint256 stockOut);
    event PricePoked(uint8 indexed track, uint160 sqrtPriceX96, bool byKeeper);
    event FallbackEntered();
    event PotsPulled(uint256 fromHook, uint256 fromCurve, uint256 fromCircuitRedirect);
    event RouteSet(uint8 indexed track, address stock);
    event RoutesSealed();

    // ───────────── errors ─────────────

    error NoLitMachines();
    /// @notice A fallback conversion below `ceil(fallbackDailyCap / 32)`: dust would fill the 32-slot cap ring.
    error ChunkBelowFallbackMinimum(uint256 wethIn, uint256 minimum);
    error TooEarly(uint64 notBefore);
    error RoutesAlreadySealed();
    error RoutesNotSealed();
    error BadTrack(uint8 track);
    error TrackNotActive(uint8 track);
    error NotKeeper(address caller);
    error NotExecutor(address caller);
    error ChunkTooLarge(uint256 wethIn, uint256 maxChunk);
    error DailyCapExceeded(uint8 track, uint256 wethIn, uint256 remaining);
    error NotEnoughObservations(uint8 track, uint256 have, uint256 need);
    error SpotDeviatesFromMedian(uint8 track, uint256 spot, uint256 median);
    error BelowFloor(uint256 out, uint256 floor);
    error NotFallback();

    // ───────────── functions (SPEC §5.1) ─────────────

    /// @notice Executor (keeper). Distribute the reward pot WETH to active tracks.
    function openEpoch() external;

    /// @notice Executor; permissionless after 24 h executor silence (with the fallback daily cap).
    function convert(uint8 track, uint256 wethIn, uint256 minUsdgOut, uint256 minStockOut, uint256 deadline) external;

    /// @notice Record a price observation for `track`. Keeper in normal mode; anyone in fallback mode.
    function poke(uint8 track) external;

    /// @notice Owner, before `sealRoutes()` only.
    function setRoute(uint8 track, StockRoute calldata route) external;
    /// @notice Owner, once. Routes (and chunk/cap values inside them) are immutable afterwards.
    function sealRoutes() external;

    // ───────────── views ─────────────

    function routeOf(uint8 track) external view returns (StockRoute memory);
    function routesSealed() external view returns (bool);
    /// @notice WETH waiting to be converted for `track` (after `openEpoch`).
    function trackPot(uint8 track) external view returns (uint256);
    function lastOpenEpoch() external view returns (uint64);
    function executor() external view returns (address);
    function keeper() external view returns (address);
    function fallbackMode() external view returns (bool);
    /// @notice Median observed price (sqrtPriceX96) and the number of observations in the active window.
    function medianPrice(uint8 track) external view returns (uint160 sqrtPriceX96, uint256 observations);
    function fallbackSpentToday(uint8 track) external view returns (uint256);
    function owner() external view returns (address);
}
