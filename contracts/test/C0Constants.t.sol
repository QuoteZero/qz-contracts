// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZConstants as K} from "../src/lib/QZConstants.sol";

/// @notice Proves the Model B constants against SPEC B.1 to B.5 and the relations between them.
contract C0ConstantsTest is Test {
    // ───────────── B.4 supply, tiers, weights ─────────────

    function test_supplyAndTiers() public pure {
        assertEq(K.TOTAL_MACHINES, 2222);
        assertEq(K.TIER_I_COUNT + K.TIER_II_COUNT + K.TIER_III_COUNT + K.TIER_IV_COUNT, K.STANDARD_MACHINES);
        assertEq(K.STANDARD_MACHINES + K.RELIC_COUNT, K.TOTAL_MACHINES);
        assertEq(K.TIER_I_COUNT, 1200);
        assertEq(K.TIER_II_COUNT, 650);
        assertEq(K.TIER_III_COUNT, 280);
        assertEq(K.TIER_IV_COUNT, 90);
        assertEq(K.FIRST_MACHINE_ID, 1);
        assertEq(K.FIRST_RELIC_ID, 2221);
        assertEq(K.LAST_RELIC_ID, K.TOTAL_MACHINES);
        assertEq(K.LAST_RELIC_ID - K.FIRST_RELIC_ID + 1, K.RELIC_COUNT);
    }

    function test_tracks() public pure {
        assertEq(K.TRACK_COUNT, 10);
        assertEq(K.MACHINES_PER_TRACK * K.TRACK_COUNT, K.STANDARD_MACHINES);
        assertEq(K.TIER_I_PER_TRACK * K.TRACK_COUNT, K.TIER_I_COUNT);
        assertEq(K.TIER_II_PER_TRACK * K.TRACK_COUNT, K.TIER_II_COUNT);
        assertEq(K.TIER_III_PER_TRACK * K.TRACK_COUNT, K.TIER_III_COUNT);
        assertEq(K.TIER_IV_PER_TRACK * K.TRACK_COUNT, K.TIER_IV_COUNT);
        assertEq(
            K.TIER_I_PER_TRACK + K.TIER_II_PER_TRACK + K.TIER_III_PER_TRACK + K.TIER_IV_PER_TRACK, K.MACHINES_PER_TRACK
        );
    }

    function test_weights() public pure {
        assertEq(K.WEIGHT_TIER_I, 10);
        assertEq(K.WEIGHT_TIER_II, 15);
        assertEq(K.WEIGHT_TIER_III, 25);
        assertEq(K.WEIGHT_TIER_IV, 40);
        assertEq(
            K.TIER_I_COUNT * K.WEIGHT_TIER_I + K.TIER_II_COUNT * K.WEIGHT_TIER_II + K.TIER_III_COUNT * K.WEIGHT_TIER_III
                + K.TIER_IV_COUNT * K.WEIGHT_TIER_IV,
            K.TOTAL_STANDARD_WEIGHT
        );
        assertEq(K.weightOf(K.TIER_I), 10);
        assertEq(K.weightOf(K.TIER_IV), 40);
        // the relics take 10% of a track's reward, 5% each
        assertEq(K.RELIC_SHARE_BPS, 1_000);
        assertEq(K.RELIC_SHARE_BPS * K.RELIC_COUNT / K.RELIC_COUNT, 1_000);
        assertEq(K.ACC_PRECISION, 1e36);
    }

    function test_weightOfRejectsRelicAndUnknownTiers() public {
        vm.expectRevert(abi.encodeWithSelector(K.BadTier.selector, uint8(0)));
        this.weightOfExt(0);
        vm.expectRevert(abi.encodeWithSelector(K.BadTier.selector, uint8(5)));
        this.weightOfExt(5);
    }

    function weightOfExt(uint8 tier) external pure returns (uint256) {
        return K.weightOf(tier);
    }

    // ───────────── B.4 mint: prices, windows, split ─────────────

    function test_prices() public pure {
        assertEq(K.USDG_DECIMALS, 6);
        assertEq(K.PRICE_GTD, 3_000_000); // $3
        assertEq(K.PRICE_FCFS, 4_000_000); // $4
        assertEq(K.PRICE_PUBLIC, 5_000_000); // $5
        assertLt(K.PRICE_GTD, K.PRICE_FCFS);
        assertLt(K.PRICE_FCFS, K.PRICE_PUBLIC);
    }

    function test_windows() public pure {
        assertEq(K.GTD_WINDOW, 24 hours);
        assertEq(K.FCFS_WINDOW, 12 hours);
        assertEq(K.PUBLIC_WINDOW_MAX, 24 hours);
        assertEq(K.GTD_WINDOW + K.FCFS_WINDOW + K.PUBLIC_WINDOW_MAX, 60 hours);
    }

    function test_mintSplitIs25To75() public pure {
        assertEq(K.MINT_REWARD_BPS, 2_500);
        assertEq(K.MINT_TREASURY_BPS, 7_500);
        assertEq(K.MINT_REWARD_BPS + K.MINT_TREASURY_BPS, K.BPS);
    }

    function test_mintSplitIsExactAtEveryPrice() public pure {
        uint256[3] memory prices = [K.PRICE_GTD, K.PRICE_FCFS, K.PRICE_PUBLIC];
        uint256[3] memory reward = [uint256(750_000), 1_000_000, 1_250_000];
        uint256[3] memory treasury = [uint256(2_250_000), 3_000_000, 3_750_000];
        for (uint256 i; i < 3; ++i) {
            uint256 r = prices[i] * K.MINT_REWARD_BPS / K.BPS;
            uint256 t = prices[i] - r;
            assertEq(r, reward[i]);
            assertEq(t, treasury[i]);
            assertEq(prices[i] * K.MINT_TREASURY_BPS % K.BPS, 0);
            assertEq(r * K.BPS, prices[i] * K.MINT_REWARD_BPS);
        }
    }

    function test_oneMintPerWalletAndNoRoyalty() public pure {
        assertEq(K.MAX_PER_WALLET, 1);
        assertEq(K.MACHINE_ROYALTY_BPS, 0);
        assertEq(K.REVEAL_MODULUS, 2222);
    }

    // ───────────── B.5 light ─────────────

    function test_lightAmountIsN() public pure {
        assertEq(K.LIGHT_AMOUNT, 100_000e18);
        assertEq(K.QZ_TOTAL_SUPPLY, 1_000_000_000e18);
        // N is 0.01% of supply, so lighting every machine locks 22.22%
        assertEq(K.LIGHT_AMOUNT * 10_000, K.QZ_TOTAL_SUPPLY);
        assertEq(K.LIGHT_AMOUNT * K.TOTAL_MACHINES, K.QZ_TOTAL_SUPPLY * 2222 / 10_000);
    }

    // ───────────── B.3 creator fee: 20:7 ─────────────

    function test_feeSplitIs20To7() public pure {
        assertEq(K.REWARD_PART, 20);
        assertEq(K.TREASURY_PART, 7);
        assertEq(K.CREATOR_TAX_BPS, 200);
        assertEq(K.PONS_BASE_FEE_BPS, 100);
        assertEq(K.PONS_PROTOCOL_SHARE_BPS, 3_000);
    }

    /// @dev What reaches the splitter per unit of volume: the base fee after Pons' share plus the whole creator tax.
    ///      The reward part must equal the creator tax exactly: 270 bps x 20/27 = 200 bps.
    function test_rewardPartEqualsTheCreatorTax() public pure {
        uint256 intoSplitterBps = K.PONS_BASE_FEE_BPS * (K.BPS - K.PONS_PROTOCOL_SHARE_BPS) / K.BPS + K.CREATOR_TAX_BPS;
        assertEq(intoSplitterBps, 270); // 0.70% of the base fee after Pons' 30%, plus the 2.00% creator tax
        assertEq(intoSplitterBps * K.REWARD_PART / (K.REWARD_PART + K.TREASURY_PART), K.CREATOR_TAX_BPS);
        assertEq(intoSplitterBps * K.TREASURY_PART / (K.REWARD_PART + K.TREASURY_PART), 70);
    }

    function testFuzz_feeSplitLeavesNoDust(uint96 total) public pure {
        uint256 reward = uint256(total) * K.REWARD_PART / (K.REWARD_PART + K.TREASURY_PART);
        uint256 treasury = uint256(total) - reward;
        assertEq(reward + treasury, total);
        assertGe(treasury * K.REWARD_PART, reward * K.TREASURY_PART);
    }

    // ───────────── entropy and converter ─────────────

    function test_entropyAndConverter() public pure {
        assertEq(K.MAX_REVEAL_GAP, 1_000);
        assertEq(K.FIRST_OPEN_EPOCH_DELAY, 24 hours);
        assertEq(K.OPEN_EPOCH_INTERVAL, 60);
        assertEq(K.CONVERT_FLOOR_BPS, 9_700);
        assertEq(K.V3_TWAP_WINDOW, 10 minutes);
        assertEq(K.MAX_SPOT_DEVIATION_BPS, 300);
        assertEq(K.CONVERT_FLOOR_BPS + K.MAX_SPOT_DEVIATION_BPS, K.BPS);
        assertEq(K.MIN_OBSERVATIONS, 9);
        assertEq(K.MEDIAN_WINDOW, 30 minutes);
        assertEq(K.FALLBACK_SILENCE, 24 hours);
        assertEq(K.FALLBACK_MIN_OBSERVATIONS, 25);
        assertEq(K.FALLBACK_MIN_OBSERVATION_SPACING, 5 minutes);
        assertEq(K.FALLBACK_WINDOW, 2 hours);
        assertEq(K.DEFAULT_MAX_CHUNK, 0.5 ether);
        assertEq(K.NFLX_MAX_CHUNK, 0.1 ether);
        assertEq(K.DEFAULT_FALLBACK_DAILY_CAP, 0.05 ether);
        assertEq(K.FALLBACK_CAP_WINDOW, 1 days);
        // 25 observations spaced 5 minutes need 2 hours
        assertEq(
            K.FALLBACK_MIN_OBSERVATIONS * K.FALLBACK_MIN_OBSERVATION_SPACING - K.FALLBACK_MIN_OBSERVATION_SPACING,
            K.FALLBACK_WINDOW
        );
    }

    function test_chainIds() public pure {
        assertEq(K.CHAIN_ID_ROBINHOOD, 4663);
        assertEq(K.CHAIN_ID_ROBINHOOD_TESTNET, 46_630);
    }
}
