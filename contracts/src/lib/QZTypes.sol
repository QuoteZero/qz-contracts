// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Curve phase (§1.5). `Pending` until the owner calls `QZCurve.start(launchAt)` and `launchAt` is reached.
enum Phase {
    Pending, // 0: before launchAt (or not started)
    F0, // 1: 0..30 min, waitlist proof, max 2 QZ per wallet
    F1, // 2: 30..120 min, public, max 2 QZ per tx, 10 QZ per wallet
    F2, // 3: > 120 min until graduation, public, max 20 QZ per tx
    Graduated // 4: curve closed, pool v4 + hook live (3% fee)
}

/// @notice Fixed traits of a machine (§1.3). Table committed by TRAITS_HASH (unit A0).
/// @dev Standard machines: tier 1..4, track 0..9, relic false. Relics (#2221..#2222): tier 0, track 0 (unused), relic true.
struct Traits {
    uint8 tier;
    uint8 track;
    bool relic;
}

/// @notice Phase limits sealed in the `QZCurve` constructor (§1.5). `type(uint256).max` = no limit.
struct PhaseLimits {
    uint256 maxPerTx;
    uint256 maxPerWallet;
}

/// @notice Conversion route of one reward track (§3.2). Sealed by `QZConverter.sealRoutes()`.
struct StockRoute {
    /// @dev stock token (raw units, §3.1)
    address stock;
    /// @dev Uniswap v4 pool USDG/stock (hooks, fee and tickSpacing are part of the pool key)
    address hooks;
    uint24 poolFee;
    int24 tickSpacing;
    /// @dev v3 WETH/USDG pool fee tier for leg 1 (100 = 0.01%)
    uint24 v3Fee;
    /// @dev §3.2 `maxChunk[track]`: max WETH per `convert` call
    uint128 maxChunk;
    /// @dev §3.2 `fallbackDailyCap[track]`: max WETH per day in fallback mode
    uint128 fallbackDailyCap;
}

/// @notice Per-week Circuit state (§4.4, I8).
struct CircuitWeek {
    uint256 pot;
    uint256 completed;
    uint256 perMachine;
    bool settled;
}
