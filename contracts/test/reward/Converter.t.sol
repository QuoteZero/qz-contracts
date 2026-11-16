// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ConverterFixture} from "./ConverterFixture.sol";
import {QZPriceMath} from "../../src/reward/QZPriceMath.sol";
import {QZConverter} from "../../src/reward/QZConverter.sol";
import {IQZConverter} from "../../src/interfaces/IQZConverter.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {StockRoute} from "../../src/lib/QZTypes.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";

/// @notice SPEC §3.2 / T15 / T10 / §2.5 `openEpoch` for `QZConverter` against a real v4 PoolManager (both token
///         orders) and a mocked v3 route.
contract ConverterTest is ConverterFixture {
    uint256 internal constant CAP = 0.05 ether;
    /// @dev ceil(CAP / 32): the smallest fallback conversion.
    uint256 internal constant MIN_CHUNK = 0.0015625 ether;

    // ───────────── routes ─────────────

    function test_setRouteOnlyOwnerAndOnlyBeforeSeal() public {
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotOwner.selector, attacker));
        vm.prank(attacker);
        conv.setRoute(0, _route(0));

        _setRoutesAndSeal();
        assertTrue(conv.routesSealed());
        vm.prank(owner);
        vm.expectRevert(IQZConverter.RoutesAlreadySealed.selector);
        conv.setRoute(0, _route(0));
        vm.prank(owner);
        vm.expectRevert(IQZConverter.RoutesAlreadySealed.selector);
        conv.sealRoutes();
    }

    function test_sealNeedsAllTenRoutes() public {
        vm.startPrank(owner);
        for (uint8 t; t < 9; ++t) {
            conv.setRoute(t, _route(t));
        }
        vm.expectRevert(abi.encodeWithSelector(QZConverter.RouteNotSet.selector, uint8(9)));
        conv.sealRoutes();
        vm.stopPrank();
    }

    function test_setRouteRejectsBadRoute() public {
        StockRoute memory r = _route(0);
        r.maxChunk = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(QZConverter.RouteInvalid.selector, uint8(0)));
        conv.setRoute(0, r);

        r = _route(0);
        r.stock = makeAddr("no code");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(QZConverter.RouteInvalid.selector, uint8(0)));
        conv.setRoute(0, r);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.BadTrack.selector, uint8(10)));
        conv.setRoute(10, _route(0));
    }

    function test_sealRejectsUninitialisedPool() public {
        vm.startPrank(owner);
        for (uint8 t; t < 10; ++t) {
            StockRoute memory r = _route(t);
            if (t == 4) r.poolFee = 500; // no such pool
            conv.setRoute(t, r);
        }
        vm.expectRevert(abi.encodeWithSelector(QZConverter.PoolNotInitialized.selector, uint8(4)));
        conv.sealRoutes();
        vm.stopPrank();
    }

    // ───────────── pause ─────────────

    function test_pauseStopsOpenEpochAndConvertNotPoke() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotPauser.selector, attacker));
        conv.pause();

        vm.prank(pauser);
        conv.pause();
        vm.prank(executor);
        vm.expectRevert(IQZErrors.EnforcedPause.selector);
        conv.openEpoch();

        vm.prank(keeper);
        conv.poke(0); // never paused

        vm.prank(pauser);
        conv.unpause();
        _open();
        vm.prank(pauser);
        conv.pause();
        vm.prank(executor);
        vm.expectRevert(IQZErrors.EnforcedPause.selector);
        conv.convert(0, 0.1 ether, 1, 1, block.timestamp + 1);
    }

    // ───────────── openEpoch (§2.5) ─────────────

    function test_openEpoch_revertsWithoutLitMachine() public {
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        vm.prank(executor);
        vm.expectRevert(IQZConverter.NoLitMachines.selector);
        conv.openEpoch();
        assertEq(hook.rewardPot(), 1 ether, "the pot stays where it is");
    }

    function test_openEpoch_firstOneWaits24hAfterLaunch() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 1;
        _lightTracks(tr);
        _setRoutesAndSeal();
        _fundPots(1 ether, 0);

        vm.warp(launchAt + 24 hours - 1);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TooEarly.selector, launchAt + 24 hours));
        conv.openEpoch();

        vm.warp(launchAt + 24 hours);
        _open();
        assertEq(conv.trackPot(1), 1 ether);

        // later epochs: 60 s apart
        _fundPots(1 ether, 0);
        vm.warp(block.timestamp + 59);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TooEarly.selector, uint64(block.timestamp) + 1));
        conv.openEpoch();
        vm.warp(block.timestamp + 1);
        _open();
        assertEq(conv.trackPot(1), 2 ether);
    }

    function test_openEpoch_neverBeforeLaunchIsKnown() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 1;
        _lightTracks(tr);
        _setRoutesAndSeal();
        curve.setLaunchAt(0);
        _fundPots(1 ether, 0);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TooEarly.selector, type(uint64).max));
        conv.openEpoch();
    }

    function test_openEpoch_splitsOnlyOverTracksWithStandardWeight() public {
        uint8[] memory tr = new uint8[](2);
        tr[0] = 2;
        tr[1] = 5;
        _lightTracks(tr);
        // a lit relic does not make an empty track active
        machine.set(4441, alice, 0, 0, true);
        vault.onHardwire(4441);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours);
        _fundPots(3 ether, 1 ether);
        circuit.setRedirected(false);
        circuit.fundCircuit(5 ether); // not redirected: must stay in the circuit

        vm.expectEmit(false, false, false, true, address(conv));
        emit IQZConverter.PotsPulled(3 ether, 1 ether, 0);
        vm.expectEmit(false, false, false, true, address(conv));
        emit IQZConverter.EpochOpened(4 ether, uint16((1 << 2) | (1 << 5)));
        _open();

        for (uint8 t; t < 10; ++t) {
            uint256 expected = (t == 2 || t == 5) ? 2 ether : 0;
            assertEq(conv.trackPot(t), expected, "track share");
        }
        assertEq(conv.totalTrackPot(), 4 ether);
        assertEq(circuit.circuitPot(), 5 ether);
    }

    function test_openEpoch_circuitRedirectIsPulledIn() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 3;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours);
        circuit.setRedirected(true);
        circuit.fundCircuit(2 ether);
        _fundPots(1 ether, 0);

        vm.expectEmit(false, false, false, true, address(conv));
        emit IQZConverter.PotsPulled(1 ether, 0, 2 ether);
        _open();
        assertEq(conv.trackPot(3), 3 ether);
    }

    function test_openEpoch_divisionRemainderRollsIntoNextEpoch() public {
        uint8[] memory tr = new uint8[](2);
        tr[0] = 0;
        tr[1] = 1;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours);
        _fundPots(7, 0);
        _open();
        assertEq(conv.trackPot(0), 3);
        assertEq(conv.trackPot(1), 3);
        assertEq(weth.balanceOf(address(conv)), 7);

        _fundPots(1, 0);
        vm.warp(block.timestamp + 60);
        _open();
        assertEq(conv.trackPot(0), 4, "remainder carried: (1 + 1) / 2 added");
        assertEq(conv.trackPot(1), 4);
    }

    /// U4.3 (Reviewer A L-2): with nothing to allocate the executor's call is a heartbeat, not a revert (it used to be
    /// `ZeroAmount`); the dust stays unassigned and nothing is booked.
    function test_openEpoch_nothingToDistributeIsAnExecutorHeartbeat() public {
        uint8[] memory tr = new uint8[](2);
        tr[0] = 0;
        tr[1] = 1;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours);
        _fundPots(1, 0); // 1 wei over 2 tracks: share 0
        vm.prank(executor);
        conv.openEpoch();
        assertEq(conv.totalTrackPot(), 0);
        assertEq(conv.lastOpenEpoch(), 0, "no epoch was opened");
    }

    function test_openEpoch_nonExecutorRevertsInNormalMode() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        assertFalse(conv.fallbackMode());
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotExecutor.selector, attacker));
        conv.openEpoch();
    }

    // ───────────── poke ─────────────

    function test_poke_nonKeeperRevertsInNormalMode() public {
        _setRoutesAndSeal();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotKeeper.selector, attacker));
        conv.poke(0);

        vm.expectEmit(true, false, false, true, address(conv));
        emit IQZConverter.PricePoked(0, _spot(0), true);
        _poke(0);
    }

    function test_poke_needsSealedRoutesAndValidTrack() public {
        vm.prank(keeper);
        vm.expectRevert(IQZConverter.RoutesNotSealed.selector);
        conv.poke(0);
        _setRoutesAndSeal();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.BadTrack.selector, uint8(10)));
        conv.poke(10);
    }

    // ───────────── convert: happy path, both token orders ─────────────

    function _runConvert(uint8 t) internal {
        uint8[] memory tr = new uint8[](1);
        tr[0] = t;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        _open();
        assertEq(conv.trackPot(t), 1 ether);

        uint256 wethIn = 0.5 ether;
        uint160 spotBefore = _spot(t);
        vm.recordLogs();
        _convert(t, wethIn);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 usdgOut;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(conv)
                    && logs[i].topics[0] == keccak256("Converted(uint8,uint256,uint256,uint256)")
            ) {
                (, usdgOut,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }

        assertEq(conv.trackPot(t), 0.5 ether);
        assertEq(conv.totalTrackPot(), 0.5 ether);
        uint256 got = vault.totalNotified(t);
        assertGt(got, 0);
        assertEq(stocks[t].balanceOf(address(vault)), got, "stock sits in the vault");
        assertEq(stocks[t].balanceOf(address(conv)), 0, "nothing left in the converter");
        assertEq(usdg.balanceOf(address(conv)), 0);
        assertEq(weth.balanceOf(address(conv)), 0.5 ether);
        // A v4 swap pays at most the pre-swap spot quote for the exact USDG spent: the 0.3% LP fee and the price impact
        // only subtract, so `got < fair` is exact. Impact of ~$1000 into ~$280k of depth is ~0.4%, so 0.3% + 0.4% < 1.5%.
        uint256 fair = QZPriceMath.quote(usdgOut, QZPriceMath.priceX128(spotBefore), _usdgIs0(t));
        assertGt(got, fair * 985 / 1000, "within 1.5% of the fair quote");
        assertLt(got, fair, "never better than the pre-swap spot");

        // the machine owner can claim it
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tracks = new uint8[](1);
        ids[0] = 100 + t;
        tracks[0] = t;
        assertEq(vault.claimable(100 + t, t), got);
        vm.prank(alice);
        vault.claim(ids, tracks);
        assertEq(stocks[t].balanceOf(alice), got);
    }

    /// usdg sorts below the stock for odd tracks (currency0) and above for even tracks (currency1, see fixture).
    function test_convert_usdgIsCurrency0() public {
        assertTrue(_usdgIs0(1));
        _runConvert(1);
    }

    function test_convert_usdgIsCurrency1() public {
        assertFalse(_usdgIs0(0));
        _runConvert(0);
    }

    function test_convert_eventAndAccounting() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        _open();
        vm.recordLogs();
        _convert(0, 0.25 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Converted(uint8,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(conv) && logs[i].topics[0] == sig) {
                found = true;
                (uint256 wethIn, uint256 usdgOut, uint256 stockOut) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(wethIn, 0.25 ether);
                assertGt(usdgOut, 0);
                assertEq(stockOut, vault.totalNotified(0));
            }
        }
        assertTrue(found, "Converted emitted");
    }

    function test_convert_guards() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        _open();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotExecutor.selector, attacker));
        conv.convert(0, 0.1 ether, 1, 1, block.timestamp + 1);

        vm.startPrank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IQZErrors.DeadlineExpired.selector, block.timestamp - 1, block.timestamp)
        );
        conv.convert(0, 0.1 ether, 1, 1, block.timestamp - 1);
        vm.expectRevert(IQZErrors.ZeroAmount.selector);
        conv.convert(0, 0, 1, 1, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.ChunkTooLarge.selector, 0.6 ether, 0.5 ether));
        conv.convert(0, 0.6 ether, 1, 1, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.BadTrack.selector, uint8(10)));
        conv.convert(10, 0.1 ether, 1, 1, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TrackNotActive.selector, uint8(3)));
        conv.convert(3, 0.1 ether, 1, 1, block.timestamp + 1); // no pot on track 3
        vm.stopPrank();
    }

    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(abi.encodeWithSelector(QZConverter.NotPoolManager.selector, attacker));
        vm.prank(attacker);
        conv.unlockCallback("");
    }

    // ───────────── leg 1: floor 97% of the v3 TWAP, minOut cannot lower it ─────────────

    function _readyTrack0() internal {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        _open();
    }

    function test_leg1_minUsdgOutOfOneStillUsesTwapFloor() public {
        _readyTrack0();
        v3.setSkewPips(50_000); // router pays 5% below the TWAP: below the 97% floor
        vm.prank(executor);
        vm.expectRevert(bytes("Too little received"));
        conv.convert(0, 0.5 ether, 1, 1, block.timestamp + 1);

        v3.setSkewPips(20_000); // 2% below TWAP: inside the 3% tolerance
        _convert(0, 0.5 ether);
        assertGt(vault.totalNotified(0), 0);
    }

    function test_leg1_callerMinOutCanRaiseTheFloor() public {
        _readyTrack0();
        v3.setSkewPips(10_000); // 1% below TWAP: passes the floor...
        uint256 twapOut = 0.5 ether * 2060e6 / 1e18;
        vm.prank(executor);
        vm.expectRevert(bytes("Too little received")); // ...but not a caller floor at 99.9% of TWAP
        conv.convert(0, 0.5 ether, twapOut * 999 / 1000, 1, block.timestamp + 1);
    }

    // ───────────── leg 2: floor 97% of the median ─────────────

    function test_leg2_minStockOutOfOneStillUsesMedianFloor() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 1;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours - 20 minutes);
        // the keeper's observations see a pool that pays 2.9% MORE stock per USDG than the pool pays now
        uint160 honest = _spot(1);
        _shiftStockPerUsdg(1, 288);
        _pokeKeeper(1, 10);
        _setSpot(1, honest);
        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();

        // spot sits inside the 3% band around the median, but fee (0.3%) + impact leave the swap below 97% x median
        vm.prank(executor);
        try conv.convert(1, 0.5 ether, 1, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.BelowFloor.selector);
        }
    }

    function test_leg2_smallMedianGapPasses() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours - 20 minutes);
        uint160 honest = _spot(0);
        _shiftStockPerUsdg(0, 100);
        _pokeKeeper(0, 10);
        _setSpot(0, honest);
        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();
        _convert(0, 0.5 ether);
        assertGt(vault.totalNotified(0), 0);
    }

    function test_leg2_callerMinStockOutRaisesTheFloor() public {
        _readyTrack0();
        uint256 usdgIn = 0.25 ether * 2060e6 / 1e18;
        uint256 tooMuch = _fairStock(0, usdgIn) * 2;
        vm.prank(executor);
        vm.expectRevert(); // asks for more than the pool can pay
        conv.convert(0, 0.25 ether, 1, tooMuch, block.timestamp + 1);
    }

    // ───────────── spot deviation ─────────────

    function test_spotDeviatingMoreThan3PercentReverts() public {
        _readyTrack0();
        uint160 honest = _spot(0);
        _shiftStockPerUsdg(0, 400);
        vm.prank(executor);
        try conv.convert(0, 0.1 ether, 1, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.SpotDeviatesFromMedian.selector);
        }
        _setSpot(0, honest);
        _convert(0, 0.1 ether);
    }

    function test_spotDeviationBelowMinusThreePercentReverts() public {
        _readyTrack0();
        _shiftStockPerUsdg(0, -400);
        vm.prank(executor);
        try conv.convert(0, 0.1 ether, 1, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.SpotDeviatesFromMedian.selector);
        }
    }

    function test_notEnoughObservationsReverts() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 8); // one short of the 9 the median needs
        _fundPots(1 ether, 0);
        _open();
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotEnoughObservations.selector, uint8(0), 8, 9));
        conv.convert(0, 0.1 ether, 1, 1, block.timestamp + 1);
    }

    function test_observationsOlderThan30MinutesDoNotCount() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        _open();
        vm.warp(block.timestamp + 40 minutes);
        (, uint256 n) = conv.medianPrice(0);
        assertEq(n, 0);
        // the keeper has to stay alive: it is not silent for 24 h here, so no fallback
        assertFalse(conv.fallbackMode());
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotEnoughObservations.selector, uint8(0), 0, 9));
        conv.convert(0, 0.1 ether, 1, 1, block.timestamp + 1);
    }

    // ───────────── median robustness against a manipulated minority ─────────────

    /// 10 observations, 4 of them recorded at a +40% pool: the median is the honest price, conversion works.
    function test_median_minorityManipulationDoesNotMoveIt() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours - 20 minutes);
        uint160 honest = _spot(0);
        for (uint256 i; i < 10; ++i) {
            bool bad = i % 5 == 1 || i % 5 == 3; // 4 of 10
            if (bad) _shiftStockPerUsdg(0, 4000);
            _poke(0);
            if (bad) _setSpot(0, honest);
            vm.warp(block.timestamp + 100);
        }
        (uint160 med, uint256 n) = conv.medianPrice(0);
        assertEq(n, 10);
        assertEq(med, honest, "median untouched by the 4 manipulated observations");

        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();
        _convert(0, 0.5 ether);
        assertGt(vault.totalNotified(0), 0);
    }

    /// A majority of manipulated observations moves the median, but the spot-deviation guard still stops the swap.
    function test_median_majorityManipulatedStillStoppedBySpotGuard() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours - 20 minutes);
        uint160 honest = _spot(0);
        for (uint256 i; i < 10; ++i) {
            bool bad = i < 6;
            if (bad) _shiftStockPerUsdg(0, 4000);
            _poke(0);
            if (bad) _setSpot(0, honest);
            vm.warp(block.timestamp + 100);
        }
        (uint160 med,) = conv.medianPrice(0);
        assertTrue(med != honest, "majority moves the median");
        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();
        vm.prank(executor);
        try conv.convert(0, 0.5 ether, 1, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.SpotDeviatesFromMedian.selector);
        }
    }

    function test_median_evenCountAveragesMiddlePair() public {
        _setRoutesAndSeal();
        vm.warp(launchAt + 1 hours);
        uint160 p0 = _spot(0);
        _poke(0);
        _setSpot(0, p0 + 100);
        vm.warp(block.timestamp + 10);
        _poke(0);
        (uint160 med, uint256 n) = conv.medianPrice(0);
        assertEq(n, 2);
        assertEq(med, p0 + 50);
        _setSpot(0, p0);
    }

    // ───────────── fallback mode (keeper or executor silent for > 24 h) ─────────────

    function _enterFallback() internal {
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours + 1 days + 1);
        assertTrue(conv.fallbackMode());
    }

    function test_fallback_isOffBeforeLaunchAndOnAfterDaySilence() public {
        assertFalse(conv.fallbackMode(), "launch time known but in the future");
        curve.setLaunchAt(0);
        vm.warp(T0 + 100 days);
        assertFalse(conv.fallbackMode(), "not started");
        curve.setLaunchAt(launchAt);
        assertTrue(conv.fallbackMode());
    }

    function test_fallback_pokeIsPermissionlessWithFiveMinuteSpacing() public {
        _enterFallback();
        vm.expectEmit(false, false, false, false, address(conv));
        emit IQZConverter.FallbackEntered();
        vm.prank(attacker);
        conv.poke(0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TooEarly.selector, uint64(block.timestamp) + 5 minutes));
        conv.poke(0);

        vm.warp(block.timestamp + 5 minutes);
        vm.prank(attacker);
        conv.poke(0);
    }

    function _fallbackObservations(uint8 t, bool manipulated) internal {
        for (uint256 i; i < 25; ++i) {
            if (manipulated) _shiftStockPerUsdg(t, -3000); // attacker makes stock 30% pricier
            vm.prank(attacker);
            conv.poke(t);
            vm.warp(block.timestamp + 5 minutes);
            if (manipulated) _setSpot(t, _honestSpot[t]);
        }
    }

    uint160[10] internal _honestSpot;

    function test_fallback_needs25SpacedObservations() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _fundPots(1 ether, 0);
        _open(); // permissionless in fallback, executor or not
        for (uint256 i; i < 24; ++i) {
            vm.prank(attacker);
            conv.poke(0);
            vm.warp(block.timestamp + 5 minutes);
        }
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotEnoughObservations.selector, uint8(0), 24, 25));
        conv.convert(0, 0.01 ether, 1, 1, block.timestamp + 1);

        vm.prank(attacker);
        conv.poke(0);
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(attacker);
        conv.convert(0, 0.01 ether, 1, 1, block.timestamp + 1);
        assertGt(vault.totalNotified(0), 0);
    }

    /// Even if the attacker owns every observation and holds the pool at a 30% worse price during the swap, the damage
    /// per day and track is bounded by `fallbackDailyCap`; repeated days repeat only that bound.
    function test_fallback_attackerOwningEveryObservationIsBoundedByDailyCap() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _honestSpot[0] = _spot(0);
        _fundPots(10 ether, 0);
        _open();

        uint256 totalConverted;
        for (uint256 day; day < 3; ++day) {
            _fallbackObservations(0, true);
            _shiftStockPerUsdg(0, -3000); // the attacker holds the manipulated price for the swap
            uint256 spentBefore = totalConverted;
            vm.startPrank(attacker);
            // all in one call at the cap
            conv.convert(0, CAP, 1, 1, block.timestamp + 1);
            totalConverted += CAP;
            assertEq(conv.fallbackSpentToday(0), CAP);
            // nothing more fits today, however the attacker slices it
            vm.expectRevert(abi.encodeWithSelector(IQZConverter.DailyCapExceeded.selector, uint8(0), 1, 0));
            conv.convert(0, 1, 1, 1, block.timestamp + 1);
            vm.stopPrank();
            _setSpot(0, _honestSpot[0]);
            assertEq(totalConverted - spentBefore, CAP);
            // a day passes (observations stay attacker-owned)
            vm.warp(block.timestamp + 1 days);
        }
        assertEq(totalConverted, 3 * CAP, "3 days cost 3 caps, no more");
        assertEq(conv.trackPot(0), 10 ether - 3 * CAP);
    }

    function test_fallback_cappedConvertSplitAcrossCalls() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _fundPots(1 ether, 0);
        _open();
        for (uint256 i; i < 25; ++i) {
            vm.prank(attacker);
            conv.poke(0);
            vm.warp(block.timestamp + 5 minutes);
        }
        vm.startPrank(attacker);
        conv.convert(0, 0.03 ether, 1, 1, block.timestamp + 1);
        conv.convert(0, 0.02 ether, 1, 1, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.DailyCapExceeded.selector, uint8(0), 0.001 ether, 0));
        conv.convert(0, 0.001 ether, 1, 1, block.timestamp + 1);
        vm.stopPrank();
    }

    /// The keeper coming back ends fallback mode; observations of fallback authors no longer count.
    function test_fallback_keeperReturnRestoresNormalMode() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _honestSpot[0] = _spot(0);
        _fundPots(1 ether, 0);
        // the executor acts now: only the keeper side stays silent
        _open();
        _fallbackObservations(0, true);
        assertTrue(conv.fallbackMode());

        _pokeKeeper(0, 1);
        assertFalse(conv.fallbackMode(), "both roles alive again");

        // normal mode: attacker poke reverts, and the median ignores the attacker's earlier observations
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.NotKeeper.selector, attacker));
        conv.poke(0);
        (uint160 med, uint256 n) = conv.medianPrice(0);
        assertEq(n, 1, "only the keeper observation");
        assertEq(med, _honestSpot[0]);
    }

    function test_fallback_executorSilenceAloneAlsoOpensConvertToEveryone() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _setRoutesAndSeal();
        // keeper alive, executor silent
        vm.warp(launchAt + 24 hours - 1 hours);
        _pokeKeeper(0, 1);
        vm.warp(launchAt + 24 hours + 12 hours);
        _pokeKeeper(0, 1);
        assertFalse(conv.fallbackMode());
        vm.warp(launchAt + 24 hours + 24 hours + 1);
        _pokeKeeper(0, 1);
        assertTrue(conv.fallbackMode(), "executor silent for 24 h after the first allowed open");
    }

    // ───────────── pots and conservation ─────────────

    function test_wethAccountingNeverStrandsOrOverspends() public {
        uint8[] memory tr = new uint8[](2);
        tr[0] = 0;
        tr[1] = 1;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(2 ether, 1 ether);
        _open();
        assertEq(weth.balanceOf(address(conv)), conv.totalTrackPot());
        _convert(0, 0.5 ether);
        _convert(1, 0.4 ether);
        assertEq(weth.balanceOf(address(conv)), conv.totalTrackPot());
        assertEq(conv.trackPot(0), 1 ether);
        assertEq(conv.trackPot(1), 1.1 ether);
        // a pot smaller than the chunk limit caps the call
        vm.startPrank(executor);
        conv.convert(1, 0.5 ether, 1, 1, block.timestamp + 1);
        conv.convert(1, 0.5 ether, 1, 1, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.TrackNotActive.selector, uint8(1)));
        conv.convert(1, 0.5 ether, 1, 1, block.timestamp + 1);
        conv.convert(1, 0.1 ether, 1, 1, block.timestamp + 1);
        vm.stopPrank();
        assertEq(conv.trackPot(1), 0);
    }

    // ───────────── regressions from the C5 check (gross floors, rolling cap, no marginal limit) ─────────────

    function _args(bytes memory err) internal pure returns (bytes memory r) {
        r = new bytes(err.length - 4);
        for (uint256 i; i < r.length; ++i) {
            r[i] = err[i + 4];
        }
    }

    /// The 3% budget is gross: the 0.3% pool fee eats part of it. Median 2.5% above spot: the gross floor (97% x median)
    /// is above what the swap pays, although it would pass a floor taken net of the fee (floor x 0.997).
    function test_leg2_floorIsGrossOfPoolFee() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 1;
        _lightTracks(tr);
        _setRoutesAndSeal();
        vm.warp(launchAt + 24 hours - 20 minutes);
        uint160 honest = _spot(1);
        _shiftStockPerUsdg(1, 248);
        _pokeKeeper(1, 10);
        _setSpot(1, honest);
        vm.warp(launchAt + 24 hours + 1);
        _fundPots(1 ether, 0);
        _open();
        vm.prank(executor);
        try conv.convert(1, 0.5 ether, 1, 1, block.timestamp + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), IQZConverter.BelowFloor.selector);
            (uint256 out, uint256 floor_) = abi.decode(_args(err), (uint256, uint256));
            assertLt(out, floor_, "below the gross floor");
            assertGe(out * 1000, floor_ * 997, "but above a floor net of the 0.3% fee");
        }
    }

    function test_leg1_floorBoundaryIsThreePercentOfTwap() public {
        _readyTrack0();
        v3.setSkewPips(31_000);
        vm.prank(executor);
        vm.expectRevert(bytes("Too little received"));
        conv.convert(0, 0.5 ether, 1, 1, block.timestamp + 1);
        v3.setSkewPips(29_000);
        _convert(0, 0.5 ether);
        assertGt(vault.totalNotified(0), 0);
    }

    function _fbPokes(uint8 t) internal {
        for (uint256 i; i < 25; ++i) {
            vm.prank(attacker);
            conv.poke(t);
            vm.warp(block.timestamp + 5 minutes);
        }
    }

    /// Checker repro: 0.049 WETH, then 0.05 WETH seconds after a fixed 24 h window would have reset. Every rolling
    /// 24 h window must stay within the cap.
    function test_fallback_capHoldsOverEveryRollingWindow() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _fundPots(1 ether, 0);
        _open();
        _fbPokes(0);
        uint256 t1 = block.timestamp;
        vm.prank(attacker);
        conv.convert(0, CAP - MIN_CHUNK, 1, 1, block.timestamp + 1);

        vm.warp(t1 + 21 hours);
        _fbPokes(0);
        vm.warp(t1 + 24 hours - 3);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.DailyCapExceeded.selector, uint8(0), CAP, MIN_CHUNK));
        conv.convert(0, CAP, 1, 1, block.timestamp + 1);
        vm.prank(attacker);
        conv.convert(0, MIN_CHUNK, 1, 1, block.timestamp + 1);
        assertEq(conv.fallbackSpentToday(0), CAP);

        // the first entry leaves the window exactly 24 h after it was made
        vm.warp(t1 + 24 hours);
        assertEq(conv.fallbackSpentToday(0), MIN_CHUNK);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.DailyCapExceeded.selector, uint8(0), CAP, CAP - MIN_CHUNK));
        conv.convert(0, CAP, 1, 1, block.timestamp + 1);
        vm.prank(attacker);
        conv.convert(0, CAP - MIN_CHUNK, 1, 1, block.timestamp + 1);
    }

    /// U4.3: the minimum chunk (`cap / 32`) makes the ring fill only when the cap is spent, so the daily-cap check
    /// fires first and `CapRingFull` stays a guard. 32 minimum chunks spend exactly the cap.
    function test_fallback_32MinimumChunksSpendExactlyTheCap() public {
        uint8[] memory tr = new uint8[](1);
        tr[0] = 0;
        _lightTracks(tr);
        _enterFallback();
        _fundPots(1 ether, 0);
        _open();
        _fbPokes(0);
        vm.startPrank(attacker);
        for (uint256 i; i < 32; ++i) {
            conv.convert(0, MIN_CHUNK, 1, 1, block.timestamp + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(IQZConverter.DailyCapExceeded.selector, uint8(0), MIN_CHUNK, 0));
        conv.convert(0, MIN_CHUNK, 1, 1, block.timestamp + 1);
        vm.stopPrank();
        assertEq(conv.fallbackSpentToday(0), CAP);
    }

    /// A swap whose average price clears the 97% floor can end at a marginal price well below it. With 2.4% average
    /// impact (thin pool) the average is fine (0.997 x 0.976 > 0.97) while the final marginal price is ~5% down.
    function test_convert_floorCompliantSwapIsNotRejectedByMarginalPrice() public {
        pm.initialize(_key(1), _spot(1), 3e15);
        uint8[] memory tr = new uint8[](1);
        tr[0] = 1;
        _lightTracks(tr);
        _readyForConvert(tr, 10);
        _fundPots(1 ether, 0);
        _open();
        uint256 fair = _fairStock(1, 0.5 ether * 2060e6 / 1e18);
        _convert(1, 0.5 ether);
        assertGt(vault.totalNotified(1), fair * 96 / 100);
    }
}
