// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IQZConverter} from "../interfaces/IQZConverter.sol";
import {IQZRewardVault} from "../interfaces/IQZRewardVault.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {StockRoute} from "../lib/QZTypes.sol";
import {QZConstants} from "../lib/QZConstants.sol";
import {QZPriceMath, ISwapRouter02Min, IUniswapV3FactoryMin} from "./QZPriceMath.sol";

/// @title QZConverter
/// @notice Turns the reward pot into stock tokens outside any swap callback and hands them to `QZRewardVault`
///         (SPEC Model B, B.3, B.5; §3.2).
///
///         Two sources fill the pot and nothing else does (donations aside): the ETH the fee splitter sends through
///         `receive()` and the USDG the machine mint sends (25% of the mint money). `openEpoch` wraps the ETH and
///         splits every WETH and every USDG not yet assigned equally over the tracks with standard weight lit; each
///         track keeps its own WETH pot and USDG pot.
///
///         Two routes to stock, both outside any callback:
///         - `convert`: WETH -> USDG on the Uniswap v3 pool (SwapRouter02), then USDG -> stock on the v4 pool of the
///           track's sealed route.
///         - `convertUsdg`: the second leg only, for the USDG pot.
///
///         Floors, both on-chain, the caller's `minOut` can only raise them:
///         - leg 1: `97% x TWAP(10 min)` of the v3 WETH/USDG pool. Gross: the v3 fee counts inside the 3%.
///         - leg 2: `97% x median` of this contract's own observations of the v4 pool price. Gross: the pool's LP fee
///           counts inside the 3%, so a 3% pool never converts.
///           The v4 pool has no oracle, so keepers record observations with `poke`:
///           normal mode: keeper only, median of >= 9 keeper observations in the last 30 min;
///           fallback mode (the keeper or the executor silent for more than 24 h): `poke`, `convert` and
///           `convertUsdg` are open to everyone, observations are >= 5 min apart, the median needs 25 of them, and a
///           track converts at most `fallbackDailyCap` WETH per rolling day. An attacker who owns every observation in
///           fallback mode therefore loses at most that cap per day and track.
///         Both functions also revert when the pool spot price deviates more than 3% from that median.
///
///         `maxChunk` and `fallbackDailyCap` are WETH amounts. A `convertUsdg` call is measured in WETH at the v3
///         TWAP (rounded up), so one limit governs both routes and one cap ring serves both.
///
///         Decisions where the spec is silent: the 97% floor is gross, it does not add the LP fee on top (the fee
///         tiers of the stock pools run from 0.212% to 3%, so the fee and the price impact share one 3% budget);
///         `owner`, `keeper`, `executor` and `pauser` are immutable; the liveness clocks of both roles start at the
///         moment lighting opens (keeper) and 24 h later, the first allowed `openEpoch` (executor); only a `convert`
///         or `convertUsdg` of at least the fallback minimum chunk refreshes the executor clock, `openEpoch` does not
///         (a heartbeat must not keep the fallback off); observations are spaced by 60 s (normal mode) or 5 min
///         (fallback); a fallback conversion must spend at least `cap / 32` so that 32 live
///         slots mean the cap is spent; `setRoute` refuses hooked pools and limits above the spec values.
contract QZConverter is IQZConverter, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ───────────── errors beyond the interface ─────────────

    error NotPoolManager(address caller);
    error PartialFill(uint256 wanted, uint256 filled);
    error CapRingFull(uint8 track);
    error Reentrancy();
    error RouteNotSet(uint8 track);
    error RouteInvalid(uint8 track);
    error PoolNotInitialized(uint8 track);

    // ───────────── constants ─────────────

    uint256 internal constant TRACKS = QZConstants.TRACK_COUNT;
    /// @dev ring buffer of observations per track
    uint256 internal constant RING = 64;
    /// @dev bit 224 of a packed observation: recorded by the keeper
    uint256 internal constant KEEPER_BIT = 1 << 224;
    /// @dev Minimum spacing between two observations of a track in normal mode (fallback uses 5 min).
    uint64 internal constant KEEPER_MIN_OBSERVATION_SPACING = 60 seconds;
    uint256 internal constant PIPS = 1_000_000;
    /// @dev fallback observations older than 2 x the 2 h span do not count.
    uint64 internal constant FALLBACK_MAX_AGE = 2 * QZConstants.FALLBACK_WINDOW;

    // ───────────── immutables ─────────────

    address public immutable owner;
    address public immutable pauser;
    address public immutable keeper;
    address public immutable executor;
    address public immutable weth;
    address public immutable usdg;
    address public immutable v3Factory;
    address public immutable v3Router;
    address public immutable poolManager;
    address public immutable vault;
    /// @inheritdoc IQZConverter
    uint64 public immutable firstEpochAt;
    /// @dev the moment `QZForge.light` opens; the keeper's liveness clock starts here
    uint64 internal immutable _lightingOpensAt;

    /// @notice Everything `owner`/roles/sinks the converter is wired to.
    struct Config {
        address owner;
        address pauser;
        address keeper;
        address executor;
        address weth;
        address usdg;
        address v3Factory;
        address v3Router;
        address poolManager;
        address vault;
        /// @dev `QZForge.lightingOpensAt()`; `firstEpochAt` is this plus 24 h
        uint64 lightingOpensAt;
    }

    // ───────────── storage ─────────────

    bool public paused;
    bool public routesSealed;
    uint64 public lastOpenEpoch;
    uint64 internal _lastKeeperPoke;
    uint64 internal _lastExecutorAction;
    bool internal _fallbackFlagged;
    uint256 internal _entered = 1;

    StockRoute[10] internal _routes;
    address[10] internal _v3Pool;
    uint16 internal _routesSet;

    /// @notice Sum of every track's WETH / USDG pot. What the converter holds beyond these is unassigned.
    uint256 public totalTrackWeth;
    uint256 public totalTrackUsdg;
    mapping(uint8 track => uint256) internal _potWeth;
    mapping(uint8 track => uint256) internal _potUsdg;

    mapping(uint8 track => uint256[64]) internal _ring;
    mapping(uint8 track => uint256) internal _obsCount;

    uint256 internal constant CAP_SLOTS = 32;
    mapping(uint8 track => uint256[CAP_SLOTS]) internal _capRing;

    constructor(Config memory c) {
        if (
            c.owner == address(0) || c.pauser == address(0) || c.keeper == address(0) || c.executor == address(0)
                || c.weth == address(0) || c.usdg == address(0) || c.v3Factory == address(0) || c.v3Router == address(0)
                || c.poolManager == address(0) || c.vault == address(0)
        ) revert ZeroAddress();
        if (c.lightingOpensAt == 0) revert ZeroAmount();
        owner = c.owner;
        pauser = c.pauser;
        keeper = c.keeper;
        executor = c.executor;
        weth = c.weth;
        usdg = c.usdg;
        v3Factory = c.v3Factory;
        v3Router = c.v3Router;
        poolManager = c.poolManager;
        vault = c.vault;
        _lightingOpensAt = c.lightingOpensAt;
        firstEpochAt = c.lightingOpensAt + QZConstants.FIRST_OPEN_EPOCH_DELAY;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    /// @inheritdoc IQZConverter
    receive() external payable {}

    // ───────────── pause (stops openEpoch, convert and convertUsdg only) ─────────────

    function pause() external {
        if (msg.sender != pauser) revert NotPauser(msg.sender);
        if (paused) revert EnforcedPause();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external {
        if (msg.sender != pauser) revert NotPauser(msg.sender);
        if (!paused) revert ExpectedPause();
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ───────────── routes ─────────────

    /// @inheritdoc IQZConverter
    function setRoute(uint8 track, StockRoute calldata route) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (routesSealed) revert RoutesAlreadySealed();
        if (track >= TRACKS) revert BadTrack(track);
        if (
            route.stock == address(0) || route.stock.code.length == 0 || route.maxChunk == 0
                || route.fallbackDailyCap == 0 || route.hooks != address(0)
                || route.maxChunk > QZConstants.DEFAULT_MAX_CHUNK
                || route.fallbackDailyCap > QZConstants.DEFAULT_FALLBACK_DAILY_CAP
                || route.fallbackDailyCap > uint256(route.maxChunk) * CAP_SLOTS
        ) {
            revert RouteInvalid(track);
        }
        if (route.poolFee > 1_000_000 || route.v3Fee >= PIPS) revert RouteInvalid(track);
        address pool = IUniswapV3FactoryMin(v3Factory).getPool(weth, usdg, route.v3Fee);
        if (pool == address(0)) revert RouteInvalid(track);

        _routes[track] = route;
        _v3Pool[track] = pool;
        _routesSet |= uint16(1 << track);
        emit RouteSet(track, route.stock);
    }

    /// @inheritdoc IQZConverter
    /// @dev All ten routes must be set and every v4 pool must already be initialised.
    function sealRoutes() external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (routesSealed) revert RoutesAlreadySealed();
        for (uint8 t; t < TRACKS; ++t) {
            if (_routesSet & (1 << t) == 0) revert RouteNotSet(t);
            (uint160 sqrtP,,,) = IPoolManager(poolManager).getSlot0(_poolKey(t).toId());
            if (sqrtP == 0) revert PoolNotInitialized(t);
        }
        routesSealed = true;
        emit RoutesSealed();
    }

    function routeOf(uint8 track) external view returns (StockRoute memory) {
        if (track >= TRACKS) revert BadTrack(track);
        return _routes[track];
    }

    /// @notice The v3 WETH/USDG pool whose TWAP floors leg 1 of `track` and measures `convertUsdg` against `maxChunk`.
    function v3PoolOf(uint8 track) external view returns (address) {
        return _v3Pool[track];
    }

    // ───────────── pot views ─────────────

    /// @inheritdoc IQZConverter
    function trackPot(uint8 track) external view returns (uint256 wethPot, uint256 usdgPot) {
        return (_potWeth[track], _potUsdg[track]);
    }

    /// @inheritdoc IQZConverter
    function unassignedPot() public view returns (uint256 eth, uint256 wethAmount, uint256 usdgAmount) {
        eth = address(this).balance;
        wethAmount = _unassigned(IERC20(weth).balanceOf(address(this)), totalTrackWeth);
        usdgAmount = _unassigned(IERC20(usdg).balanceOf(address(this)), totalTrackUsdg);
    }

    /// @inheritdoc IQZConverter
    function potBalance() external view returns (uint256 eth, uint256 wethAmount, uint256 usdgAmount) {
        return (address(this).balance, IERC20(weth).balanceOf(address(this)), IERC20(usdg).balanceOf(address(this)));
    }

    /// @notice The most USDG one `convertUsdg` call may spend on `track`: `maxChunk` WETH at the v3 TWAP, rounded down.
    function usdgChunkLimit(uint8 track) external view returns (uint256) {
        if (track >= TRACKS) revert BadTrack(track);
        if (!routesSealed) revert RoutesNotSealed();
        return QZPriceMath.quote(_routes[track].maxChunk, _twapX128(track), weth < usdg);
    }

    /// @dev Balance beyond the assigned pots. Saturates: if a token issuer ever removed funds from here the next
    ///      `openEpoch` still runs and the shortfall is absorbed by the next deposits instead of wedging the epoch.
    function _unassigned(uint256 balance, uint256 assigned) private pure returns (uint256) {
        return balance > assigned ? balance - assigned : 0;
    }

    // ───────────── liveness ─────────────

    /// @notice True when the keeper or the executor has been silent for more than 24 h since `max(last action,
    ///         lighting opens [+ 24 h for the executor])`. Executor activity is a conversion of at least `cap / 32`
    ///         WETH; `openEpoch` is not activity, so pots that stay unconverted for 24 h open the fallback.
    function fallbackMode() public view returns (bool) {
        uint64 keeperSince = _max(_lastKeeperPoke, _lightingOpensAt);
        uint64 executorSince = _max(_lastExecutorAction, firstEpochAt);
        return block.timestamp > uint256(keeperSince) + QZConstants.FALLBACK_SILENCE
            || block.timestamp > uint256(executorSince) + QZConstants.FALLBACK_SILENCE;
    }

    function _enterFallbackIfNeeded(bool fb) internal {
        if (fb && !_fallbackFlagged) {
            _fallbackFlagged = true;
            emit FallbackEntered();
        }
    }

    function _leaveFallbackIfNeeded() internal {
        if (_fallbackFlagged && !fallbackMode()) _fallbackFlagged = false;
    }

    // ───────────── openEpoch ─────────────

    /// @inheritdoc IQZConverter
    /// @dev Executor, or anyone in fallback mode. Wraps the ETH held, then distributes every WETH and every USDG not
    ///      yet assigned to a track (the splitter's ETH, the mint seed, donations, last epoch's division remainder)
    ///      equally over the tracks with `W[t] > 0`, so no track without a standard machine ever gets a share (§2.5).
    ///      It reverts `NoLitMachines` only when no machine at all is lit; with only relics lit, or nothing fresh,
    ///      there is nothing to allocate: the executor's call then succeeds and changes nothing (it is not executor
    ///      activity), anyone else gets `ZeroAmount`.
    function openEpoch() external nonReentrant whenNotPaused {
        bool fb = fallbackMode();
        if (!fb && msg.sender != executor) revert NotExecutor(msg.sender);
        _enterFallbackIfNeeded(fb);
        if (!routesSealed) revert RoutesNotSealed();

        uint64 notBefore = lastOpenEpoch == 0 ? firstEpochAt : lastOpenEpoch + QZConstants.OPEN_EPOCH_INTERVAL;
        if (block.timestamp < notBefore) revert TooEarly(notBefore);

        uint16 mask;
        uint256 active;
        for (uint8 t; t < TRACKS; ++t) {
            if (IQZRewardVault(vault).weightOf(t) != 0) {
                mask |= uint16(1 << t);
                ++active;
            }
        }
        if (active == 0 && IQZRewardVault(vault).relicCount() == 0) revert NoLitMachines();

        uint256 eth = address(this).balance;
        if (eth != 0) {
            IWETH9(weth).deposit{value: eth}();
            emit EthWrapped(eth);
        }

        uint256 wethShare;
        uint256 usdgShare;
        if (active != 0) {
            wethShare = _unassigned(IERC20(weth).balanceOf(address(this)), totalTrackWeth) / active;
            usdgShare = _unassigned(IERC20(usdg).balanceOf(address(this)), totalTrackUsdg) / active;
        }
        if (wethShare == 0 && usdgShare == 0) {
            if (msg.sender != executor) revert ZeroAmount();
            return;
        }
        for (uint8 t; t < TRACKS; ++t) {
            if (mask & (1 << t) != 0) {
                _potWeth[t] += wethShare;
                _potUsdg[t] += usdgShare;
            }
        }
        totalTrackWeth += wethShare * active;
        totalTrackUsdg += usdgShare * active;
        lastOpenEpoch = uint64(block.timestamp);
        emit EpochOpened(wethShare * active, usdgShare * active, mask);
    }

    // ───────────── poke ─────────────

    /// @inheritdoc IQZConverter
    /// @dev Observations are spaced: >= 60 s in normal mode, >= 5 min in fallback mode, against the newest
    ///      observation of the track. Nine observations then span at least 8 minutes, so a keeper cannot set the
    ///      median with nine pokes inside one transaction (or one block): the price it feeds must hold across
    ///      eight minutes of other people's trades. 60 s fits the keeper's 3 minute mean poke interval and leaves
    ///      room for the 9 observations inside the 30 minute window.
    function poke(uint8 track) external {
        bool fb = fallbackMode();
        bool isKeeper = msg.sender == keeper;
        if (!fb && !isKeeper) revert NotKeeper(msg.sender);
        _enterFallbackIfNeeded(fb);
        if (track >= TRACKS) revert BadTrack(track);
        if (!routesSealed) revert RoutesNotSealed();

        uint256 count = _obsCount[track];
        if (count != 0) {
            uint64 spacing = fb ? QZConstants.FALLBACK_MIN_OBSERVATION_SPACING : KEEPER_MIN_OBSERVATION_SPACING;
            uint64 notBefore = uint64(_ring[track][(count - 1) % RING]) + spacing;
            if (block.timestamp < notBefore) revert TooEarly(notBefore);
        }

        uint160 sqrtP = _spot(track);
        _ring[track][count % RING] =
            uint256(uint64(block.timestamp)) | (uint256(sqrtP) << 64) | (isKeeper ? KEEPER_BIT : 0);
        _obsCount[track] = count + 1;
        emit PricePoked(track, sqrtP, isKeeper);

        if (isKeeper) {
            _lastKeeperPoke = uint64(block.timestamp);
            _leaveFallbackIfNeeded();
        }
    }

    // ───────────── median ─────────────

    /// @inheritdoc IQZConverter
    /// @dev Normal mode: median of the keeper observations of the last 30 min. Fallback mode: median of the newest
    ///      observations that are >= 5 min apart (at most 25, none older than 4 h), any author.
    function medianPrice(uint8 track) public view returns (uint160 sqrtPriceX96, uint256 observations) {
        if (track >= TRACKS) revert BadTrack(track);
        uint256 total = _obsCount[track];
        uint256 avail = total < RING ? total : RING;
        uint256[] memory vals = new uint256[](avail);
        bool fb = fallbackMode();
        uint256 n;
        if (!fb) {
            uint256 since = block.timestamp - QZConstants.MEDIAN_WINDOW;
            for (uint256 k; k < avail; ++k) {
                uint256 p = _ring[track][(total - 1 - k) % RING];
                if (uint64(p) < since) break;
                if (p & KEEPER_BIT == 0) continue;
                vals[n++] = uint160(p >> 64);
            }
        } else {
            uint256 oldestAllowed = block.timestamp > FALLBACK_MAX_AGE ? block.timestamp - FALLBACK_MAX_AGE : 0;
            uint64 lastTs;
            for (uint256 k; k < avail; ++k) {
                uint256 p = _ring[track][(total - 1 - k) % RING];
                uint64 ts = uint64(p);
                if (ts < oldestAllowed) break;
                if (n != 0 && uint256(ts) + QZConstants.FALLBACK_MIN_OBSERVATION_SPACING > lastTs) continue;
                vals[n++] = uint160(p >> 64);
                lastTs = ts;
                if (n == QZConstants.FALLBACK_MIN_OBSERVATIONS) break;
            }
        }
        if (n == 0) return (0, 0);
        return (uint160(QZPriceMath.median(vals, n)), n);
    }

    // ───────────── convert ─────────────

    /// @inheritdoc IQZConverter
    function convert(uint8 track, uint256 wethIn, uint256 minUsdgOut, uint256 minStockOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
    {
        (bool fb, StockRoute memory route) = _beginConversion(track, deadline, wethIn);
        if (wethIn > route.maxChunk) revert ChunkTooLarge(wethIn, route.maxChunk);
        uint256 have = _potWeth[track];
        if (wethIn > have) _revertPotShort(track, wethIn, have);
        if (fb) _spendFallbackCap(track, wethIn, route.fallbackDailyCap);

        _potWeth[track] = have - wethIn;
        totalTrackWeth -= wethIn;

        uint256 referenceX128 = _referencePrice(track, fb);
        uint256 usdgOut = _legWethToUsdg(track, route, wethIn, minUsdgOut);
        uint256 stockOut = _legUsdgToStock(track, route, usdgOut, referenceX128, minStockOut);

        _notifyVault(track, route, stockOut);
        emit Converted(track, wethIn, usdgOut, stockOut);
        _executorDone(wethIn, route);
    }

    /// @inheritdoc IQZConverter
    /// @dev Leg 2 only, for the USDG pot. The call is measured in WETH at the v3 TWAP (rounded up) against `maxChunk`
    ///      and the fallback daily cap, so a USDG pot cannot be pushed through the pool faster than a WETH pot.
    function convertUsdg(uint8 track, uint256 usdgIn, uint256 minStockOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
    {
        (bool fb, StockRoute memory route) = _beginConversion(track, deadline, usdgIn);
        uint256 wethEquivalent = QZPriceMath.quoteRoundingUp(usdgIn, _twapX128(track), usdg < weth);
        if (wethEquivalent > route.maxChunk) revert ChunkTooLarge(wethEquivalent, route.maxChunk);
        uint256 have = _potUsdg[track];
        if (usdgIn > have) _revertPotShort(track, usdgIn, have);
        if (fb) _spendFallbackCap(track, wethEquivalent, route.fallbackDailyCap);

        _potUsdg[track] = have - usdgIn;
        totalTrackUsdg -= usdgIn;

        uint256 referenceX128 = _referencePrice(track, fb);
        uint256 stockOut = _legUsdgToStock(track, route, usdgIn, referenceX128, minStockOut);

        _notifyVault(track, route, stockOut);
        emit Converted(track, 0, usdgIn, stockOut);
        _executorDone(wethEquivalent, route);
    }

    /// @dev Shared prologue: access, fallback flag, deadline, track, seal, non-zero amount.
    function _beginConversion(uint8 track, uint256 deadline, uint256 amount)
        internal
        returns (bool fb, StockRoute memory route)
    {
        fb = fallbackMode();
        if (!fb && msg.sender != executor) revert NotExecutor(msg.sender);
        _enterFallbackIfNeeded(fb);
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        if (track >= TRACKS) revert BadTrack(track);
        if (!routesSealed) revert RoutesNotSealed();
        if (amount == 0) revert ZeroAmount();
        route = _routes[track];
    }

    /// @dev A track that never received a share is `TrackNotActive`; one that holds less than asked is `PotTooSmall`.
    function _revertPotShort(uint8 track, uint256 want, uint256 have) internal view {
        if (_potWeth[track] == 0 && _potUsdg[track] == 0) revert TrackNotActive(track);
        revert PotTooSmall(track, want, have);
    }

    function _notifyVault(uint8 track, StockRoute memory route, uint256 stockOut) internal {
        IERC20(route.stock).forceApprove(vault, stockOut);
        IQZRewardVault(vault).notify(track, stockOut);
    }

    /// @dev Only a conversion of at least the fallback minimum chunk (`cap / 32`, in WETH) by the executor counts as
    ///      executor activity. `openEpoch` never does, so an executor that heartbeats `openEpoch` (or converts dust)
    ///      cannot keep fallback mode off while the pots sit unconverted.
    function _executorDone(uint256 wethEquivalent, StockRoute memory route) internal {
        if (msg.sender == executor && wethEquivalent >= (route.fallbackDailyCap + CAP_SLOTS - 1) / CAP_SLOTS) {
            _lastExecutorAction = uint64(block.timestamp);
            _leaveFallbackIfNeeded();
        }
    }

    /// @dev Leg 1: WETH -> USDG on the v3 pool, floor `97% x` the gross TWAP(10 min) quote (v3 fee included in the 3%),
    ///      raised by `minUsdgOut`.
    function _legWethToUsdg(uint8 track, StockRoute memory route, uint256 wethIn, uint256 minUsdgOut)
        internal
        returns (uint256 usdgOut)
    {
        uint256 floor_ =
            QZPriceMath.quote(wethIn, _twapX128(track), weth < usdg) * QZConstants.CONVERT_FLOOR_BPS / QZConstants.BPS;
        if (minUsdgOut > floor_) floor_ = minUsdgOut;

        IERC20(weth).forceApprove(v3Router, wethIn);
        uint256 before = IERC20(usdg).balanceOf(address(this));
        ISwapRouter02Min(v3Router)
            .exactInputSingle(
                ISwapRouter02Min.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: usdg,
                    fee: route.v3Fee,
                    recipient: address(this),
                    amountIn: wethIn,
                    amountOutMinimum: floor_,
                    sqrtPriceLimitX96: 0
                })
            );
        usdgOut = IERC20(usdg).balanceOf(address(this)) - before;
        if (usdgOut < floor_) revert BelowFloor(usdgOut, floor_);
    }

    /// @dev Leg 2: USDG -> stock on the v4 pool, floor `97% x` the gross median quote (pool fee included in the 3%),
    ///      raised by `minStockOut`, enforced on the stock actually received.
    function _legUsdgToStock(
        uint8 track,
        StockRoute memory route,
        uint256 usdgIn,
        uint256 referenceX128,
        uint256 minStockOut
    ) internal returns (uint256 stockOut) {
        bool usdgIsCurrency0 = usdg < route.stock;
        uint256 floor_ =
            QZPriceMath.quote(usdgIn, referenceX128, usdgIsCurrency0) * QZConstants.CONVERT_FLOOR_BPS / QZConstants.BPS;
        if (minStockOut > floor_) floor_ = minStockOut;
        if (floor_ == 0) floor_ = 1;

        uint256 before = IERC20(route.stock).balanceOf(address(this));
        try IPoolManager(poolManager).unlock(abi.encode(_poolKey(track), usdgIsCurrency0, usdgIn)) {}
        catch (bytes memory reason) {
            if (bytes4(reason) == PartialFill.selector) revert BelowFloor(0, floor_);
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        stockOut = IERC20(route.stock).balanceOf(address(this)) - before;
        if (stockOut < floor_) revert BelowFloor(stockOut, floor_);
    }

    /// @dev priceX128 of the v3 WETH/USDG pool over the last 10 minutes (token1 per token0, raw units).
    function _twapX128(uint8 track) internal view returns (uint256) {
        return QZPriceMath.priceAtTick(QZPriceMath.twapTick(_v3Pool[track], QZConstants.V3_TWAP_WINDOW));
    }

    /// @dev Reference price (priceX128) of the v4 pool: the median of the observations, after proving there are enough
    ///      of them and that the spot price is within 3% of it.
    function _referencePrice(uint8 track, bool fb) internal view returns (uint256 medianX128) {
        (uint160 medianSqrt, uint256 n) = medianPrice(track);
        uint256 need = fb ? QZConstants.FALLBACK_MIN_OBSERVATIONS : QZConstants.MIN_OBSERVATIONS;
        if (n < need) revert NotEnoughObservations(track, n, need);
        uint160 spotSqrt = _spot(track);
        medianX128 = QZPriceMath.priceX128(medianSqrt);
        uint256 spotX128 = QZPriceMath.priceX128(spotSqrt);
        uint256 diff = spotX128 > medianX128 ? spotX128 - medianX128 : medianX128 - spotX128;
        if (medianX128 == 0 || diff * QZConstants.BPS > medianX128 * QZConstants.MAX_SPOT_DEVIATION_BPS) {
            revert SpotDeviatesFromMedian(track, spotSqrt, medianSqrt);
        }
    }

    /// @dev Rolling 24 h cap: every conversion of the last 24 h is kept (slot per conversion, up to `CAP_SLOTS`), a
    ///      conversion is accepted only if the sum of those still inside `(now - 24h, now]` plus the new one is within
    ///      the cap. Any 24 h interval then holds at most `cap`: at the time of the last conversion in the interval all
    ///      earlier ones are inside its window. A full ring (all slots still inside the window) reverts, never evicts.
    function _spendFallbackCap(uint8 track, uint256 wethIn, uint256 cap) internal {
        uint256[CAP_SLOTS] storage ring = _capRing[track];
        uint256 spent;
        uint256 free = CAP_SLOTS;
        for (uint256 i; i < CAP_SLOTS; ++i) {
            uint256 e = ring[i];
            if (e >> 128 != 0 && (e >> 128) + QZConstants.FALLBACK_CAP_WINDOW > block.timestamp) {
                spent += uint128(e);
            } else if (free == CAP_SLOTS) {
                free = i;
            }
        }
        if (spent + wethIn > cap) revert DailyCapExceeded(track, wethIn, cap > spent ? cap - spent : 0);
        uint256 minChunk = (cap + CAP_SLOTS - 1) / CAP_SLOTS;
        if (wethIn < minChunk) revert ChunkBelowFallbackMinimum(wethIn, minChunk);
        // Unreachable while every live slot holds >= cap / 32 (the sum is then >= cap and the check above fires first);
        // kept so a later change can never overwrite a live slot.
        if (free == CAP_SLOTS) revert CapRingFull(track);
        ring[free] = (block.timestamp << 128) | wethIn;
    }

    function fallbackSpentToday(uint8 track) external view returns (uint256 spent) {
        for (uint256 i; i < CAP_SLOTS; ++i) {
            uint256 e = _capRing[track][i];
            if (e >> 128 != 0 && (e >> 128) + QZConstants.FALLBACK_CAP_WINDOW > block.timestamp) spent += uint128(e);
        }
    }

    // ───────────── v4 leg ─────────────

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert NotPoolManager(msg.sender);
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        IPoolManager pm = IPoolManager(poolManager);

        // No tight price limit: the floor is on the average execution price, and a swap whose average clears the floor
        // can still end at a much lower marginal price. The floor is enforced on the amount actually received.
        BalanceDelta delta = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 spent = zeroForOne ? delta.amount0() : delta.amount1();
        int128 got = zeroForOne ? delta.amount1() : delta.amount0();
        if (spent >= 0 || uint256(uint128(-spent)) != amountIn) {
            revert PartialFill(amountIn, spent >= 0 ? 0 : uint256(uint128(-spent)));
        }

        pm.sync(Currency.wrap(usdg));
        IERC20(usdg).safeTransfer(poolManager, amountIn);
        pm.settle();
        pm.take(zeroForOne ? key.currency1 : key.currency0, address(this), uint256(uint128(got)));
        return "";
    }

    function _poolKey(uint8 track) internal view returns (PoolKey memory key) {
        StockRoute storage r = _routes[track];
        bool usdgIsCurrency0 = usdg < r.stock;
        key = PoolKey({
            currency0: Currency.wrap(usdgIsCurrency0 ? usdg : r.stock),
            currency1: Currency.wrap(usdgIsCurrency0 ? r.stock : usdg),
            fee: r.poolFee,
            tickSpacing: r.tickSpacing,
            hooks: IHooks(r.hooks)
        });
    }

    function _spot(uint8 track) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = IPoolManager(poolManager).getSlot0(_poolKey(track).toId());
        if (sqrtP == 0) revert PoolNotInitialized(track);
    }

    function _max(uint64 a, uint64 b) private pure returns (uint64) {
        return a > b ? a : b;
    }
}
