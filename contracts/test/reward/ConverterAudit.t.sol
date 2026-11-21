// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ConverterFixture} from "./ConverterFixture.sol";
import {QZConverter} from "../../src/reward/QZConverter.sol";
import {QZRoutes} from "../../src/reward/QZRoutes.sol";
import {IQZConverter} from "../../src/interfaces/IQZConverter.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {StockRoute} from "../../src/lib/QZTypes.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";

/// @notice U4.3 regression tests for the two-model review of `QZConverter` (Reviewer A L-2, I-2, I-4; CheckC5 ring dust).
///         Each test reproduces the reviewers' scenario and fails on the code at `81f4027`.
contract ConverterAuditTest is ConverterFixture {
    uint256 internal constant CAP = QZConstants.DEFAULT_FALLBACK_DAILY_CAP;

    function _enterFallback() internal {
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1 days + 1);
        assertTrue(conv.fallbackMode());
    }

    function _fbPokes(uint8 t) internal {
        for (uint256 i; i < 25; ++i) {
            vm.prank(attacker);
            conv.poke(t);
            vm.warp(block.timestamp + 5 minutes);
        }
    }

    // ───────────── Reviewer A L-2: liveness must not depend on fees arriving ─────────────

    /// F4.1: an executor that only heartbeats `openEpoch` (and a keeper that keeps poking) cannot hold fallback off
    /// while a pot sits unconverted: after 24 h of no conversion the converter falls back.
    function test_F41_heartbeatingExecutorCannotBlockFallback() public {
        _lightTrack(0);
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();
        uint256 potBefore = _potWeth(0);

        // 23 h later the keeper and the executor are both "alive" by heartbeat
        vm.warp(block.timestamp + 23 hours);
        _poke(0);
        _open(); // nothing fresh: succeeds for the executor, changes nothing
        assertFalse(conv.fallbackMode());
        vm.warp(block.timestamp + 2 hours);
        _poke(0);
        _open();
        assertTrue(conv.fallbackMode(), "no conversion for more than 24 h opens the fallback");
        assertEq(_potWeth(0), potBefore, "a heartbeat allocates nothing");

        // anyone can now poke and, after 25 observations, convert (daily cap)
        for (uint256 i; i < 25; ++i) {
            vm.warp(block.timestamp + 5 minutes);
            vm.prank(attacker);
            conv.poke(0);
        }
        vm.prank(attacker);
        conv.convert(0, 0.05 ether, 1, 1, block.timestamp + 1);
    }

    /// Dust is not activity either: a conversion below `cap / 32` does not refresh the executor clock.
    function test_F41_dustConversionDoesNotRefreshTheExecutorClock() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        _open();
        vm.warp(block.timestamp + 23 hours);
        _pokeKeeper(0, 10);
        _convert(0, 1e12);
        vm.warp(block.timestamp + 2 hours);
        _poke(0);
        assertTrue(conv.fallbackMode(), "dust is not executor activity");
    }

    /// A live executor that converts keeps normal mode without any heartbeat.
    function test_L2_executorThatConvertsStaysOutOfFallback() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        _open();
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 23 hours);
            _pokeKeeper(0, 10);
            _convert(0, 0.1 ether);
            assertFalse(conv.fallbackMode(), "executor and keeper are alive");
        }
    }

    /// The heartbeat is the executor's alone: anyone else with nothing to distribute still reverts.
    function test_L2_zeroShareStillRevertsForNonExecutorInFallback() public {
        _lightTrack(0);
        _enterFallback();
        vm.prank(attacker);
        vm.expectRevert(IQZErrors.ZeroAmount.selector);
        conv.openEpoch();
    }

    /// An executor that really is silent still lets the converter fall back (SPEC §3.2 dead-keeper semantics).
    function test_L2_deadExecutorStillFallsBack() public {
        _lightTrack(0);
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();
        vm.warp(block.timestamp + 24 hours - 1);
        _poke(0);
        assertFalse(conv.fallbackMode());
        vm.warp(block.timestamp + 2);
        assertTrue(conv.fallbackMode(), "executor silent for more than 24 h");
    }

    // ───────────── CheckC5: fallback ring dust griefing ─────────────

    /// 32 dust conversions used to fill the 32-slot ring while spending almost none of the cap, blocking every
    /// honest conversion for the rest of the window. After the fix dust is refused and capacity stays usable.
    function test_ringDust_cannotBlockTheDailyCap() public {
        _lightTrack(0);
        _enterFallback();
        _fundPots(1 ether, 0);
        _open();
        _fbPokes(0);

        vm.startPrank(attacker);
        for (uint256 i; i < 32; ++i) {
            try conv.convert(0, 1e12, 1, 1, block.timestamp + 1) {} catch {}
        }
        conv.convert(0, 0.04 ether, 1, 1, block.timestamp + 1);
        vm.stopPrank();
        assertEq(conv.fallbackSpentToday(0) / 0.04 ether, 1, "the honest conversion went through");
    }

    /// The refusal is explicit and the boundary is exact: `ceil(cap / 32)` passes, one wei less does not.
    function test_ringDust_belowMinimumRevertsWithTheMinimum() public {
        _lightTrack(0);
        _enterFallback();
        _fundPots(1 ether, 0);
        _open();
        _fbPokes(0);
        uint256 min = (CAP + 31) / 32;

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.ChunkBelowFallbackMinimum.selector, min - 1, min));
        conv.convert(0, min - 1, 1, 1, block.timestamp + 1);
        conv.convert(0, min, 1, 1, block.timestamp + 1);
        vm.stopPrank();
        assertEq(conv.fallbackSpentToday(0), min);
    }

    // ───────────── Reviewer A I-2: setRoute before seal ─────────────

    function test_I2_setRouteRejectsHookedPoolAndOversizedLimits() public {
        StockRoute memory r = _route(0);
        r.hooks = makeAddr("hook");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(QZConverter.RouteInvalid.selector, uint8(0)));
        conv.setRoute(0, r);

        r = _route(0);
        r.maxChunk = uint128(QZConstants.DEFAULT_MAX_CHUNK) + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(QZConverter.RouteInvalid.selector, uint8(0)));
        conv.setRoute(0, r);

        r = _route(0);
        r.fallbackDailyCap = uint128(QZConstants.DEFAULT_FALLBACK_DAILY_CAP) + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(QZConverter.RouteInvalid.selector, uint8(0)));
        conv.setRoute(0, r);

        // the spec values themselves are accepted
        vm.prank(owner);
        conv.setRoute(0, _route(0));
    }

    /// The deploy table (`QZRoutes`) is inside the new bounds for every track.
    function test_I2_deployTableIsWithinTheBounds() public pure {
        for (uint8 t; t < 10; ++t) {
            StockRoute memory r = QZRoutes.route(t);
            assertEq(r.hooks, address(0));
            assertLe(r.maxChunk, QZConstants.DEFAULT_MAX_CHUNK);
            assertLe(r.fallbackDailyCap, QZConstants.DEFAULT_FALLBACK_DAILY_CAP);
            assertLe(r.fallbackDailyCap, uint256(r.maxChunk) * 32, "a fallback chunk of cap/32 must fit maxChunk");
        }
    }

    // ───────────── Reviewer A I-4: openEpoch with only relics lit ─────────────

    /// SPEC §2.5: `openEpoch` reverts only when no machine at all is lit. With relics only there is no standard track
    /// to fund, so the pots stay where they are and the executor's call succeeds, changing nothing.
    function test_I4_onlyRelicsLitDoesNotRevertNoLitMachines() public {
        machine.set(2221, alice, 0, 0, true);
        vault.register(2221);
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1);
        _fundPots(1 ether, 0);

        _open();
        assertEq(conv.totalTrackWeth(), 0, "no standard track to fund");
        (uint256 eth, uint256 w,) = conv.unassignedPot();
        assertEq(eth, 0, "the ETH was wrapped");
        assertEq(w, 1 ether, "the WETH waits unassigned");

        vm.warp(block.timestamp + 23 hours);
        _open();
        vm.warp(block.timestamp + 23 hours);
        _poke(0);
        assertTrue(conv.fallbackMode(), "an openEpoch heartbeat is not executor activity");

        // once a standard machine lights, the waiting pot is distributed
        _lightTrack(0);
        vm.warp(block.timestamp + 60);
        _open();
        assertEq(_potWeth(0), 1 ether);
    }

    function test_I4_noMachineAtAllStillReverts() public {
        _setRoutesAndSeal();
        vm.warp(lightingOpensAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        vm.prank(executor);
        vm.expectRevert(IQZConverter.NoLitMachines.selector);
        conv.openEpoch();
    }
}
