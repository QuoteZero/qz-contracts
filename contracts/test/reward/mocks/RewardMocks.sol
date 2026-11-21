// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZMachine} from "../../../src/interfaces/IQZMachine.sol";
import {IQZRewardVault} from "../../../src/interfaces/IQZRewardVault.sol";
import {StockRoute} from "../../../src/lib/QZTypes.sol";
import {QZPriceMath} from "../../../src/reward/QZPriceMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Plain 18-decimal (configurable) ERC-20 with free mint.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external virtual returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Behaves like the RHJ `Stock` token where it matters to the reward vault (§3.1): `transfer`,
///         `transferFrom` and `approve` revert when the token is paused or a party is blocklisted; `adminBurn` takes
///         tokens from any holder without consent and without the pause/blocklist checks.
contract MockStock is MockERC20 {
    bool public tokenPaused;
    mapping(address => bool) public blocked;
    /// @dev when set, `transfer` calls back into this target (reentrancy probe, T9)
    address public reentryTarget;
    bytes public reentryData;
    bool public swallowReentryRevert;

    constructor() MockERC20("Mock Stock", "MSTK", 18) {}

    function setPaused(bool p) external {
        tokenPaused = p;
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function adminBurn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function setReentry(address target, bytes calldata data, bool swallowRevert) external {
        reentryTarget = target;
        reentryData = data;
        swallowReentryRevert = swallowRevert;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        require(!tokenPaused, "paused");
        require(!blocked[msg.sender] && !blocked[spender], "blocked");
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(!tokenPaused, "paused");
        require(!blocked[from] && !blocked[to], "blocked");
        super._transfer(from, to, amount);
        if (reentryTarget != address(0)) {
            address t = reentryTarget;
            reentryTarget = address(0);
            (bool ok, bytes memory ret) = t.call(reentryData);
            if (!ok && !swallowReentryRevert) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// @notice Stand-in for `QZMachine`: ownership, transfer and the trait table the vault reads. `traitsOf` reverts before
///         the reveal like the real machine.
contract MockMachine {
    struct M {
        address owner;
        uint8 tier;
        uint8 track;
        bool relic;
    }

    error NotRevealed();

    mapping(uint256 => M) public machines;
    mapping(uint256 => bool) public unrevealed;

    function set(uint256 id, address owner_, uint8 tier, uint8 track, bool relic) external {
        machines[id] = M(owner_, tier, track, relic);
        unrevealed[id] = false;
    }

    /// @dev a minted token whose traits are not known yet
    function setUnrevealed(uint256 id, address owner_) external {
        machines[id] = M(owner_, 0, 0, false);
        unrevealed[id] = true;
    }

    function traitsOf(uint256 id) external view returns (uint8, uint8, bool) {
        if (unrevealed[id]) revert NotRevealed();
        M memory m = machines[id];
        return (m.tier, m.track, m.relic);
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = machines[id].owner;
        require(o != address(0), "nonexistent");
        return o;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(machines[id].owner == from, "not owner");
        machines[id].owner = to;
    }
}

/// @notice WETH9 behaviour the converter needs: `deposit` wraps the ETH sent with the call one to one.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }
}

/// @notice Mock of the v3 WETH/USDG pool oracle and of SwapRouter02 in one contract (and of the v3 factory).
///         The pool "price" is `priceAtTick(tick)`; the router pays that price times `(1e6 - skewPips) / 1e6`.
contract MockV3 {
    MockERC20 public immutable weth;
    MockERC20 public immutable usdg;
    int24 public tick;
    uint256 public skewPips;
    bool public wethIsToken0;

    constructor(MockERC20 weth_, MockERC20 usdg_, int24 tick_) {
        weth = weth_;
        usdg = usdg_;
        tick = tick_;
        wethIsToken0 = address(weth_) < address(usdg_);
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function setSkewPips(uint256 s) external {
        skewPips = s;
    }

    // factory
    function getPool(address, address, uint24) external view returns (address) {
        return address(this);
    }

    // pool oracle
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory c, uint160[] memory s) {
        c = new int56[](secondsAgos.length);
        s = new uint160[](secondsAgos.length);
        // cumulative(t) = tick * (t0 - secondsAgo) with t0 = now: the mean over any window is `tick`
        for (uint256 i; i < secondsAgos.length; ++i) {
            c[i] = int56(tick) * (int56(uint56(block.timestamp)) - int56(uint56(secondsAgos[i])));
        }
    }

    // router
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        weth.transferFrom(msg.sender, address(this), p.amountIn);
        uint256 px = QZPriceMath.priceAtTick(tick);
        amountOut = QZPriceMath.quote(p.amountIn, px, wethIsToken0) * (1_000_000 - skewPips) / 1_000_000;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        usdg.mint(p.recipient, amountOut);
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
}

/// @notice Stand-in for `QZConverter` in vault-only tests: serves `routeOf` and delivers stock through `notify`.
contract MockConverter {
    MockStock[10] public stocks;

    constructor() {
        for (uint256 i; i < 10; ++i) {
            stocks[i] = new MockStock();
        }
    }

    function routeOf(uint8 track) external view returns (StockRoute memory r) {
        r.stock = address(stocks[track]);
    }

    /// @dev mints `amount` stock to itself, approves the vault and calls `notify`.
    function deliver(IQZRewardVault vault, uint8 track, uint256 amount) external {
        stocks[track].mint(address(this), amount);
        stocks[track].approve(address(vault), amount);
        vault.notify(track, amount);
    }
}

/// @notice Constant-liquidity stand-in for the Uniswap v4 `PoolManager` (the real one needs the uninitialised nested
///         `solmate` submodule of v4-core, so it cannot be compiled here). Same entry points the converter uses
///         (`unlock`, `swap`, `sync`, `settle`, `take`, `extsload` for `StateLibrary.getSlot0`), the same swap step math
///         (`SwapMath.computeSwapStep`) and the same flash accounting: every currency delta must be settled before `unlock`
///         returns. The real PoolManager is exercised by the fork test (`ConverterFork.t.sol`).
contract MockPoolManager {
    struct Pool {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint24 fee;
        bool initialized;
    }

    mapping(bytes32 poolId => Pool) public pools;
    mapping(bytes32 slot => bytes32 value) internal _store;

    address internal _locker;
    mapping(address currency => int256) internal _delta;
    address[] internal _touched;
    address internal _synced;
    uint256 internal _syncedBalance;

    error CurrencyNotSettled(address currency, int256 delta);
    error AlreadyUnlocked();
    error ManagerLocked();

    function poolId(PoolKey memory key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96, uint128 liquidity) external {
        bytes32 id = poolId(key);
        pools[id] = Pool(sqrtPriceX96, liquidity, key.fee, true);
        _writeSlot0(id);
    }

    /// @dev test helper: set the spot price of a pool (like an outside swap would).
    function setSqrtPrice(PoolKey memory key, uint160 sqrtPriceX96) external {
        bytes32 id = poolId(key);
        pools[id].sqrtPriceX96 = sqrtPriceX96;
        _writeSlot0(id);
    }

    function _writeSlot0(bytes32 id) internal {
        Pool memory p = pools[id];
        int24 tick = TickMath.getTickAtSqrtPrice(p.sqrtPriceX96);
        bytes32 packed = bytes32(uint256(p.sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(p.fee) << 208));
        _store[keccak256(abi.encode(id, uint256(6)))] = packed;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _store[slot];
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (_locker != address(0)) revert AlreadyUnlocked();
        _locker = msg.sender;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        for (uint256 i; i < _touched.length; ++i) {
            int256 d = _delta[_touched[i]];
            if (d != 0) revert CurrencyNotSettled(_touched[i], d);
        }
        delete _touched;
        _locker = address(0);
    }

    function _account(address currency, int256 d) internal {
        if (_delta[currency] == 0) _touched.push(currency);
        _delta[currency] += d;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta)
    {
        if (msg.sender != _locker) revert ManagerLocked();
        bytes32 id = poolId(key);
        Pool storage p = pools[id];
        require(p.initialized, "pool not initialized");
        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 feeAmount) = SwapMath.computeSwapStep(
            p.sqrtPriceX96, params.sqrtPriceLimitX96, p.liquidity, params.amountSpecified, p.fee
        );
        p.sqrtPriceX96 = next;
        _writeSlot0(id);
        int128 in_ = -int128(int256(amountIn + feeAmount));
        int128 out_ = int128(int256(amountOut));
        (address cin, address cout) = params.zeroForOne
            ? (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1))
            : (Currency.unwrap(key.currency1), Currency.unwrap(key.currency0));
        _account(cin, int256(in_));
        _account(cout, int256(out_));
        return params.zeroForOne ? toBalanceDelta(in_, out_) : toBalanceDelta(out_, in_);
    }

    function sync(Currency currency) external {
        _synced = Currency.unwrap(currency);
        _syncedBalance = MockERC20(_synced).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = MockERC20(_synced).balanceOf(address(this)) - _syncedBalance;
        _account(_synced, int256(paid));
        _synced = address(0);
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (msg.sender != _locker) revert ManagerLocked();
        _account(Currency.unwrap(currency), -int256(amount));
        MockERC20(Currency.unwrap(currency)).transfer(to, amount);
    }
}
