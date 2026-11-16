// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title QZConstants
/// @notice Every number of the QuoteZero spec (docs/SPEC.md) in one place. Each constant cites its spec section.
///         The section numbers of the spec are the contract; the 16 Nov changes (top of the spec) win.
///         Nothing here is configurable: contracts read these at compile time and seal them in constructors.
library QZConstants {
    // ───────────────────────────── §0, §1.3 supply, machines, tiers ─────────────────────────────

    /// @dev §1.3 invariant I1: `totalSupply + totalHardwired * 1e18 == 4444e18`.
    uint256 internal constant TOTAL_SUPPLY = 4444e18;
    /// @dev §1.2: one whole QZ = one dark ticket = one potential machine.
    uint256 internal constant UNIT = 1e18;
    /// @dev §1.3: machine ids are 1..4444.
    uint256 internal constant TOTAL_MACHINES = 4444;
    uint256 internal constant FIRST_MACHINE_ID = 1;
    /// @dev §1.3 tiers: 2400 + 1300 + 560 + 180 standard machines.
    uint256 internal constant STANDARD_MACHINES = 4440;
    /// @dev §1.3: relics "Origin Wire" #4441..#4444.
    uint256 internal constant RELIC_COUNT = 4;
    uint256 internal constant FIRST_RELIC_ID = 4441;
    uint256 internal constant LAST_RELIC_ID = 4444;
    /// @dev §3.1: ten reward tracks (stock tokens). Order: NVDA, AAPL, TSLA, GME, SPY, PLTR, NFLX, RDDT, MSTR, SPCX.
    uint8 internal constant TRACK_COUNT = 10;
    /// @dev §1.3: 4440 standard machines / 10 tracks = 444 per track.
    uint256 internal constant MACHINES_PER_TRACK = 444;

    /// @dev §1.3 tier table, tier ids 1..4 = I Ticker, II Relay, III Endpoint, IV Zero Desk. Tier 0 = relic.
    uint8 internal constant TIER_RELIC = 0;
    uint8 internal constant TIER_I = 1;
    uint8 internal constant TIER_II = 2;
    uint8 internal constant TIER_III = 3;
    uint8 internal constant TIER_IV = 4;

    uint256 internal constant TIER_I_COUNT = 2400;
    uint256 internal constant TIER_II_COUNT = 1300;
    uint256 internal constant TIER_III_COUNT = 560;
    uint256 internal constant TIER_IV_COUNT = 180;
    /// @dev §1.3 per track: 240 / 130 / 56 / 18.
    uint256 internal constant TIER_I_PER_TRACK = 240;
    uint256 internal constant TIER_II_PER_TRACK = 130;
    uint256 internal constant TIER_III_PER_TRACK = 56;
    uint256 internal constant TIER_IV_PER_TRACK = 18;

    /// @dev §2.5 integer reward weights: tier I = 10, II = 15, III = 25, IV = 40 (1x / 1.5x / 2.5x / 4x times 10).
    uint256 internal constant WEIGHT_TIER_I = 10;
    uint256 internal constant WEIGHT_TIER_II = 15;
    uint256 internal constant WEIGHT_TIER_III = 25;
    uint256 internal constant WEIGHT_TIER_IV = 40;
    /// @dev §1.3: total standard weight 6470 in 1x units (2400*1 + 1300*1.5 + 560*2.5 + 180*4) = 64700 in the
    ///      integer weights of §2.5 (x10).
    uint256 internal constant TOTAL_STANDARD_WEIGHT = 64700;

    /// @dev §1.3 / §2.5: each track's distribution gives 10% to the relics, split equally over the 4 relic slots
    ///      (2.5% each). Unlit relic slots fall back to the standard machines. `rel = amount * 10% * R / 4`.
    uint256 internal constant RELIC_SHARE_BPS = 1_000;
    /// @dev §2.5 accumulator scale P = 1e36.
    uint256 internal constant ACC_PRECISION = 1e36;

    // ───────────────────────────── §1.4 fees ─────────────────────────────

    uint256 internal constant BPS = 10_000;

    /// @dev §1.4 post-graduation swap fee: 3% of the WETH side, buy and sell. Taken in the hook's afterSwap.
    uint256 internal constant HOOK_FEE_BPS = 300;
    /// @dev §1.4 split of the 3%, in bps of swap volume: 2.00 / 0.50 / 0.25 / 0.25. Sum = HOOK_FEE_BPS.
    uint256 internal constant HOOK_REWARD_BPS = 200;
    uint256 internal constant HOOK_LP_BPS = 50;
    uint256 internal constant HOOK_CIRCUIT_BPS = 25;
    uint256 internal constant HOOK_TREASURY_BPS = 25;

    /// @dev §1.4 curve phase fee: 1% of the ETH side on buy and sell (pump.fun `fee_basis_points = 100`).
    uint256 internal constant CURVE_FEE_BPS = 100;
    /// @dev §1.4 split of the curve fee, in bps of trade volume: 0.75 reward pot / 0.25 treasury. Sum = CURVE_FEE_BPS.
    uint256 internal constant CURVE_REWARD_BPS = 75;
    uint256 internal constant CURVE_TREASURY_BPS = 25;

    /// @dev §1.4 QZMachine royalty (ERC-2981): 5% = 4% reward pot + 1% treasury.
    uint256 internal constant ROYALTY_BPS = 500;
    uint256 internal constant ROYALTY_REWARD_BPS = 400;
    uint256 internal constant ROYALTY_TREASURY_BPS = 100;

    // ───────────────────────────── §1.5 launch phases and buy limits ─────────────────────────────

    /// @dev §1.5 F0 "Handshake": 0..30 min after `launchAt`, waitlist Merkle proof required.
    uint64 internal constant F0_DURATION = 30 minutes;
    /// @dev §1.5 F1 "Open Wire": 30..120 min after `launchAt`, public.
    uint64 internal constant F1_END = 120 minutes;
    /// @dev §1.5 F2: after 120 min until graduation, public.

    /// @dev §1.5 F0: max 2 QZ per wallet cumulative (no separate per-tx limit; the wallet limit binds).
    uint256 internal constant F0_MAX_PER_WALLET = 2e18;
    /// @dev §1.5 F1: max 2 QZ per tx, max 10 QZ per wallet cumulative (includes F0 purchases).
    uint256 internal constant F1_MAX_PER_TX = 2e18;
    uint256 internal constant F1_MAX_PER_WALLET = 10e18;
    /// @dev §1.5 F2: max 20 QZ per tx, no per-wallet limit.
    uint256 internal constant F2_MAX_PER_TX = 20e18;
    uint256 internal constant NO_LIMIT = type(uint256).max;

    // ───────────────────────────── §1.6 virtual bonding curve ─────────────────────────────
    // (X0 + e) * (Y0 - s) = X0 * Y0, e = real ETH reserve (excl. fees), s = QZ sold net.

    /// @dev §1.6 S = QZ sold on the curve: 3555.2 QZ (80% of 4444).
    uint256 internal constant CURVE_SUPPLY = 3555.2e18;
    /// @dev §1.6 G = QZ reserved for the pool: 888.8 QZ (= 4444 - S).
    uint256 internal constant POOL_SUPPLY = 888.8e18;
    /// @dev §1.6 X0 = virtual ETH reserve: 4 ETH.
    uint256 internal constant X0 = 4 ether;
    /// @dev §1.6 Y0 = S^2 / (S - G), exact: S^2 / (S - G) = 4740.26666...e18 wei. The wei value is rounded UP
    ///      (...666.67 -> ...667). Rounding up makes the reserve at s = S exactly E (12 ether): with the floor
    ///      (...666) `reserveAt(S)` would be E + 1 wei and violate I9 `reserveEth <= E`.
    ///      Relations (proved in test/C0Constants.t.sol): E == X0*S/(Y0-S) within 1 wei,
    ///      pool price E/G == final curve price (X0+E)/(Y0-S) within 1e-21 relative.
    uint256 internal constant Y0 = 4_740_266_666_666_666_666_667;
    /// @dev §1.6 K = X0 * Y0, the constant product.
    uint256 internal constant CURVE_K = X0 * Y0;
    /// @dev §1.6 E = graduation target: 12 ETH of real reserve at s = S. I9 cap for `reserveEth`.
    uint256 internal constant TARGET_ETH = 12 ether;

    // ───────────────────────────── §1.6 / §4.1 canonical pool (C0 decisions where spec is silent) ─────────────────────────────

    /// @dev C0 decision (spec silent): LP fee 0; the 3% is taken by the hook (§1.4).
    uint24 internal constant POOL_LP_FEE = 0;
    /// @dev C0 decision (spec silent): tickSpacing 60 so full range is [-887220, 887220].
    int24 internal constant POOL_TICK_SPACING = 60;
    int24 internal constant POOL_MIN_TICK = -887_220;
    int24 internal constant POOL_MAX_TICK = 887_220;
    /// @dev §5.1 QZHook: beforeInitialize, beforeAddLiquidity, beforeSwap, afterSwap + afterSwap return delta.
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    // ───────────────────────────── §4.3 entropy (commit-reveal) ─────────────────────────────

    /// @dev §4.3 step 2: epoch = 2 minute window on `block.timestamp`.
    uint64 internal constant EPOCH_DURATION = 120;
    /// @dev §4.3 step 5: a missing `reveal(e)` after 1 hour rolls the queue to the next open epoch.
    uint64 internal constant REVEAL_ROLLOVER = 1 hours;
    /// @dev §4.3 step 1: onion length N = 3653 days / 120 s = 2 630 160 links (10 years, leap days included).
    uint256 internal constant ONION_LENGTH = 3653 days / EPOCH_DURATION;

    // ───────────────────────────── §2.5 / §3.2 converter ─────────────────────────────

    /// @dev §2.5: first `openEpoch()` is allowed 24 h after `launchAt`.
    uint64 internal constant FIRST_OPEN_EPOCH_DELAY = 24 hours;
    /// @dev §2.5: later `openEpoch()` interval 60 s (Quotrons style).
    uint64 internal constant OPEN_EPOCH_INTERVAL = 60;
    /// @dev §3.2 leg 1: `minUsdgOut >= 97% x TWAP 10 min` of the v3 WETH/USDG pool.
    uint256 internal constant CONVERT_FLOOR_BPS = 9_700;
    uint32 internal constant V3_TWAP_WINDOW = 10 minutes;
    /// @dev §3.2 leg 2 floor: `97% x usdgIn / median`; `convert` reverts if spot deviates > 3% from the median.
    uint256 internal constant MAX_SPOT_DEVIATION_BPS = 300;
    /// @dev §3.2 normal mode: median of >= 9 observations within the last 30 min.
    uint256 internal constant MIN_OBSERVATIONS = 9;
    uint64 internal constant MEDIAN_WINDOW = 30 minutes;
    /// @dev §3.2 normal mode: keeper pokes at undisclosed random times, mean 3 minutes (off-chain schedule, ops unit K1).
    uint64 internal constant KEEPER_POKE_MEAN_INTERVAL = 3 minutes;
    /// @dev §3.2 fallback: keeper silent > 24 h makes `poke` permissionless; same window makes `convert` permissionless.
    uint64 internal constant FALLBACK_SILENCE = 24 hours;
    /// @dev §3.2 fallback median: >= 25 observations spaced >= 5 min, spanning >= 2 h.
    uint256 internal constant FALLBACK_MIN_OBSERVATIONS = 25;
    uint64 internal constant FALLBACK_MIN_OBSERVATION_SPACING = 5 minutes;
    uint64 internal constant FALLBACK_WINDOW = 2 hours;
    /// @dev §3.2 `maxChunk[track]` default 0.5 ETH (NFLX 0.1 ETH); sealed. [INFERENCE in spec, recomputed in C5]
    uint256 internal constant DEFAULT_MAX_CHUNK = 0.5 ether;
    uint256 internal constant NFLX_MAX_CHUNK = 0.1 ether;
    /// @dev §3.2 `fallbackDailyCap[track]` proposal 0.05 ETH/day, sealed. [INFERENCE in spec, recomputed in C5]
    uint256 internal constant DEFAULT_FALLBACK_DAILY_CAP = 0.05 ether;
    uint64 internal constant FALLBACK_CAP_WINDOW = 1 days;

    // ───────────────────────────── §4.4 / §4.2 Circuit ─────────────────────────────

    /// @dev §4.4 weekly Circuit. C0 decision (spec silent on the origin): week 0 starts at `launchAt`.
    uint64 internal constant CIRCUIT_WEEK = 7 days;
    /// @dev §4.2: `redirectPot()` allowed `launchAt` + 180 days if no active adapter.
    uint64 internal constant REDIRECT_DELAY = 180 days;

    // ───────────────────────────── §5.2 LayerZero ─────────────────────────────

    uint32 internal constant EID_ROBINHOOD = 30_416;
    uint32 internal constant EID_INK = 30_339;
    uint32 internal constant EID_BASE = 30_184;
    /// @dev §4.2 / §8 Tahap 2 testnet EIDs: Robinhood 40451 (chain 46630), Ink Sepolia 40358 (763373), Base Sepolia 40245 (84532).
    uint32 internal constant EID_ROBINHOOD_TESTNET = 40_451;
    uint32 internal constant EID_INK_TESTNET = 40_358;
    uint32 internal constant EID_BASE_TESTNET = 40_245;

    uint256 internal constant CHAIN_ID_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ID_INK = 57_073;
    uint256 internal constant CHAIN_ID_BASE = 8453;
    uint256 internal constant CHAIN_ID_ROBINHOOD_TESTNET = 46_630;

    /// @dev §5.1 / §5.2: at most 10 whole QZ (tickets) per OFT message, gas bound for the escrow release.
    uint256 internal constant MAX_UNITS_PER_MESSAGE = 10;
    /// @dev §5.2 shared decimals 6 (default), local 18 -> bridge minimum 0.000001 QZ.
    uint8 internal constant OFT_SHARED_DECIMALS = 6;
    /// @dev §5.2 confirmations 30 each way.
    uint64 internal constant LZ_CONFIRMATIONS = 30;
    uint8 internal constant LZ_REQUIRED_DVN_COUNT = 2;
    uint8 internal constant LZ_OPTIONAL_DVN_COUNT = 2;
    uint8 internal constant LZ_OPTIONAL_DVN_THRESHOLD = 1;
    /// @dev §5.2 enforced options: msgType SEND = 1 (SEND_AND_CALL = 2 not opened in R1/R2 phase 1).
    uint16 internal constant LZ_MSG_TYPE_SEND = 1;
    /// @dev §5.2 enforced lzReceive gas per path.
    uint128 internal constant GAS_ONFT_HOME_TO_SPOKE = 120_000;
    uint128 internal constant GAS_ONFT_SPOKE_TO_HOME = 190_000;
    uint128 internal constant GAS_OFT_HOME_TO_SPOKE = 100_000;
    uint128 internal constant GAS_OFT_SPOKE_TO_HOME = 1_200_000;
    /// @dev §5.2 rate limiter example: 200 QZ / 1 h per EID and 50 machines / 1 h per EID. [INFERENCE, calibrate on testnet]
    uint256 internal constant RATE_LIMIT_QZ = 200e18;
    uint256 internal constant RATE_LIMIT_MACHINES = 50;
    uint256 internal constant RATE_LIMIT_WINDOW = 1 hours;

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev §2.5 tier weight; reverts on tier 0 (relic) and > 4.
    error BadTier(uint8 tier);

    function weightOf(uint8 tier) internal pure returns (uint256) {
        if (tier == TIER_I) return WEIGHT_TIER_I;
        if (tier == TIER_II) return WEIGHT_TIER_II;
        if (tier == TIER_III) return WEIGHT_TIER_III;
        if (tier == TIER_IV) return WEIGHT_TIER_IV;
        revert BadTier(tier);
    }
}
