// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ConverterFixture} from "./ConverterFixture.sol";
import {QZConverter} from "../../src/reward/QZConverter.sol";
import {IQZConverter} from "../../src/interfaces/IQZConverter.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";

/// @notice Model B behaviour of `QZConverter`: the pot is the splitter's ETH (wrapped) plus the mint seed in USDG,
///         `convertUsdg` spends the USDG pot, the first epoch follows the Forge's lighting time, and the pot
///         accounting stays exact under random programs (I6 on the converter side).
contract ConverterModelBTest is ConverterFixture {
    uint256 internal constant CAP = QZConstants.DEFAULT_FALLBACK_DAILY_CAP;

    function _ready(uint8 t, uint256 ethAmt, uint256 usdgAmt) internal {
        uint8[] memory tr = new uint8[](1);
        tr[0] = t;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(ethAmt, usdgAmt);
        _open();
    }

    function _convertUsdg(uint8 t, uint256 usdgIn) internal {
        vm.prank(executor);
        conv.convertUsdg(t, usdgIn, 1, block.timestamp + 1);
    }

    function _fbPokes(uint8 t) internal {
        for (uint256 i; i < 25; ++i) {
            vm.prank(attacker);
            conv.poke(t);
            vm.warp(block.timestamp + 5 minutes);
        }
    }

    function _enterFallback() internal {
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1 days + 1);
        assertTrue(conv.fallbackMode());
    }

    // ───────────── convertUsdg: both token orders ─────────────

    function _runConvertUsdg(uint8 t) internal {
        _ready(t, 0, 500e6);
        assertEq(_potUsdg(t), 500e6);
        assertEq(_potWeth(t), 0);

        vm.recordLogs();
        _convertUsdg(t, 400e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(conv) && logs[i].topics[0] == IQZConverter.Converted.selector) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), t);
                (uint256 wethIn, uint256 usdgOut, uint256 stockOut) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(wethIn, 0, "no WETH was spent");
                assertEq(usdgOut, 400e6);
                assertEq(stockOut, vault.totalNotified(t));
            }
        }
        assertTrue(found, "Converted emitted");

        assertEq(_potUsdg(t), 100e6);
        assertEq(conv.totalTrackUsdg(), 100e6);
        assertEq(usdg.balanceOf(address(conv)), 100e6, "only the spent USDG left");
        assertEq(stocks[t].balanceOf(address(conv)), 0, "nothing stays in the converter");
        uint256 got = vault.totalNotified(t);
        assertEq(stocks[t].balanceOf(address(vault)), got);
        assertGt(got, _fairStock(t, 400e6) * 985 / 1000, "within 1.5% of the fair quote");
        assertLt(got, _fairStock(t, 400e6) * 1001 / 1000);

        vm.prank(alice);
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tracks = new uint8[](1);
        ids[0] = 100 + t;
        tracks[0] = t;
        vault.claim(ids, tracks);
        assertEq(stocks[t].balanceOf(alice), got, "the machine owner claims it");
    }

    function test_convertUsdg_usdgIsCurrency0() public {
        assertTrue(_usdgIs0(1));
        _runConvertUsdg(1);
    }

    function test_convertUsdg_usdgIsCurrency1() public {
        assertFalse(_usdgIs0(0));
        _runConvertUsdg(0);
    }

    /// The WETH conversion never touches the USDG pot: leg 1's USDG is spent by leg 2 in the same call.
    function test_convert_leavesTheUsdgPotAlone() public {
        _ready(0, 1 ether, 500e6);
        uint256 usdgPot = _potUsdg(0);
        _convert(0, 0.5 ether);
        assertEq(_potUsdg(0), usdgPot);
        assertEq(usdg.balanceOf(address(conv)), usdgPot, "leg 1's USDG was fully spent in leg 2");
        assertEq(_potWeth(0), 0.5 ether);
    }

    // ───────────── convertUsdg: guards ─────────────

    function test_convertUsdg_guards() public {
        _ready(0, 0, 500e6);
        uint256 limit = conv.usdgChunkLimit(0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotExecutor.selector, attacker));
        conv.convertUsdg(0, 1e6, 1, block.timestamp + 1);

        vm.startPrank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IQZErrors.DeadlineExpired.selector, block.timestamp - 1, block.timestamp)
        );
        conv.convertUsdg(0, 1e6, 1, block.timestamp - 1);
        vm.expectRevert(IQZErrors.ZeroAmount.selector);
        conv.convertUsdg(0, 0, 1, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.BadTrack.selector, uint8(10)));
        conv.convertUsdg(10, 1e6, 1, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TrackNotActive.selector, uint8(3)));
        conv.convertUsdg(3, 1e6, 1, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.PotTooSmall.selector, uint8(0), 500e6 + 1, 500e6));
        conv.convertUsdg(0, 500e6 + 1, 1, block.timestamp + 1);
        vm.stopPrank();

        // the USDG pot must be larger than one chunk for the chunk check to be the binding one
        assertGt(limit, 500e6);
        _fundPots(0, 2 * limit);
        vm.warp(block.timestamp + 60);
        _open();
        vm.prank(executor);
        vm.expectRevert();
        conv.convertUsdg(0, limit * 2, 1, block.timestamp + 1);
        vm.prank(executor);
        try conv.convertUsdg(0, limit + limit / 50, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.ChunkTooLarge.selector);
        }
        vm.prank(executor);
        conv.convertUsdg(0, limit - limit / 50, 1, block.timestamp + 1);
    }

    function test_convertUsdg_pauseAndSeal() public {
        vm.prank(executor);
        vm.expectRevert(IQZConverter.RoutesNotSealed.selector);
        conv.convertUsdg(0, 1e6, 1, block.timestamp + 1);
        vm.expectRevert(IQZConverter.RoutesNotSealed.selector);
        conv.usdgChunkLimit(0);

        _ready(0, 0, 500e6);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.BadTrack.selector, uint8(10)));
        conv.usdgChunkLimit(10);
        vm.prank(pauser);
        conv.pause();
        vm.prank(executor);
        vm.expectRevert(IQZErrors.EnforcedPause.selector);
        conv.convertUsdg(0, 1e6, 1, block.timestamp + 1);
    }

    /// `usdgChunkLimit` is `maxChunk` WETH at the v3 TWAP (~2060 USDG per WETH here), rounded down.
    function test_usdgChunkLimit_isMaxChunkAtTheTwap() public {
        _setRoutesAndSeal();
        uint256 expected = QZConstants.DEFAULT_MAX_CHUNK * 2060e6 / 1e18;
        assertApproxEqRel(conv.usdgChunkLimit(0), expected, 0.005e18);
        assertApproxEqRel(conv.usdgChunkLimit(1), expected, 0.005e18);
    }

    /// Leg 2 keeps its 97%-of-median floor: a caller floor cannot lower it and a bad pool price is refused.
    function test_convertUsdg_keepsTheMedianFloorsAndSpotGuard() public {
        _ready(0, 0, 500e6);
        uint160 honest = _spot(0);
        _shiftStockPerUsdg(0, 400);
        vm.prank(executor);
        try conv.convertUsdg(0, 100e6, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.SpotDeviatesFromMedian.selector);
        }
        _setSpot(0, honest);
        uint256 tooMuch = _fairStock(0, 100e6) * 2;
        vm.prank(executor);
        vm.expectRevert(); // asks for more stock than the pool can pay
        conv.convertUsdg(0, 100e6, tooMuch, block.timestamp + 1);
        _convertUsdg(0, 100e6);
    }

    // ───────────── convertUsdg: fallback cap shares the WETH budget ─────────────

    function test_convertUsdg_fallbackCapIsMeasuredInWeth() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _fundPots(0, 1000e6);
        _open(); // permissionless in fallback
        _fbPokes(0);

        // CAP = 0.05 WETH ~ 103 USDG: 100 USDG fits, 10 USDG more does not
        vm.startPrank(attacker);
        conv.convertUsdg(0, 100e6, 1, block.timestamp + 1);
        assertApproxEqRel(conv.fallbackSpentToday(0), uint256(100e6) * 1e18 / 2060e6, 0.002e18);
        try conv.convertUsdg(0, 10e6, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.DailyCapExceeded.selector);
        }
        vm.stopPrank();
    }

    function test_convertUsdg_fallbackMinimumChunk() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _fundPots(0, 1000e6);
        _open();
        _fbPokes(0);
        vm.prank(attacker);
        try conv.convertUsdg(0, 1e4, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.ChunkBelowFallbackMinimum.selector);
        }
    }

    /// WETH and USDG conversions draw on one cap: the attacker cannot get 2x by alternating.
    function test_fallback_wethAndUsdgShareTheCap() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _fundPots(1 ether, 1000e6);
        _open();
        _fbPokes(0);
        vm.startPrank(attacker);
        conv.convert(0, 0.03 ether, 1, 1, block.timestamp + 1);
        // ~0.03 WETH of USDG no longer fits in the remaining 0.02
        try conv.convertUsdg(0, 62e6, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.DailyCapExceeded.selector);
        }
        conv.convertUsdg(0, 40e6, 1, block.timestamp + 1); // ~0.0194 WETH
        vm.stopPrank();
        assertLe(conv.fallbackSpentToday(0), CAP);
    }

    // ───────────── ETH pot, track isolation, DoS ─────────────

    /// ETH that arrives after an epoch waits for the next one; a conversion in between spends only assigned pots.
    function test_ethArrivingLaterIsNotSpendable() public {
        _ready(0, 1 ether, 0);
        _fundPots(5 ether, 0);
        _convert(0, 0.5 ether);
        _convert(0, 0.5 ether);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TrackNotActive.selector, uint8(0)));
        conv.convert(0, 0.1 ether, 1, 1, block.timestamp + 1);
        (uint256 eth,,) = conv.unassignedPot();
        assertEq(eth, 5 ether, "the later ETH waits for its epoch");
    }

    /// Anyone can send ETH, WETH or USDG to the converter: it only enlarges the next epoch, never breaks one.
    function test_donationsOnlyEnlargeThePot() public {
        _ready(0, 1 ether, 0);
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool ok,) = address(conv).call{value: 1 wei}("");
        assertTrue(ok);
        weth.mint(address(conv), 3);
        usdg.mint(address(conv), 7);
        vm.warp(block.timestamp + 60);
        _open();
        assertEq(_potWeth(0), 1 ether + 1 + 3);
        assertEq(_potUsdg(0), 7);
        _convert(0, 0.5 ether);
    }

    /// A relic-only world still parks the money: nothing is assigned, nothing is lost.
    function test_noStandardTrackKeepsTheMoney() public {
        machine.set(2221, alice, 0, 0, true);
        vault.register(2221);
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours);
        _fundPots(1 ether, 100e6);
        _open();
        (uint256 eth, uint256 w, uint256 u) = conv.potBalance();
        assertEq(eth, 0);
        assertEq(w, 1 ether);
        assertEq(u, 100e6);
        assertEq(conv.totalTrackWeth(), 0);
        assertEq(conv.totalTrackUsdg(), 0);
    }

    /// A late-lit machine gets none of the stock converted before it was lit (checked through the converter).
    function test_lateLitMachineGetsNothingFromEarlierConversions() public {
        _ready(0, 1 ether, 0);
        _convert(0, 0.5 ether);
        machine.set(777, makeAddr("bob"), 1, 0, false);
        vault.register(777);
        assertEq(vault.claimable(777, 0), 0);
        assertGt(vault.claimable(100, 0), 0);
    }

    // ───────────── I6 on the converter: random programs ─────────────

    uint256 internal _fundedEth;
    uint256 internal _fundedUsdg;
    uint256 internal _spentWeth;
    uint256 internal _spentUsdg;
    bool[10] internal _lit;
    uint256 internal _litCount;

    /// @dev Random sequence of: ETH / USDG arriving, lighting a machine, opening an epoch, converting a pot (WETH or
    ///      USDG) and claiming. After every step: the pots are covered by the balances, nothing is created or lost,
    ///      the stock sits in the vault, and the vault conserves.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_I6_converterAndVaultConserve(uint256 seed) public {
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours - 20 minutes);
        for (uint256 s; s < 14; ++s) {
            seed = uint256(keccak256(abi.encode(seed, s)));
            _fuzzStep(seed);
            _assertConverterConserved();
        }
    }

    function _fuzzStep(uint256 seed) internal {
        uint256 op = seed % 7;
        uint256 r = seed >> 8;
        uint8 t = uint8(r % 10);
        if (op == 0) {
            uint256 amt = 1 + (r >> 4) % 5 ether;
            _fundPots(amt, 0);
            _fundedEth += amt;
        } else if (op == 1) {
            uint256 amt = 1 + (r >> 4) % 5000e6;
            _fundPots(0, amt);
            _fundedUsdg += amt;
        } else if (op == 2 && !_lit[t]) {
            _lightTrack(t);
            _lit[t] = true;
            ++_litCount;
        } else if (op == 3) {
            if (block.timestamp < conv.firstEpochAt()) vm.warp(conv.firstEpochAt());
            vm.warp(block.timestamp + 60);
            vm.prank(executor);
            if (_litCount == 0) {
                vm.expectRevert(IQZConverter.NoLitMachines.selector);
            }
            conv.openEpoch();
        } else if (op == 4 && _lit[t]) {
            _fuzzConvertWeth(t, r >> 4);
        } else if (op == 5 && _lit[t]) {
            _fuzzConvertUsdg(t, r >> 4);
        } else if (op == 6 && _lit[t]) {
            uint256[] memory ids = new uint256[](1);
            uint8[] memory tracks = new uint8[](1);
            ids[0] = 100 + t;
            tracks[0] = t;
            vm.prank(alice);
            try vault.claim(ids, tracks) {} catch {}
        }
    }

    /// @dev Fresh keeper observations (the 30 min window moves with the fuzzed warps), then a call sized by `r`.
    function _freshObservations(uint8 t) internal {
        for (uint256 i; i < 9; ++i) {
            _poke(t);
            vm.warp(block.timestamp + 60);
        }
    }

    function _fuzzConvertWeth(uint8 t, uint256 r) internal {
        uint256 pot = _potWeth(t);
        if (pot < 1e12) return;
        uint256 cap = pot < QZConstants.DEFAULT_MAX_CHUNK ? pot : QZConstants.DEFAULT_MAX_CHUNK;
        uint256 amt = 1e12 + r % (cap - 1e12 + 1);
        _freshObservations(t);
        _convert(t, amt);
        _spentWeth += amt;
    }

    function _fuzzConvertUsdg(uint8 t, uint256 r) internal {
        uint256 pot = _potUsdg(t);
        if (pot < 1e4) return;
        uint256 limit = conv.usdgChunkLimit(t);
        uint256 cap = pot < limit ? pot : limit;
        if (cap < 1e4) return;
        uint256 amt = 1e4 + r % (cap - 1e4 + 1);
        _freshObservations(t);
        vm.prank(executor);
        conv.convertUsdg(t, amt, 1, block.timestamp + 1);
        _spentUsdg += amt;
    }

    function _assertConverterConserved() internal view {
        uint256 sumW;
        uint256 sumU;
        for (uint8 t; t < 10; ++t) {
            sumW += _potWeth(t);
            sumU += _potUsdg(t);
            // stock: whatever was bought is in the vault, none stays here, and the vault holds notified - claimed
            assertEq(stocks[t].balanceOf(address(conv)), 0, "stock stuck in the converter");
            assertEq(
                stocks[t].balanceOf(address(vault)) + vault.totalClaimed(t), vault.totalNotified(t), "vault conserves"
            );
            if (_lit[t]) {
                assertLe(vault.claimable(100 + t, t) + vault.totalClaimed(t), vault.totalNotified(t), "I6");
            }
        }
        assertEq(sumW, conv.totalTrackWeth(), "WETH pots sum to the total");
        assertEq(sumU, conv.totalTrackUsdg(), "USDG pots sum to the total");

        (uint256 eth, uint256 w, uint256 u) = conv.potBalance();
        assertGe(w, sumW, "WETH balance covers the pots");
        assertGe(u, sumU, "USDG balance covers the pots");
        // nothing created, nothing lost: every ETH wei that came in is held (as ETH or WETH) or was spent
        assertEq(eth + w + _spentWeth, _fundedEth, "ETH/WETH conserved");
        assertEq(u + _spentUsdg, _fundedUsdg, "USDG conserved");
    }

    // ───────────── F4.2: observation spacing in normal mode ─────────────

    /// A keeper that pokes nine times in one transaction (one block) cannot build a median: the second poke of the
    /// same second reverts, so a price pushed for one transaction is one observation, not nine.
    function test_F42_keeperCannotPokeNineTimesInOneTransaction() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();

        uint160 honest = _spot(0);
        _shiftStockPerUsdg(0, -3000); // the manipulated pool price, held for this transaction only
        _poke(0);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TooEarly.selector, uint64(block.timestamp + 60)));
        _poke(0);
        (, uint256 n) = conv.medianPrice(0);
        assertEq(n, 1, "one observation");

        // and one observation is not a reference: the manipulated price converts nothing
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotEnoughObservations.selector, uint8(0), 1, 9));
        conv.convert(0, 0.5 ether, 1, 1, block.timestamp + 1);
        _setSpot(0, honest);
    }

    /// Spacing is exactly 60 s, and nine observations spaced 60 s span 8 minutes and are enough to convert.
    function test_F42_sixtySecondSpacingStillSatisfiesTheMedianRule() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();

        _poke(0);
        vm.warp(block.timestamp + 59);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TooEarly.selector, uint64(block.timestamp + 1)));
        _poke(0);
        vm.warp(block.timestamp + 1);
        for (uint256 i = 1; i < 9; ++i) {
            _poke(0);
            vm.warp(block.timestamp + 60);
        }
        (, uint256 n) = conv.medianPrice(0);
        assertEq(n, 9);
        _convert(0, 0.5 ether);
    }

    /// A manipulation has to survive eight minutes of other trades: pokes 60 s apart while the price is held
    /// manipulated and then restored leave an honest spot, which the 3% guard compares against the manipulated median.
    function test_F42_manipulatedMedianIsStoppedOnceThePriceIsUnwound() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();

        uint160 honest = _spot(0);
        _shiftStockPerUsdg(0, -3000);
        for (uint256 i; i < 9; ++i) {
            _poke(0);
            vm.warp(block.timestamp + 60);
        }
        _setSpot(0, honest); // arbitrageurs restore the price during those eight minutes
        vm.prank(executor);
        try conv.convert(0, 0.5 ether, 1, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.SpotDeviatesFromMedian.selector);
        }
    }
}
