// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Stand-ins for what the Robinhood testnet (46630) lacks, so the contracts can be deployed there. The testnet
///         has the Uniswap v4 PoolManager and Permit2 at the mainnet addresses, a real WETH9 and five real stock tokens
///         (TSLA, AMZN, PLTR, NFLX, AMD) that do not cover the ten QuoteZero tracks, but no USDG and no Uniswap v3.
///         These mocks are deployed by `DeployTestnetAssets`; none of them is meant for a live production chain.
///
///         They are tradeable, so `QZConverter.convert` runs unmodified on testnet: leg 1 (WETH -> USDG) goes through the
///         v3 stand-in at an owner-settable rate that the pool stand-in also reports as its TWAP (the converter's 97%
///         floor is therefore checked against a real quote), leg 2 (USDG -> stock) is a real swap on the real v4
///         PoolManager against liquidity `MockLiquiditySeeder` put into the ten pools.

interface IMint {
    function mint(address to, uint256 amount) external;
}

/// @dev Stock token stand-in with an open `mint`; one instance per track.
contract MockStock is ERC20 {
    string private _symbol;

    constructor(string memory symbol_) {
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return string.concat("Mock ", _symbol);
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev USDG stand-in: 6 decimals, open `mint`.
contract MockUSDG is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock USDG";
    }

    function symbol() public pure override returns (string memory) {
        return "mUSDG";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev v3 WETH/USDG pool stand-in: one owner-settable rate (USDG raw units per 1e18 WETH wei). `observe` reports a
///      constant tick equal to that rate, so the converter's 10 minute TWAP is the rate. Not a real pool: no liquidity,
///      no swaps (the router below prices at the same rate).
contract MockV3Pool is Ownable {
    address public immutable weth;
    address public immutable usdg;
    uint256 public usdgPerWeth;
    int24 public tick;

    event RateSet(uint256 usdgPerWeth, int24 tick);

    constructor(address weth_, address usdg_, address owner_, uint256 usdgPerWeth_) {
        weth = weth_;
        usdg = usdg_;
        _initializeOwner(owner_);
        _setRate(usdgPerWeth_);
    }

    function setRate(uint256 usdgPerWeth_) external onlyOwner {
        _setRate(usdgPerWeth_);
    }

    function _setRate(uint256 r) internal {
        require(r != 0, "rate zero");
        usdgPerWeth = r;
        // price = token1 / token0 in raw units; sqrtPriceX96 = sqrt(price * 2^192)
        uint256 priceX192 = weth < usdg ? FullMath.mulDiv(r, 1 << 192, 1e18) : FullMath.mulDiv(1e18, 1 << 192, r);
        tick = TickMath.getTickAtSqrtPrice(uint160(FixedPointMathLib.sqrt(priceX192)));
        emit RateSet(r, tick);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = int56(tick) * (int56(uint56(block.timestamp)) - int56(uint56(secondsAgos[i])));
        }
    }
}

/// @dev `getPool` answers with the one pool stand-in for the WETH/USDG pair at any fee tier.
contract MockV3Factory {
    address public immutable pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

/// @dev SwapRouter02 shape the converter calls (`factory()`, `exactInputSingle`): WETH in, USDG out at the pool
///      stand-in's rate (USDG is minted: the mock has no inventory to run dry). Enforces `amountOutMinimum`.
contract MockV3Router {
    address public immutable factory;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    constructor(address factory_) {
        factory = factory_;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        MockV3Pool pool = MockV3Pool(MockV3Factory(factory).pool());
        require(p.tokenIn == pool.weth() && p.tokenOut == pool.usdg(), "MockV3Router: pair");
        amountOut = FullMath.mulDiv(p.amountIn, pool.usdgPerWeth(), 1e18);
        require(amountOut >= p.amountOutMinimum, "Too little received");
        require(ERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn), "pull");
        MockUSDG(p.tokenOut).mint(p.recipient, amountOut);
    }
}

/// @dev Puts full-range liquidity into an initialised v4 pool of two open-`mint` mocks: mints exactly what the
///      PoolManager asks for straight to it. The position belongs to this contract and is never removed.
contract MockLiquiditySeeder is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager pm) {
        poolManager = pm;
    }

    function seed(PoolKey calldata key, uint256 liquidity) external {
        poolManager.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PoolManager");
        (PoolKey memory key, uint256 liquidity) = abi.decode(data, (PoolKey, uint256));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(liquidity),
                salt: bytes32(0)
            }),
            ""
        );
        _pay(key.currency0, delta.amount0());
        _pay(key.currency1, delta.amount1());
        return "";
    }

    function _pay(Currency c, int128 amount) internal {
        require(amount <= 0, "seed owes nothing back");
        if (amount == 0) return;
        poolManager.sync(c);
        IMint(Currency.unwrap(c)).mint(address(poolManager), uint256(uint128(-amount)));
        poolManager.settle();
    }
}
