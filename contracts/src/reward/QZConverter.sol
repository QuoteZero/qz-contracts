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
import {IQZCurve} from "../interfaces/IQZCurve.sol";
import {IQZHook} from "../interfaces/IQZHook.sol";
import {IQZCircuit} from "../interfaces/IQZCircuit.sol";
import {StockRoute} from "../lib/QZTypes.sol";
import {QZConstants} from "../lib/QZConstants.sol";
import {QZPriceMath, ISwapRouter02Min, IUniswapV3FactoryMin} from "./QZPriceMath.sol";

/// @title QZConverter
/// @notice Turns the reward-pot WETH into stock tokens outside any swap callback and hands them to `QZRewardVault`
///         (SPEC §3.2, T15). Route: WETH -> USDG on the Uniswap v3 pool (SwapRouter02), USDG -> stock on the v4 pool
///         of the track's sealed route.
///
///         Floors, both on-chain, the caller's `minOut` can only raise them:
///         - leg 1: `97% x TWAP(10 min)` of the v3 WETH/USDG pool, net of the v3 fee.
///         - leg 2: `97% x median` of this contract's own observations of the v4 pool price, net of the pool fee.
///           The v4 pool has no oracle, so keepers record observations with `poke`:
///           normal mode: keeper only, median of >= 9 keeper observations in the last 30 min;
///           fallback mode (the keeper or the executor silent for more than 24 h): `poke` and `convert` are open to
///           everyone, observations are >= 5 min apart, the median needs 25 of them, and a track converts at most
///           `fallbackDailyCap` WETH per rolling day. An attacker who owns every observation in fallback mode therefore
///           loses at most that cap per day and track.
///         `convert` also reverts when the pool spot price deviates more than 3% from that median.
///
///         C5 decisions where the spec is silent: the 97% floor applies to the price net of the pool's LP fee (the
///         fee tiers of the stock pools run from 0.212% to 3%, so a floor that ignored the fee would make the 3% tier
///         unconvertible); `owner`, `keeper`, `executor` and `pauser` are immutable; the liveness clocks of both
///         roles start at `launchAt` (keeper) and `launchAt + 24 h` (executor, the first allowed `openEpoch`).
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
    uint256 internal constant PIPS = 1_000_000;
    /// @dev C5 decision: fallback observations older than 2 x the 2 h span do not count.
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
    address public immutable hook;
    address public immutable curve;
    /// @dev may be `address(0)` (R1 without Circuit wired): then no circuit pull happens.
    address public immutable circuit;
    uint64 internal immutable _deployedAt;

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
        address hook;
        address curve;
        address circuit;
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

    uint256 public totalTrackPot;
    mapping(uint8 track => uint256) public trackPot;

    mapping(uint8 track => uint256[64]) internal _ring;
    mapping(uint8 track => uint256) internal _obsCount;

    uint256 internal constant CAP_SLOTS = 32;
    mapping(uint8 track => uint256[CAP_SLOTS]) internal _capRing;

    constructor(Config memory c) {
        if (
            c.owner == address(0) || c.pauser == address(0) || c.keeper == address(0) || c.executor == address(0)
                || c.weth == address(0) || c.usdg == address(0) || c.v3Factory == address(0) || c.v3Router == address(0)
                || c.poolManager == address(0) || c.vault == address(0) || c.hook == address(0) || c.curve == address(0)
        ) revert ZeroAddress();
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
        hook = c.hook;
        curve = c.curve;
        circuit = c.circuit;
        _deployedAt = uint64(block.timestamp);
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

    // ───────────── pause (§4.2: stops openEpoch and convert only) ─────────────

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
                || route.fallbackDailyCap == 0
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

    /// @notice The v3 WETH/USDG pool whose TWAP floors leg 1 of `track`.
    function v3PoolOf(uint8 track) external view returns (address) {
        return _v3Pool[track];
    }

    // ───────────── liveness ─────────────

    /// @notice True when the keeper or the executor has been silent for more than 24 h since `max(last action,
    ///         launchAt [+ 24 h for the executor])`. Before `launchAt` is known it is false.
    function fallbackMode() public view returns (bool) {
        uint64 launch = IQZCurve(curve).launchAt();
        if (launch == 0) return false;
        uint64 keeperSince = _max(_lastKeeperPoke, launch);
        uint64 executorSince = _max(_lastExecutorAction, launch + QZConstants.FIRST_OPEN_EPOCH_DELAY);
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
    /// @dev Executor, or anyone in fallback mode. Distributes every WETH not yet assigned to a track (the pulled pots,
    ///      a Circuit redirect, royalty WETH, last epoch's division remainder, donations) equally over the tracks with
    ///      `W[t] > 0`, so no track without a standard machine ever gets a share (§2.5).
    function openEpoch() external nonReentrant whenNotPaused {
        bool fb = fallbackMode();
        if (!fb && msg.sender != executor) revert NotExecutor(msg.sender);
        _enterFallbackIfNeeded(fb);
        if (!routesSealed) revert RoutesNotSealed();

        uint64 launch = IQZCurve(curve).launchAt();
        uint64 notBefore = lastOpenEpoch == 0
            ? (launch == 0 ? type(uint64).max : launch + QZConstants.FIRST_OPEN_EPOCH_DELAY)
            : lastOpenEpoch + QZConstants.OPEN_EPOCH_INTERVAL;
        if (block.timestamp < notBefore) revert TooEarly(notBefore);

        uint16 mask;
        uint256 active;
        for (uint8 t; t < TRACKS; ++t) {
            if (IQZRewardVault(vault).weightOf(t) != 0) {
                mask |= uint16(1 << t);
                ++active;
            }
        }
        if (active == 0) revert NoLitMachines();

        uint256 fromHook = IQZHook(hook).pullRewardPot();
        uint256 fromCurve = IQZCurve(curve).pullRewardPot();
        uint256 fromCircuit;
        if (circuit != address(0) && IQZCircuit(circuit).redirected()) {
            fromCircuit = IQZCircuit(circuit).pullCircuitPot();
        }
        emit PotsPulled(fromHook, fromCurve, fromCircuit);

        uint256 share = (IERC20(weth).balanceOf(address(this)) - totalTrackPot) / active;
        if (share == 0) revert ZeroAmount();
        for (uint8 t; t < TRACKS; ++t) {
            if (mask & (1 << t) != 0) trackPot[t] += share;
        }
        totalTrackPot += share * active;
        lastOpenEpoch = uint64(block.timestamp);
        emit EpochOpened(share * active, mask);

        if (msg.sender == executor) {
            _lastExecutorAction = uint64(block.timestamp);
            _leaveFallbackIfNeeded();
        }
    }

    // ───────────── poke ─────────────

    /// @inheritdoc IQZConverter
    function poke(uint8 track) external {
        bool fb = fallbackMode();
        bool isKeeper = msg.sender == keeper;
        if (!fb && !isKeeper) revert NotKeeper(msg.sender);
        _enterFallbackIfNeeded(fb);
        if (track >= TRACKS) revert BadTrack(track);
        if (!routesSealed) revert RoutesNotSealed();

        uint256 count = _obsCount[track];
        if (fb && count != 0) {
            uint64 notBefore = uint64(_ring[track][(count - 1) % RING]) + QZConstants.FALLBACK_MIN_OBSERVATION_SPACING;
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
        bool fb = fallbackMode();
        if (!fb && msg.sender != executor) revert NotExecutor(msg.sender);
        _enterFallbackIfNeeded(fb);
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        if (track >= TRACKS) revert BadTrack(track);
        if (!routesSealed) revert RoutesNotSealed();
        if (wethIn == 0) revert ZeroAmount();
        StockRoute memory route = _routes[track];
        if (wethIn > route.maxChunk) revert ChunkTooLarge(wethIn, route.maxChunk);
        if (wethIn > trackPot[track]) revert TrackNotActive(track);
        if (fb) _spendFallbackCap(track, wethIn, route.fallbackDailyCap);

        uint256 referenceX128 = _referencePrice(track, fb);
        uint256 usdgOut = _legWethToUsdg(track, route, wethIn, minUsdgOut);
        uint256 stockOut = _legUsdgToStock(track, route, usdgOut, referenceX128, minStockOut);

        trackPot[track] -= wethIn;
        totalTrackPot -= wethIn;

        IERC20(route.stock).forceApprove(vault, stockOut);
        IQZRewardVault(vault).notify(track, stockOut);
        emit Converted(track, wethIn, usdgOut, stockOut);

        if (msg.sender == executor) {
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
        uint256 twapX128 = QZPriceMath.priceAtTick(QZPriceMath.twapTick(_v3Pool[track], QZConstants.V3_TWAP_WINDOW));
        uint256 floor_ =
            QZPriceMath.quote(wethIn, twapX128, weth < usdg) * QZConstants.CONVERT_FLOOR_BPS / QZConstants.BPS;
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
