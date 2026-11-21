// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Where the machine mint stands (SPEC Model B, B.4). One value per moment, derived from `block.timestamp`,
///         the sealed schedule and the mint counters; nothing stores it.
enum MintPhase {
    Pending, // 0: no schedule yet, or before the GTD window opens
    Gtd, // 1: GTD window, 24 h, GTD Merkle proof, GTD price
    Fcfs, // 2: FCFS window, 12 h, FCFS Merkle proof, FCFS price
    Public, // 3: public window, at most 24 h, no proof, public price
    Closed // 4: sold out, window over, or `finalizeMint` was called
}

/// @notice Fixed traits of a machine (SPEC §1.3). Table committed by TRAITS_HASH (unit A0).
/// @dev Standard machines: tier 1..4, track 0..9, relic false. Relics (#2221..#2222): tier 0, track 0 (unused), relic true.
struct Traits {
    uint8 tier;
    uint8 track;
    bool relic;
}

/// @notice Conversion route of one reward track (SPEC §3.2). Sealed by `QZConverter.sealRoutes()`.
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
