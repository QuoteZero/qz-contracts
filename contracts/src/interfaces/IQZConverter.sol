// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StockRoute} from "../lib/QZTypes.sol";
import {IQZPausable} from "./IQZCommon.sol";

/// @title IQZConverter
/// @notice Turns the reward pot into stock tokens, outside any swap callback (SPEC Model B, B.3, B.5; §3.2, T15).
///
///         Two sources fill the pot and nothing else does: the ETH the fee splitter sends (20/27 of the creator fee)
///         and the USDG the machine mint sends (25% of the mint money). ETH arrives through `receive()` and is wrapped
///         to WETH inside `openEpoch`. Anyone may also donate to the pot.
///
///         `openEpoch()` splits every WETH and every USDG not yet assigned equally over the tracks with `W[t] > 0`
///         (the relic share rides along) and reverts if no machine is lit. The first call is allowed at
///         `firstEpochAt()` (24 h after lighting opens), later calls every 60 s.
///
///         `convert` swaps WETH -> USDG (v3, floor 97% x TWAP 10 min) -> stock (v4, floor 97% x median of the converter's
///         own observations) and calls `QZRewardVault.notify`. `convertUsdg` does the second leg only for the USDG share.
///         The caller's `minOut` can only raise the floor. Spot deviating > 3% from the median reverts.
///         Normal mode: `poke(track)` keeper only, random times, median of >= 9 observations in 30 min.
///         Fallback (keeper silent > 24 h): `poke` and `convert` are permissionless, median of >= 25 observations spaced
///         >= 5 min over >= 2 h, per-track `fallbackDailyCap`. Per-call size <= `maxChunk`.
///         A paused or blocked stock freezes only that track (`TrackFrozen` on the vault). `pause()` stops `openEpoch`,
///         `convert` and `convertUsdg`.
interface IQZConverter is IQZPausable {
    // ───────────── events ─────────────

    /// @param wethAmount WETH assigned to tracks this epoch
    /// @param usdgAmount USDG assigned to tracks this epoch
    /// @param activeTracks bitmask, bit t set = track t received a share
    event EpochOpened(uint256 wethAmount, uint256 usdgAmount, uint16 activeTracks);
    /// @param wethIn WETH spent, 0 for a `convertUsdg` call
    /// @param usdgOut USDG that went into the stock leg (the WETH leg's output, or the USDG spent directly)
    /// @param stockOut stock units handed to the vault
    event Converted(uint8 indexed track, uint256 wethIn, uint256 usdgOut, uint256 stockOut);
    event PricePoked(uint8 indexed track, uint160 sqrtPriceX96, bool byKeeper);
    event FallbackEntered();
    /// @notice ETH from the splitter (or a donor) was wrapped into WETH during `openEpoch`.
    event EthWrapped(uint256 amount);
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
    /// @notice `convert` or `convertUsdg` asked for more than the track's pot holds.
    error PotTooSmall(uint8 track, uint256 want, uint256 have);

    // ───────────── functions ─────────────

    /// @notice Accepts ETH (the splitter's reward share, or a donation); wrapped on the next `openEpoch`.
    receive() external payable;

    /// @notice Executor; anyone in fallback mode. Wraps held ETH, then assigns every unassigned WETH and USDG
    ///         equally over the active tracks.
    function openEpoch() external;

    /// @notice Executor; permissionless after 24 h executor silence (with the fallback daily cap). Spends `wethIn`
    ///         of the track's WETH pot.
    function convert(uint8 track, uint256 wethIn, uint256 minUsdgOut, uint256 minStockOut, uint256 deadline) external;

    /// @notice Same access as `convert`. Spends `usdgIn` of the track's USDG pot on the stock leg only.
    function convertUsdg(uint8 track, uint256 usdgIn, uint256 minStockOut, uint256 deadline) external;

    /// @notice Record a price observation for `track`. Keeper in normal mode; anyone in fallback mode.
    function poke(uint8 track) external;

    /// @notice Owner, before `sealRoutes()` only.
    function setRoute(uint8 track, StockRoute calldata route) external;
    /// @notice Owner, once. Routes (and chunk/cap values inside them) are immutable afterwards.
    function sealRoutes() external;

    // ───────────── views ─────────────

    function routeOf(uint8 track) external view returns (StockRoute memory);
    function routesSealed() external view returns (bool);
    /// @notice WETH / USDG waiting to be converted for `track` (after `openEpoch`).
    function trackPot(uint8 track) external view returns (uint256 weth, uint256 usdg);
    /// @notice What the converter holds that no track owns yet: `eth` + `weth` + `usdg`. The next `openEpoch`
    ///         assigns it.
    function unassignedPot() external view returns (uint256 eth, uint256 weth, uint256 usdg);
    /// @notice Everything the converter holds for the pot: unassigned plus per-track.
    function potBalance() external view returns (uint256 eth, uint256 weth, uint256 usdg);
    function lastOpenEpoch() external view returns (uint64);
    /// @notice The first moment `openEpoch` is allowed: lighting opens plus 24 h. Fixed at deployment.
    function firstEpochAt() external view returns (uint64);
    function executor() external view returns (address);
    function keeper() external view returns (address);
    function fallbackMode() external view returns (bool);
    /// @notice Median observed price (sqrtPriceX96) and the number of observations in the active window.
    function medianPrice(uint8 track) external view returns (uint160 sqrtPriceX96, uint256 observations);
    function fallbackSpentToday(uint8 track) external view returns (uint256);
    function owner() external view returns (address);
    function weth() external view returns (address);
    function usdg() external view returns (address);
    function vault() external view returns (address);
}
