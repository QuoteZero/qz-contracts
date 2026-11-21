// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title QZConstants
/// @notice Every number of the QuoteZero Model B spec (docs/SPEC.md, "Model B" section B.1 to B.8) in one place.
///         Each constant cites its section. The Model B section wins over the archived path A text.
///         Nothing here is configurable: contracts read these at compile time and seal them in constructors.
library QZConstants {
    // ───────────────────────────── B.4 supply, machines, tiers ─────────────────────────────

    /// @dev B.4: machine ids are 1..2222, the NFT supply cap.
    uint256 internal constant TOTAL_MACHINES = 2222;
    uint256 internal constant FIRST_MACHINE_ID = 1;
    /// @dev B.4 tiers: 1200 + 650 + 280 + 90 standard machines.
    uint256 internal constant STANDARD_MACHINES = 2220;
    /// @dev B.4: relics "Origin Wire" #2221..#2222 (trait slots; the reveal rotation decides which token holds them).
    uint256 internal constant RELIC_COUNT = 2;
    uint256 internal constant FIRST_RELIC_ID = 2221;
    uint256 internal constant LAST_RELIC_ID = 2222;
    /// @dev B.1: ten reward tracks (stock tokens). Order: NVDA, AAPL, TSLA, GME, SPY, PLTR, NFLX, RDDT, MSTR, SPCX.
    uint8 internal constant TRACK_COUNT = 10;
    /// @dev 2220 standard machines / 10 tracks = 222 per track.
    uint256 internal constant MACHINES_PER_TRACK = 222;

    /// @dev Tier ids 1..4 = I Ticker, II Relay, III Endpoint, IV Zero Desk. Tier 0 = relic.
    uint8 internal constant TIER_RELIC = 0;
    uint8 internal constant TIER_I = 1;
    uint8 internal constant TIER_II = 2;
    uint8 internal constant TIER_III = 3;
    uint8 internal constant TIER_IV = 4;

    uint256 internal constant TIER_I_COUNT = 1200;
    uint256 internal constant TIER_II_COUNT = 650;
    uint256 internal constant TIER_III_COUNT = 280;
    uint256 internal constant TIER_IV_COUNT = 90;
    /// @dev Per track: 120 / 65 / 28 / 9.
    uint256 internal constant TIER_I_PER_TRACK = 120;
    uint256 internal constant TIER_II_PER_TRACK = 65;
    uint256 internal constant TIER_III_PER_TRACK = 28;
    uint256 internal constant TIER_IV_PER_TRACK = 9;

    /// @dev Integer reward weights: tier I = 10, II = 15, III = 25, IV = 40 (1x / 1.5x / 2.5x / 4x times 10).
    uint256 internal constant WEIGHT_TIER_I = 10;
    uint256 internal constant WEIGHT_TIER_II = 15;
    uint256 internal constant WEIGHT_TIER_III = 25;
    uint256 internal constant WEIGHT_TIER_IV = 40;
    /// @dev Total standard weight 3235 in 1x units (1200*1 + 650*1.5 + 280*2.5 + 90*4) = 32350 in the integer weights.
    uint256 internal constant TOTAL_STANDARD_WEIGHT = 32350;

    /// @dev Each track's distribution gives 10% to the relics, split equally over the 2 relic slots (5% each).
    ///      Unlit relic slots fall back to the standard machines. `rel = amount * 10% * R / 2`.
    uint256 internal constant RELIC_SHARE_BPS = 1_000;
    /// @dev Vault accumulator scale P = 1e36.
    uint256 internal constant ACC_PRECISION = 1e36;
    uint256 internal constant BPS = 10_000;

    // ───────────────────────────── B.4 mint: prices, windows, split ─────────────────────────────

    /// @dev B.4: USDG on Robinhood Chain has 6 decimals.
    uint8 internal constant USDG_DECIMALS = 6;
    /// @dev B.4 prices, USDG with 6 decimals. These are the defaults the deploy script passes to
    ///      the three immutable `QZMachine` constructor arguments; the contract reads its own immutables, never these.
    uint256 internal constant PRICE_GTD = 3_000_000;
    uint256 internal constant PRICE_FCFS = 4_000_000;
    uint256 internal constant PRICE_PUBLIC = 5_000_000;
    /// @dev B.4 windows: GTD 24 h, FCFS 12 h, public until sold out and at most 24 h (60 h total).
    uint64 internal constant GTD_WINDOW = 24 hours;
    uint64 internal constant FCFS_WINDOW = 12 hours;
    uint64 internal constant PUBLIC_WINDOW_MAX = 24 hours;
    /// @dev B.4 mint split, in the payment transaction: 25% to `QZConverter` (first reward pot), 75% to the treasury.
    uint256 internal constant MINT_REWARD_BPS = 2_500;
    uint256 internal constant MINT_TREASURY_BPS = 7_500;
    /// @dev B.4: one mint per wallet across all phases.
    uint256 internal constant MAX_PER_WALLET = 1;
    /// @dev B.4 reveal: `offset = keccak256(seed, lockedHash) mod 2222`.
    uint256 internal constant REVEAL_MODULUS = TOTAL_MACHINES;
    /// @dev B.4: royalty 0%.
    uint256 internal constant MACHINE_ROYALTY_BPS = 0;

    // ───────────────────────────── B.5 light ─────────────────────────────

    /// @dev B.1 / B.5: Pons fair launch, 1 billion QZ with 18 decimals.
    uint256 internal constant QZ_TOTAL_SUPPLY = 1_000_000_000e18;
    /// @dev B.5: N = 100,000 QZ (0.01% of supply) locked per machine, exactly, once, forever.
    uint256 internal constant LIGHT_AMOUNT = 100_000e18;

    // ───────────────────────────── B.3 creator fee split ─────────────────────────────

    /// @dev B.3: creator tax T = 2% (200 bps). Pons base fee 1% with a 30% protocol share (both read from Pons at
    ///      deploy by runbook B7; if `protocolFeeShareBps` is not 3000 these are recomputed before deploy).
    uint256 internal constant CREATOR_TAX_BPS = 200;
    uint256 internal constant PONS_BASE_FEE_BPS = 100;
    uint256 internal constant PONS_PROTOCOL_SHARE_BPS = 3_000;
    /// @dev B.3: what reaches the `QZFeeSplitter` is split 20:7 (reward : treasury), sealed in its constructor.
    ///      `reward = total * 20 / 27` rounded down, `treasury = total - reward`, so no dust stays behind.
    uint256 internal constant REWARD_PART = 20;
    uint256 internal constant TREASURY_PART = 7;

    // ───────────────────────────── B.2 / B.5 entropy ─────────────────────────────

    /// @dev B.4 / B.6 trimmed `QZEntropy`: one reveal may skip at most this many onion links (verified by hashing
    ///      `index - lastIndex` times). Bounds the gas of a reveal.
    uint64 internal constant MAX_REVEAL_GAP = 1_000;

    // ───────────────────────────── B.5 / SPEC §3.2 converter ─────────────────────────────

    /// @dev B.5: first `openEpoch()` is allowed 24 h after lighting opens (no race to light first).
    uint64 internal constant FIRST_OPEN_EPOCH_DELAY = 24 hours;
    /// @dev Later `openEpoch()` interval 60 s.
    uint64 internal constant OPEN_EPOCH_INTERVAL = 60;
    /// @dev §3.2 leg 1: `minUsdgOut >= 97% x TWAP 10 min` of the v3 WETH/USDG pool.
    uint256 internal constant CONVERT_FLOOR_BPS = 9_700;
    uint32 internal constant V3_TWAP_WINDOW = 10 minutes;
    /// @dev §3.2 leg 2 floor: `97% x usdgIn / median`; `convert` reverts if spot deviates > 3% from the median.
    uint256 internal constant MAX_SPOT_DEVIATION_BPS = 300;
    /// @dev §3.2 normal mode: median of >= 9 observations within the last 30 min.
    uint256 internal constant MIN_OBSERVATIONS = 9;
    uint64 internal constant MEDIAN_WINDOW = 30 minutes;
    /// @dev §3.2 normal mode: keeper pokes at undisclosed random times, mean 3 minutes (off-chain schedule).
    uint64 internal constant KEEPER_POKE_MEAN_INTERVAL = 3 minutes;
    /// @dev §3.2 fallback: keeper silent > 24 h makes `poke` permissionless; same window makes `convert` permissionless.
    uint64 internal constant FALLBACK_SILENCE = 24 hours;
    /// @dev §3.2 fallback median: >= 25 observations spaced >= 5 min, spanning >= 2 h.
    uint256 internal constant FALLBACK_MIN_OBSERVATIONS = 25;
    uint64 internal constant FALLBACK_MIN_OBSERVATION_SPACING = 5 minutes;
    uint64 internal constant FALLBACK_WINDOW = 2 hours;
    /// @dev §3.2 `maxChunk[track]` default 0.5 ETH (NFLX 0.1 ETH); sealed.
    uint256 internal constant DEFAULT_MAX_CHUNK = 0.5 ether;
    uint256 internal constant NFLX_MAX_CHUNK = 0.1 ether;
    /// @dev §3.2 `fallbackDailyCap[track]` 0.05 ETH/day, sealed.
    uint256 internal constant DEFAULT_FALLBACK_DAILY_CAP = 0.05 ether;
    uint64 internal constant FALLBACK_CAP_WINDOW = 1 days;

    // ───────────────────────────── chains ─────────────────────────────

    uint256 internal constant CHAIN_ID_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ID_ROBINHOOD_TESTNET = 46_630;

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev Tier weight; reverts on tier 0 (relic) and > 4.
    error BadTier(uint8 tier);

    function weightOf(uint8 tier) internal pure returns (uint256) {
        if (tier == TIER_I) return WEIGHT_TIER_I;
        if (tier == TIER_II) return WEIGHT_TIER_II;
        if (tier == TIER_III) return WEIGHT_TIER_III;
        if (tier == TIER_IV) return WEIGHT_TIER_IV;
        revert BadTier(tier);
    }
}
