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
        vm.warp(launchAt + 24 hours + 1 days + 1);
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

    /// Three and a half days without a single fee: a live executor (heartbeat via `openEpoch`) and a live keeper
    /// keep the converter out of fallback, and nothing is allocated.
    function test_L2_aliveExecutorWithoutVolumeDoesNotEnterFallback() public {
        _lightTrack(0);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();
        uint256 potBefore = conv.trackPot(0);

        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 23 hours);
            _poke(0);
            _open(); // no new WETH: must not revert for the executor
            assertFalse(conv.fallbackMode(), "executor and keeper are alive");
        }
        assertEq(conv.trackPot(0), potBefore, "a heartbeat allocates nothing");
        assertEq(conv.totalTrackPot(), potBefore);
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
        vm.warp(launchAt + 24 hours + 1);
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
    /// to fund, so the pots stay where they are and the executor's call succeeds as a heartbeat.
    function test_I4_onlyRelicsLitDoesNotRevertNoLitMachines() public {
        machine.set(2221, alice, 0, 0, true);
        vault.onHardwire(2221);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);

        _open();
        assertEq(conv.totalTrackPot(), 0, "no standard track to fund");
        assertEq(hook.rewardPot(), 1 ether, "the pot waits in the hook");

        vm.warp(block.timestamp + 23 hours);
        _open();
        vm.warp(block.timestamp + 23 hours);
        _poke(0);
        assertFalse(conv.fallbackMode(), "the heartbeat kept the executor alive");

        // once a standard machine lights, the waiting pot is distributed
        _lightTrack(0);
        vm.warp(block.timestamp + 60);
        _open();
        assertEq(conv.trackPot(0), 1 ether);
    }

    function test_I4_noMachineAtAllStillReverts() public {
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        vm.prank(executor);
        vm.expectRevert(IQZConverter.NoLitMachines.selector);
        conv.openEpoch();
    }
}
