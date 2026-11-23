// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {QZCloseBell} from "../../src/dapps/QZCloseBell.sol";
import {IQZCloseBell, Direction, CallState, CloseStatus, Result, Profile, SessionTimes} from "../../src/interfaces/IQZCloseBell.sol";
import {PriceStatus} from "../../src/interfaces/IQZPriceSource.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {FeeToken} from "../light/mocks/LightMocks.sol";
import {BellFixture, ScriptedSource, ReentrantQZ} from "./BellFixture.sol";

contract QZCloseBellTest is BellFixture {
    // ───────────── constructor ─────────────

    function test_constructorStoresConfig() public view {
        assertEq(bell.machine(), address(machine));
        assertEq(bell.forge(), address(forge));
        assertEq(bell.qz(), address(qz));
        assertEq(bell.usdg(), address(usdg));
        assertEq(bell.source(), address(src));
        assertEq(bell.calendar(), calendar);
        assertEq(bell.treasury(), treasury);
        assertEq(bell.sponsor(), sponsor);
        assertEq(bell.voidAfter(), VOID_AFTER);
        assertEq(bell.claimDelay(), CLAIM_DELAY);
        assertEq(bell.minLead(), MIN_LEAD);
        assertEq(bell.snapshotDelay(), SNAP_DELAY);
        assertEq(bell.DEAD(), DEAD);
    }

    function test_constructorRejectsZeroAddresses() public {
        Profile memory p = _profile();
        address m = address(machine);
        address f = address(forge);
        address q = address(qz);
        address u = address(usdg);
        address s = address(src);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZCloseBell(address(0), f, q, u, s, calendar, treasury, sponsor, p);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZCloseBell(m, address(0), q, u, s, calendar, treasury, sponsor, p);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZCloseBell(m, f, address(0), u, s, calendar, treasury, sponsor, p);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZCloseBell(m, f, q, address(0), s, calendar, treasury, sponsor, p);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZCloseBell(m, f, q, u, address(0), calendar, treasury, sponsor, p);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZCloseBell(m, f, q, u, s, address(0), treasury, sponsor, p);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZCloseBell(m, f, q, u, s, calendar, address(0), sponsor, p);
    }

    function test_constructorAllowsNoSponsor() public {
        QZCloseBell b = new QZCloseBell(
            address(machine), address(forge), address(qz), address(usdg), address(src), calendar, treasury, address(0), _profile()
        );
        assertEq(b.sponsor(), address(0));
        // the zero address can never fund: no caller is address(0)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotFunder.selector, alice));
        b.fundPurse(1, 1);
    }

    function test_constructorRejectsBadProfile() public {
        address[7] memory a =
            [address(machine), address(forge), address(qz), address(usdg), address(src), calendar, treasury];
        Profile[4] memory bad = [
            Profile(0, 0, 0, 1), // voidAfter 0
            Profile(1 hours, 30 minutes, 0, 1), // claimDelay < voidAfter
            Profile(1 hours, 1 hours, 0, 0), // snapshotDelay 0
            Profile(1 hours, 1 hours, 0, 1 hours) // snapshotDelay >= voidAfter
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IQZCloseBell.BadProfile.selector);
            new QZCloseBell(a[0], a[1], a[2], a[3], a[4], a[5], a[6], sponsor, bad[i]);
        }
    }

    // ───────────── createSeason ─────────────

    function test_createSeasonRecordsCalendar() public view {
        (uint32 first, uint32 last, uint64 baseline, uint128 ante, uint64 claimOpensAt, bool exists) = bell.seasons(S1);
        assertEq(first, 1);
        assertEq(last, N);
        assertEq(baseline, BASE - 1 hours);
        assertEq(ante, ANTE);
        assertEq(claimOpensAt, closeOf_(N) + CLAIM_DELAY);
        assertTrue(exists);
        (uint64 o, uint64 c, uint64 cl, uint16 season) = bell.sessionTimes(2);
        assertEq(o, opensOf(2));
        assertEq(c, cutoffOf(2));
        assertEq(cl, closeOf_(2));
        assertEq(season, S1);
        assertEq(bell.seasonCount(), 1);
        assertEq(bell.sessionCount(), N);
    }

    function test_createSeasonEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IQZCloseBell.SeasonCreated(2, N + 1, N + 2, 5e18);
        _createSeason(2, N + 1, closeOf_(N), 5e18, closeOf_(N) + 1 hours, 2);
    }

    function test_createSeasonSecondSeasonContiguous() public {
        _createSeason(2, N + 1, closeOf_(N), 5e18, closeOf_(N) + 10 minutes, 3);
        assertEq(bell.seasonCount(), 2);
        assertEq(bell.sessionCount(), N + 3);
        (,,, uint16 s) = bell.sessionTimes(N + 1);
        assertEq(s, 2);
    }

    function test_createSeasonOnlyCalendar() public {
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotCalendar.selector, alice));
        vm.prank(alice);
        bell.createSeason(2, N + 1, closeOf_(N), 1, _times(closeOf_(N) + 1 hours, 1));
    }

    function test_createSeasonDuplicate() public {
        SessionTimes[] memory t = _times(closeOf_(N) + 1 hours, 1);
        vm.prank(calendar);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.SeasonExists.selector, S1));
        bell.createSeason(S1, N + 1, closeOf_(N), 1, t);
    }

    function test_createSeasonBadNumbers() public {
        SessionTimes[] memory t = _times(closeOf_(N) + 1 hours, 1);
        vm.startPrank(calendar);
        vm.expectRevert(IQZCloseBell.BadSeason.selector); // gap in season ids
        bell.createSeason(3, N + 1, closeOf_(N), 1, t);
        vm.expectRevert(IQZCloseBell.BadSeason.selector); // gap in session ids
        bell.createSeason(2, N + 2, closeOf_(N), 1, t);
        vm.expectRevert(IQZCloseBell.BadSeason.selector); // overlap in session ids
        bell.createSeason(2, N, closeOf_(N), 1, t);
        vm.stopPrank();
    }

    function test_createSeasonBadTimes() public {
        uint64 s0 = closeOf_(N) + 1 hours;
        vm.startPrank(calendar);
        SessionTimes[] memory e = new SessionTimes[](0);
        vm.expectRevert(IQZCloseBell.BadTimes.selector);
        bell.createSeason(2, N + 1, closeOf_(N), 1, e);
        vm.expectRevert(IQZCloseBell.BadTimes.selector); // zero ante
        bell.createSeason(2, N + 1, closeOf_(N), 0, _times(s0, 1));
        vm.expectRevert(IQZCloseBell.BadTimes.selector); // too many sessions
        bell.createSeason(2, N + 1, closeOf_(N), 1, _times(s0, 367));
        vm.expectRevert(IQZCloseBell.BadTimes.selector); // baseline before the last close
        bell.createSeason(2, N + 1, closeOf_(N) - 1, 1, _times(s0, 1));

        SessionTimes[] memory t = _times(s0, 2);
        t[0].cutoff = t[0].opensAt; // opens >= cutoff
        vm.expectRevert(IQZCloseBell.BadTimes.selector);
        bell.createSeason(2, N + 1, closeOf_(N), 1, t);
        t = _times(s0, 2);
        t[0].closeTs = t[0].cutoff; // cutoff >= close
        vm.expectRevert(IQZCloseBell.BadTimes.selector);
        bell.createSeason(2, N + 1, closeOf_(N), 1, t);
        t = _times(s0, 2);
        t[1].opensAt = t[0].closeTs - 1; // overlaps the previous session
        vm.expectRevert(IQZCloseBell.BadTimes.selector);
        bell.createSeason(2, N + 1, closeOf_(N), 1, t);
        t = _times(s0, 1);
        vm.expectRevert(IQZCloseBell.BadTimes.selector); // first session opens before the baseline close
        bell.createSeason(2, N + 1, s0 + 1, 1, t);
        vm.stopPrank();
        QZCloseBell fresh = _newBell(address(qz), address(usdg));
        vm.prank(calendar);
        // zero baseline (first season of a fresh Bell)
        vm.expectRevert(IQZCloseBell.BadTimes.selector);
        fresh.createSeason(1, 1, 0, 1, _times(s0, 1));
    }

    function test_createSeasonBackToBackSessionsAllowed() public {
        SessionTimes[] memory t = new SessionTimes[](2);
        uint64 s0 = closeOf_(N) + 1 hours;
        t[0] = SessionTimes(s0, s0 + 10, s0 + 20);
        t[1] = SessionTimes(s0 + 20, s0 + 30, s0 + 40); // opens exactly at the previous close
        vm.prank(calendar);
        bell.createSeason(2, N + 1, closeOf_(N), 1, t);
    }

    function test_createSeasonTooSoon() public {
        QZCloseBell fresh = _newBell(address(qz), address(usdg));
        uint64 early = uint64(block.timestamp) + MIN_LEAD - 1;
        SessionTimes[] memory t = _times(early, 1);
        vm.prank(calendar);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.TooSoon.selector, early, early + 1));
        fresh.createSeason(1, 1, BASE - 1 hours, 1, t);
        // exactly minLead ahead is fine
        t = _times(uint64(block.timestamp) + MIN_LEAD, 1);
        vm.prank(calendar);
        fresh.createSeason(1, 1, BASE - 1 hours, 1, t);
    }

    // ───────────── call ─────────────

    function test_callPullsAnteAndRecords() public {
        _toWindow(1);
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.Called(A, 1, NVDA, Direction.Up, alice);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        assertEq(qz.balanceOf(address(bell)), ANTE);
        assertEq(qz.balanceOf(alice), 1_000_000e18 - ANTE);
        assertEq(bell.openAntes(), ANTE);
        assertEq(bell.totalAnteIn(), ANTE);
        (address payer, uint8 track, Direction dir, CallState st) = bell.callOf(A, 1);
        assertEq(payer, alice);
        assertEq(track, NVDA);
        assertEq(uint8(dir), uint8(Direction.Up));
        assertEq(uint8(st), uint8(CallState.Open));
    }

    function test_callWindowBoundaries() public {
        vm.warp(opensOf(1) - 1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.WindowClosed.selector, opensOf(1), cutoffOf(1)));
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.warp(cutoffOf(1));
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.WindowClosed.selector, opensOf(1), cutoffOf(1)));
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.warp(closeOf_(1));
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.WindowClosed.selector, opensOf(1), cutoffOf(1)));
        _callAs(alice, A, 1, NVDA, Direction.Up);
        // first and last second of the window are open
        vm.warp(opensOf(1));
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.warp(cutoffOf(2) - 1);
        _callAs(alice, A, 2, NVDA, Direction.Down);
    }

    function test_callRejects() public {
        _toWindow(1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NoSession.selector, 99));
        _callAs(alice, A, 99, NVDA, Direction.Up);
        vm.expectRevert(IQZCloseBell.BadDirection.selector);
        _callAs(alice, A, 1, NVDA, Direction.None);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.BadTrack.selector, 10));
        _callAs(alice, A, 1, 10, Direction.Up);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotOwner.selector, bob));
        _callAs(bob, A, 1, NVDA, Direction.Up); // not the owner
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotLit.selector, C));
        _callAs(carol, C, 1, NVDA, Direction.Up); // not lit
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.WrongTrack.selector, NVDA, TSLA));
        _callAs(alice, A, 1, TSLA, Direction.Up); // standard machine, other ticker
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotCallable.selector, 6));
        _callAs(dave, NF, 1, 6, Direction.Up); // NFLX has no feed
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotCallable.selector, 6));
        _callAs(rel, R, 1, 6, Direction.Up); // a relic neither
        vm.expectRevert(); // nonexistent machine
        _callAs(alice, 777, 1, NVDA, Direction.Up);
    }

    function test_callOnce() public {
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.AlreadyCalled.selector, A, 1));
        _callAs(alice, A, 1, NVDA, Direction.Down);
    }

    function test_relicCallsAnyCallableTrack() public {
        _toWindow(1);
        _callAs(rel, R, 1, GME, Direction.Up);
        (, uint8 track,,) = bell.callOf(R, 1);
        assertEq(track, GME);
        _toWindow(2);
        _callAs(rel, R, 2, NVDA, Direction.Down); // another track next session
    }

    function test_callNeedsAllowanceAndBalance() public {
        _toWindow(1);
        vm.prank(alice);
        qz.approve(address(bell), 0);
        vm.expectRevert();
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.prank(alice);
        qz.approve(address(bell), type(uint256).max);
        uint256 all = qz.balanceOf(alice);
        vm.prank(alice);
        qz.transfer(carol, all);
        vm.expectRevert();
        _callAs(alice, A, 1, NVDA, Direction.Up);
        // a failed pull leaves nothing recorded
        assertEq(bell.openAntes(), 0);
        assertEq(uint8(_state(A, 1)), uint8(CallState.None));
    }

    function test_callFeeOnTransferTokenReverts() public {
        FeeToken fee = new FeeToken(100); // 1% fee
        QZCloseBell b = _newBell(address(fee), address(usdg));
        vm.prank(calendar);
        b.createSeason(1, 1, BASE - 1 hours, ANTE, _times(BASE + 5 minutes, 1));
        fee.mint(alice, 10_000e18);
        vm.prank(alice);
        fee.approve(address(b), type(uint256).max);
        _toWindow(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.TransferMismatch.selector, ANTE, ANTE - ANTE / 100));
        b.call(A, 1, NVDA, Direction.Up);
    }

    function test_callTransferFalseTokenReverts() public {
        _toWindow(1);
        vm.mockCall(address(qz), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(false));
        vm.expectRevert();
        _callAs(alice, A, 1, NVDA, Direction.Up);
    }

    // ───────────── snapshotBaseline ─────────────

    function test_baseline() public {
        _toSnap(1);
        src.setAnswer(NVDA, BASE - 1 hours, 100e8, PriceStatus.Ok);
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.BaselineSet(S1, NVDA, 100e8);
        bell.snapshotBaseline(S1, NVDA, 0);
        assertEq(bell.baselineOf(S1, NVDA), 100e8);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.BaselineAlreadySet.selector, S1, NVDA));
        bell.snapshotBaseline(S1, NVDA, 0);
    }

    function test_baselineRejects() public {
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NoSeason.selector, 9));
        bell.snapshotBaseline(9, NVDA, 0);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.BadTrack.selector, 10));
        bell.snapshotBaseline(S1, 10, 0);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotCallable.selector, 6));
        bell.snapshotBaseline(S1, 6, 0);
        // before baselineCloseTs + snapshotDelay
        vm.warp(BASE - 1 hours + SNAP_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.TooEarly.selector, BASE - 1 hours + SNAP_DELAY));
        bell.snapshotBaseline(S1, NVDA, 0);
        vm.warp(BASE);
        // market closed on the baseline day: the calendar must pick a trading close
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        bell.snapshotBaseline(S1, NVDA, 0);
        src.setAnswer(NVDA, BASE - 1 hours, 0, PriceStatus.Paused);
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        bell.snapshotBaseline(S1, NVDA, 0);
        src.setMode(ScriptedSource.Mode.Revert);
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        bell.snapshotBaseline(S1, NVDA, 0);
    }

    // ───────────── snapshot ─────────────

    function test_snapshotUpDownFlat() public {
        _baseline(NVDA, 100e8);
        _post(NVDA, 1, 110e8);
        _post(NVDA, 2, 99e8);
        _post(NVDA, 3, 99e8);
        _toSnap(1);
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.Snapshotted(NVDA, 1, 110e8, 1000, CloseStatus.Up);
        _snap(NVDA, 1);
        (uint128 p, int32 mv, uint32 prevOk, CloseStatus s) = bell.closeOf(NVDA, 1);
        assertEq(p, 110e8);
        assertEq(mv, 1000);
        assertEq(prevOk, 0);
        assertEq(uint8(s), uint8(CloseStatus.Up));
        _toSnap(2);
        _snap(NVDA, 2);
        (p, mv, prevOk, s) = bell.closeOf(NVDA, 2);
        assertEq(mv, -1000); // (99 - 110) / 110 = -10%
        assertEq(prevOk, 1);
        assertEq(uint8(s), uint8(CloseStatus.Down));
        _toSnap(3);
        _snap(NVDA, 3);
        (p, mv, prevOk, s) = bell.closeOf(NVDA, 3);
        assertEq(uint8(s), uint8(CloseStatus.Flat)); // equal close: void
        assertEq(p, 0);
        assertEq(bell.lastSnapshotted(NVDA), 3);
    }

    function test_snapshotMoveBpsSubBpsStillDirectional() public {
        _baseline(NVDA, 1_000_000e8);
        _post(NVDA, 1, 1_000_000e8 + 1); // 0.0000001%: below 1 bp
        _toSnap(1);
        _snap(NVDA, 1);
        (, int32 mv,, CloseStatus s) = bell.closeOf(NVDA, 1);
        assertEq(mv, 0);
        assertEq(uint8(s), uint8(CloseStatus.Up));
    }

    function test_snapshotMoveBpsClampsAtInt32() public {
        _baseline(NVDA, 1);
        _post(NVDA, 1, type(uint128).max);
        _toSnap(1);
        _snap(NVDA, 1);
        (, int32 mv,,) = bell.closeOf(NVDA, 1);
        assertEq(mv, type(int32).max);
        _post(NVDA, 2, 1);
        _toSnap(2);
        _snap(NVDA, 2);
        (, mv,,) = bell.closeOf(NVDA, 2);
        assertEq(mv, -9999);
    }

    function test_snapshotRejects() public {
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NoSession.selector, 99));
        bell.snapshot(NVDA, 99, 0);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.BadTrack.selector, 10));
        bell.snapshot(10, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.OutOfOrder.selector, 1, 2));
        bell.snapshot(NVDA, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotCallable.selector, 6));
        bell.snapshot(6, 1, 0);
        vm.warp(closeOf_(1) + SNAP_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.TooEarly.selector, closeOf_(1) + SNAP_DELAY));
        bell.snapshot(NVDA, 1, 0);
        _toSnap(1);
        _post(NVDA, 1, 5);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.BaselineMissing.selector, S1, NVDA));
        bell.snapshot(NVDA, 1, 0);
    }

    function test_snapshotIsInOrderPerTrackAndOnce() public {
        _baseline(NVDA, 100e8);
        _baseline(TSLA, 100e8);
        _post(NVDA, 1, 101e8);
        _post(NVDA, 2, 102e8);
        _post(TSLA, 2, 103e8);
        _toSnap(2);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.OutOfOrder.selector, 1, 2));
        bell.snapshot(TSLA, 2, 0); // tracks are independent but each is strictly ordered
        _snap(NVDA, 1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.OutOfOrder.selector, 2, 1));
        bell.snapshot(NVDA, 1, 0); // never twice
        _snap(NVDA, 2);
    }

    function test_snapshotMarketClosedAndNoSource() public {
        _baseline(NVDA, 100e8);
        _toSnap(1);
        // no answer scripted: MarketClosed
        _snap(NVDA, 1);
        assertEq(uint8(_status(NVDA, 1)), uint8(CloseStatus.Closed));
        _toSnap(2);
        src.setAnswer(NVDA, closeOf_(2), 0, PriceStatus.NoSource);
        _snap(NVDA, 2);
        assertEq(uint8(_status(NVDA, 2)), uint8(CloseStatus.Closed));
    }

    function test_snapshotPausedRevertsUntilExpiry() public {
        _baseline(NVDA, 100e8);
        _toSnap(1);
        src.setAnswer(NVDA, closeOf_(1), 0, PriceStatus.Paused);
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        bell.snapshot(NVDA, 1, 0);
        vm.warp(closeOf_(1) + VOID_AFTER - 1);
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        bell.snapshot(NVDA, 1, 0);
        vm.warp(closeOf_(1) + VOID_AFTER);
        bell.snapshot(NVDA, 1, 0); // does not read the source any more
        assertEq(uint8(_status(NVDA, 1)), uint8(CloseStatus.Expired));
    }

    function test_snapshotHostileSourceModes() public {
        _baseline(NVDA, 100e8);
        _post(NVDA, 1, 101e8);
        _toSnap(1);
        ScriptedSource.Mode[7] memory modes = [
            ScriptedSource.Mode.Revert,
            ScriptedSource.Mode.Garbage,
            ScriptedSource.Mode.Bomb,
            ScriptedSource.Mode.BigReturn,
            ScriptedSource.Mode.BadStatus,
            ScriptedSource.Mode.FutureObs,
            ScriptedSource.Mode.HugePrice
        ];
        for (uint256 i; i < modes.length; ++i) {
            src.setMode(modes[i]);
            vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
            bell.snapshot(NVDA, 1, 0);
        }
        src.setMode(ScriptedSource.Mode.OkZero);
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        bell.snapshot(NVDA, 1, 0);
        src.setMode(ScriptedSource.Mode.Normal);
        _snap(NVDA, 1); // the honest source still works afterwards
        assertEq(uint8(_status(NVDA, 1)), uint8(CloseStatus.Up));
    }

    function test_snapshotSecondSeasonUsesBaselineThenChain() public {
        // season 1: NVDA moves up in session 1 only
        _baseline(NVDA, 100e8);
        _post(NVDA, 1, 110e8);
        _toSnap(1);
        _snap(NVDA, 1);
        for (uint32 k = 2; k <= N; ++k) {
            _toSnap(k);
            _snap(NVDA, k); // MarketClosed
        }
        // season 2: baseline 112, first session closes at 113
        uint64 start = closeOf_(N) + 1 hours;
        _createSeason(2, N + 1, closeOf_(N), 7e18, start, 2);
        uint64 close5 = start + 6 minutes;
        uint64 close6 = start + 8 minutes + 6 minutes;
        src.setAnswer(NVDA, closeOf_(N), 112e8, PriceStatus.Ok);
        vm.warp(close5 + SNAP_DELAY);
        bell.snapshotBaseline(2, NVDA, 0);
        src.setAnswer(NVDA, close5, 113e8, PriceStatus.Ok);
        bell.snapshot(NVDA, N + 1, 0);
        (uint128 p,, uint32 prevOk, CloseStatus s) = bell.closeOf(NVDA, N + 1);
        assertEq(p, 113e8);
        assertEq(prevOk, 1); // the last Ok close of the track, from season 1
        assertEq(uint8(s), uint8(CloseStatus.Up)); // measured from the season 2 baseline (112), not from 110
        src.setAnswer(NVDA, close6, 112e8, PriceStatus.Ok);
        vm.warp(close6 + SNAP_DELAY);
        bell.snapshot(NVDA, N + 2, 0);
        (,,, s) = bell.closeOf(NVDA, N + 2);
        assertEq(uint8(s), uint8(CloseStatus.Down)); // chained from 113
    }

    function test_snapshotFlatFirstSessionKeepsBaselineReference() public {
        _baseline(NVDA, 100e8);
        _post(NVDA, 1, 100e8); // flat against the baseline
        _post(NVDA, 2, 99e8);
        _toSnap(1);
        _snap(NVDA, 1);
        assertEq(uint8(_status(NVDA, 1)), uint8(CloseStatus.Flat));
        _toSnap(2);
        _snap(NVDA, 2);
        (,, uint32 prevOk, CloseStatus s) = bell.closeOf(NVDA, 2);
        assertEq(uint8(s), uint8(CloseStatus.Down));
        assertEq(prevOk, 0);
    }

    function test_isCallableFollowsSource() public view {
        assertTrue(bell.isCallable(NVDA));
        assertFalse(bell.isCallable(6));
        assertFalse(bell.isCallable(7));
        assertFalse(bell.isCallable(10));
    }

    // ───────────── settle ─────────────

    /// @dev Snapshots every season 1 session of `track` (all void: nothing scripted, or expired) so season 2 can start.
    function _snapshotSeason1(uint8 track) internal {
        vm.warp(closeOf_(N) + SNAP_DELAY);
        for (uint32 k = 1; k <= N; ++k) {
            bell.snapshot(track, k, 0);
        }
    }

    function _winSession(uint32 k, uint128 price) internal {
        _post(NVDA, k, price);
        _toSnap(k);
        _snap(NVDA, k);
    }

    function test_settleWinBurnsAndScores() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _winSession(1, 101e8);
        uint256 deadBefore = qz.balanceOf(DEAD);
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.Settled(A, 1, Result.Win, 1, 1);
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.AnteBurned(A, 1, ANTE);
        vm.prank(keeper);
        bell.settle(A, 1);
        assertEq(qz.balanceOf(DEAD) - deadBefore, ANTE);
        assertEq(bell.totalBurned(), ANTE);
        assertEq(bell.openAntes(), 0);
        assertEq(qz.balanceOf(address(bell)), 0);
        assertEq(bell.seasonPoints(S1, A), 1);
        assertEq(bell.seasonTotalPoints(S1), 1);
        assertEq(bell.teamPoints(S1, NVDA), 1);
        (uint32 st, uint32 best, uint32 w, uint32 l) = _heat(A);
        assertEq(st, 1);
        assertEq(best, 1);
        assertEq(w, 1);
        assertEq(l, 0);
        assertEq(uint8(_state(A, 1)), uint8(CallState.Settled));
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.AlreadySettled.selector, A, 1));
        bell.settle(A, 1);
    }

    function test_settleLossBurnsAndResetsStreak() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _toWindow(2);
        _callAs(alice, A, 2, NVDA, Direction.Up);
        _winSession(1, 101e8);
        bell.settle(A, 1);
        _winSession(2, 99e8);
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.Settled(A, 2, Result.Loss, 0, 0);
        bell.settle(A, 2);
        (uint32 st, uint32 best, uint32 w, uint32 l) = _heat(A);
        assertEq(st, 0);
        assertEq(best, 1);
        assertEq(w, 1);
        assertEq(l, 1);
        assertEq(bell.totalBurned(), 2 * ANTE); // a loss burns too
        assertEq(bell.seasonPoints(S1, A), 1);
    }

    function test_settleDownWins() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Down);
        _winSession(1, 90e8);
        bell.settle(A, 1);
        (uint32 st,, uint32 w,) = _heat(A);
        assertEq(st, 1);
        assertEq(w, 1);
    }

    function test_settleRejects() public {
        _baseline(NVDA, 100e8);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NoCall.selector, A, 1));
        bell.settle(A, 1);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotSettleable.selector, A, 1));
        bell.settle(A, 1); // no snapshot yet
    }

    function test_settleOrderPerMachine() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _toWindow(2);
        _callAs(alice, A, 2, NVDA, Direction.Up);
        _winSession(1, 101e8);
        _winSession(2, 102e8);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.PrevUnsettled.selector, A, 2, 1));
        bell.settle(A, 2);
        bell.settle(A, 1);
        bell.settle(A, 2);
        (uint32 st,,,) = _heat(A);
        assertEq(st, 2);
    }

    function test_streakPointsRampAndCap() public {
        // 8 sessions in season 2, a win every session: points 1,2,3,4,5,6,7,7
        uint64 start = closeOf_(N) + 1 hours;
        _createSeason(2, N + 1, closeOf_(N), ANTE, start, 8);
        _snapshotSeason1(NVDA);
        src.setAnswer(NVDA, closeOf_(N), 100e8, PriceStatus.Ok);
        vm.warp(start);
        bell.snapshotBaseline(2, NVDA, 0);
        uint32[8] memory expected = [uint32(1), 3, 6, 10, 15, 21, 28, 35];
        for (uint32 i; i < 8; ++i) {
            uint32 k = N + 1 + i;
            uint64 o = start + 8 minutes * i;
            vm.warp(o + 1);
            _callAs(alice, A, k, NVDA, Direction.Up);
            src.setAnswer(NVDA, o + 6 minutes, uint128(101e8 + i), PriceStatus.Ok);
            vm.warp(o + 6 minutes + SNAP_DELAY);
            bell.snapshot(NVDA, k, 0);
            bell.settle(A, k);
            assertEq(bell.seasonPoints(2, A), expected[i]);
        }
        (uint32 st, uint32 best, uint32 w,) = _heat(A);
        assertEq(st, 8);
        assertEq(best, 8);
        assertEq(w, 8);
    }

    function test_voidSessionDoesNotBreakStreak() public {
        // win, void (market closed), win: the streak continues and the second win scores 2
        _baseline(NVDA, 100e8);
        for (uint32 k = 1; k <= 3; ++k) {
            _toWindow(k);
            _callAs(alice, A, k, NVDA, Direction.Up);
        }
        _winSession(1, 101e8);
        _toSnap(2);
        _snap(NVDA, 2); // MarketClosed
        _winSession(3, 102e8);
        bell.settle(A, 1);
        bell.settle(A, 2); // void: refund
        bell.settle(A, 3);
        (uint32 st,,,) = _heat(A);
        assertEq(st, 2);
        assertEq(bell.seasonPoints(S1, A), 1 + 2);
        assertEq(qz.balanceOf(DEAD), 2 * ANTE);
        assertEq(bell.totalRefunded(), ANTE);
    }

    function test_flatSessionIsInvisibleToStreak() public {
        _baseline(NVDA, 100e8);
        for (uint32 k = 1; k <= 3; ++k) {
            _toWindow(k);
            _callAs(alice, A, k, NVDA, Direction.Up);
        }
        _winSession(1, 101e8);
        _winSession(2, 101e8); // flat
        _winSession(3, 102e8);
        for (uint32 k = 1; k <= 3; ++k) {
            bell.settle(A, k);
        }
        (uint32 st,,,) = _heat(A);
        assertEq(st, 2);
    }

    function test_skippedSessionBreaksStreak() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _toWindow(3);
        _callAs(alice, A, 3, NVDA, Direction.Up); // did not call session 2, which was a real Up/Down session
        _winSession(1, 101e8);
        _winSession(2, 102e8);
        _winSession(3, 103e8);
        bell.settle(A, 1);
        bell.settle(A, 3);
        (uint32 st, uint32 best,,) = _heat(A);
        assertEq(st, 1);
        assertEq(best, 1);
        assertEq(bell.seasonPoints(S1, A), 2);
    }

    function test_lossThenWinRestartsAtOne() public {
        _baseline(NVDA, 100e8);
        for (uint32 k = 1; k <= 3; ++k) {
            _toWindow(k);
            _callAs(alice, A, k, NVDA, Direction.Up);
        }
        _winSession(1, 101e8);
        _winSession(2, 100e8); // loss for an Up call
        _winSession(3, 101e8); // win
        for (uint32 k = 1; k <= 3; ++k) {
            bell.settle(A, k);
        }
        (uint32 st, uint32 best, uint32 w, uint32 l) = _heat(A);
        assertEq(st, 1);
        assertEq(best, 1);
        assertEq(w, 2);
        assertEq(l, 1);
    }

    function test_closedFlatAndExpiredRefundThePayer() public {
        _baseline(NVDA, 100e8);
        for (uint32 k = 1; k <= 3; ++k) {
            _toWindow(k);
            _callAs(alice, A, k, NVDA, Direction.Up);
        }
        uint256 before_ = qz.balanceOf(alice);
        _toSnap(1);
        _snap(NVDA, 1); // closed
        _post(NVDA, 2, 100e8);
        _toSnap(2);
        _snap(NVDA, 2); // flat
        vm.warp(closeOf_(3) + VOID_AFTER);
        _snap(NVDA, 3); // expired
        assertEq(uint8(_status(NVDA, 3)), uint8(CloseStatus.Expired));
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.AnteRefunded(A, 1, alice, ANTE);
        bell.settle(A, 1);
        bell.settle(A, 2);
        bell.settle(A, 3);
        assertEq(qz.balanceOf(alice), before_ + 3 * ANTE);
        assertEq(bell.totalRefunded(), 3 * ANTE);
        assertEq(bell.totalBurned(), 0);
        (uint32 st,, uint32 w, uint32 l) = _heat(A);
        assertEq(st + w + l, 0); // a void changes no heat
        assertEq(uint8(_state(A, 3)), uint8(CallState.Refunded));
    }

    function test_refundAfterTransferGoesToPayerHeatFollowsNft() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _toWindow(2);
        _callAs(alice, A, 2, NVDA, Direction.Up);
        _toSnap(1);
        _snap(NVDA, 1); // closed: void
        _winSession(2, 101e8);
        vm.prank(alice);
        machine.transferFrom(alice, bob, A);
        uint256 aliceBefore = qz.balanceOf(alice);
        uint256 bobBefore = qz.balanceOf(bob);
        bell.settle(A, 1);
        assertEq(qz.balanceOf(alice) - aliceBefore, ANTE); // refund to the wallet that paid
        assertEq(qz.balanceOf(bob), bobBefore);
        bell.settle(A, 2);
        (uint32 st,,,) = _heat(A);
        assertEq(st, 1); // heat is keyed by the machine, so it moved with the NFT
        // the new owner can call next, the purse pays the new owner
        _toWindow(3);
        _callAs(bob, A, 3, NVDA, Direction.Down);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotOwner.selector, alice));
        _callAs(alice, A, 3, NVDA, Direction.Down);
    }

    function test_settleManySkipsAndCounts() public {
        _baseline(NVDA, 100e8);
        _baseline(TSLA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _callAs(bob, B, 1, TSLA, Direction.Down);
        _callAs(alice, A2, 1, NVDA, Direction.Down);
        _post(NVDA, 1, 101e8);
        _toSnap(1);
        _snap(NVDA, 1); // TSLA not snapshotted yet
        uint256[] memory ids = new uint256[](5);
        ids[0] = A;
        ids[1] = B; // not snapshotted: skipped
        ids[2] = A2;
        ids[3] = C; // no call: skipped
        ids[4] = A; // duplicate: second one already settled, skipped
        assertEq(bell.settleMany(ids, 1), 2);
        assertEq(uint8(_state(A, 1)), uint8(CallState.Settled));
        assertEq(uint8(_state(B, 1)), uint8(CallState.Open));
        assertEq(bell.seasonPoints(S1, A), 1);
        assertEq(bell.seasonPoints(S1, A2), 0);
    }

    function test_settleManySkipsPrevUnsettled() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _toWindow(2);
        _callAs(alice, A, 2, NVDA, Direction.Up);
        _winSession(1, 101e8);
        _winSession(2, 102e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = A;
        assertEq(bell.settleMany(ids, 2), 0);
        assertEq(bell.settleMany(ids, 1), 1);
        assertEq(bell.settleMany(ids, 2), 1);
    }

    // ───────────── voidExpired ─────────────

    function test_voidExpiredRefundsUnsnapshotted() public {
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.warp(closeOf_(1) + VOID_AFTER - 1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotVoidable.selector, A, 1));
        bell.voidExpired(A, 1);
        vm.warp(closeOf_(1) + VOID_AFTER);
        uint256 before_ = qz.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.AnteRefunded(A, 1, alice, ANTE);
        vm.prank(keeper);
        bell.voidExpired(A, 1);
        assertEq(qz.balanceOf(alice) - before_, ANTE);
        assertEq(uint8(_state(A, 1)), uint8(CallState.Refunded));
        assertEq(bell.totalRefunded(), ANTE);
        assertEq(bell.openAntes(), 0);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.AlreadySettled.selector, A, 1));
        bell.voidExpired(A, 1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.AlreadySettled.selector, A, 1));
        bell.settle(A, 1);
    }

    function test_voidExpiredNoCall() public {
        vm.warp(closeOf_(1) + VOID_AFTER);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NoCall.selector, A, 1));
        bell.voidExpired(A, 1);
    }

    function test_voidExpiredRevertsOnceAnySnapshotExists() public {
        _baseline(NVDA, 100e8);
        for (uint32 k = 1; k <= 3; ++k) {
            _toWindow(k);
            _callAs(alice, A, k, NVDA, Direction.Down); // would be losers if Up/Down
        }
        _winSession(1, 101e8); // Up
        _toSnap(2);
        _snap(NVDA, 2); // Closed
        _post(NVDA, 3, 90e8);
        _toSnap(3);
        _snap(NVDA, 3); // Down
        vm.warp(closeOf_(3) + VOID_AFTER + 365 days);
        for (uint32 k = 1; k <= 3; ++k) {
            vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotVoidable.selector, A, k));
            bell.voidExpired(A, k);
        }
        // a loser cannot dodge the burn: the only path is settle
        bell.settle(A, 1);
        bell.settle(A, 2);
        bell.settle(A, 3);
        assertEq(bell.totalBurned(), 2 * ANTE);
        assertEq(bell.totalRefunded(), ANTE);
    }

    function test_voidExpiredNotVoidableAfterExpiredSnapshot() public {
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.warp(closeOf_(1) + VOID_AFTER);
        _baselineLate();
        bell.snapshot(NVDA, 1, 0); // Expired
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotVoidable.selector, A, 1));
        bell.voidExpired(A, 1);
        bell.settle(A, 1); // the refund goes through settle
        assertEq(bell.totalRefunded(), ANTE);
    }

    function _baselineLate() internal {
        src.setAnswer(NVDA, BASE - 1 hours, 100e8, PriceStatus.Ok);
        bell.snapshotBaseline(S1, NVDA, 0);
    }

    function test_voidExpiredIgnoresHostileSource() public {
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        vm.warp(closeOf_(1) + VOID_AFTER);
        ScriptedSource.Mode[4] memory modes = [
            ScriptedSource.Mode.Bomb, ScriptedSource.Mode.Revert, ScriptedSource.Mode.Garbage, ScriptedSource.Mode.BigReturn
        ];
        src.setMode(modes[0]);
        uint256 g = gasleft();
        bell.snapshot(NVDA, 1, 0); // Expired: source not read even if it is a gas bomb
        assertLt(g - gasleft(), 200_000);
        src.setMode(modes[1]);
        bell.settle(A, 1);
        assertEq(bell.totalRefunded(), ANTE);
    }

    function test_voidExpiredWorksWhileSourceIsHostile() public {
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        src.setMode(ScriptedSource.Mode.Bomb);
        vm.warp(closeOf_(1) + VOID_AFTER);
        bell.voidExpired(A, 1);
        assertEq(bell.totalRefunded(), ANTE);
    }

    function test_hostileSourceCostsBoundedGas() public {
        _baseline(NVDA, 100e8);
        _toSnap(1);
        src.setMode(ScriptedSource.Mode.Bomb);
        uint256 g = gasleft();
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        bell.snapshot(NVDA, 1, 0);
        assertLt(g - gasleft(), 400_000);
    }

    // ───────────── season freeze and purse ─────────────

    function test_purseSplitByPoints() public {
        // alice (NVDA) wins sessions 1..3 for 1+2+3 = 6 points; bob (TSLA) wins session 1 for 1 point
        _baseline(NVDA, 100e8);
        _baseline(TSLA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _callAs(bob, B, 1, TSLA, Direction.Up);
        _toWindow(2);
        _callAs(alice, A, 2, NVDA, Direction.Up);
        _toWindow(3);
        _callAs(alice, A, 3, NVDA, Direction.Up);
        _post(NVDA, 1, 101e8);
        _post(NVDA, 2, 102e8);
        _post(NVDA, 3, 103e8);
        _post(TSLA, 1, 101e8);
        _toSnap(1);
        _snap(NVDA, 1);
        _snap(TSLA, 1);
        _toSnap(2);
        _snap(NVDA, 2);
        _toSnap(3);
        _snap(NVDA, 3);
        bell.settle(A, 1);
        bell.settle(B, 1);
        bell.settle(A, 2);
        bell.settle(A, 3);
        assertEq(bell.seasonPoints(S1, A), 1 + 2 + 3);
        assertEq(bell.seasonPoints(S1, B), 1);
        assertEq(bell.seasonTotalPoints(S1), 7);
        assertEq(bell.teamPoints(S1, NVDA), 6);
        assertEq(bell.teamPoints(S1, TSLA), 1);

        // fund from both allowed funders
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.PurseFunded(S1, treasury, 700e6);
        vm.prank(treasury);
        bell.fundPurse(S1, 700e6);
        vm.prank(sponsor);
        bell.fundPurse(S1, 3e6 + 1); // 703_000_001: not divisible by 7
        (uint128 funded, uint128 paid, bool swept) = bell.purseOf(S1);
        assertEq(funded, 703_000_001);
        assertEq(paid, 0);
        assertFalse(swept);

        uint64 opens = closeOf_(N) + CLAIM_DELAY;
        vm.warp(opens - 1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.TooEarly.selector, opens));
        bell.claimPurse(A, S1);
        vm.warp(opens);
        uint256 aBefore = usdg.balanceOf(alice);
        uint256 expectA = uint256(funded) * 6 / 7;
        uint256 expectB = uint256(funded) * 1 / 7;
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.PurseClaimed(A, S1, alice, expectA);
        bell.claimPurse(A, S1);
        assertEq(usdg.balanceOf(alice) - aBefore, expectA);
        assertTrue(bell.purseClaimed(S1, A));
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.AlreadyClaimed.selector, A, S1));
        bell.claimPurse(A, S1);
        // bob sells his machine before claiming: the owner at claim time is paid
        vm.prank(bob);
        machine.transferFrom(bob, dave, B);
        bell.claimPurse(B, S1);
        assertEq(usdg.balanceOf(dave), expectB);
        assertLe(expectA + expectB, funded);
        // machines without points get nothing
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NothingToClaim.selector, A2, S1));
        bell.claimPurse(A2, S1);
        (, paid,) = bell.purseOf(S1);
        assertEq(paid, expectA + expectB);
        assertEq(usdg.balanceOf(address(bell)), funded - paid);
    }

    function test_fundPurseOnlyFundersAndWindow() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotFunder.selector, alice));
        bell.fundPurse(S1, 1e6);
        vm.prank(calendar);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotFunder.selector, calendar));
        bell.fundPurse(S1, 1e6);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NoSeason.selector, 9));
        bell.fundPurse(9, 1e6);
        vm.prank(treasury);
        vm.expectRevert(IQZErrors.ZeroAmount.selector);
        bell.fundPurse(S1, 0);
        vm.warp(closeOf_(N) + CLAIM_DELAY);
        vm.prank(treasury);
        vm.expectRevert(IQZCloseBell.TooLate.selector);
        bell.fundPurse(S1, 1e6);
        // one second before the freeze it still works
        vm.warp(closeOf_(N) + CLAIM_DELAY - 1);
        vm.prank(treasury);
        bell.fundPurse(S1, 1e6);
    }

    function test_fundPurseFeeTokenAndHugeAmount() public {
        usdg.setFeeBps(100);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.TransferMismatch.selector, 100e6, 99e6));
        bell.fundPurse(S1, 100e6);
        usdg.setFeeBps(0);
        vm.prank(treasury);
        vm.expectRevert(); // does not fit uint128
        bell.fundPurse(S1, uint256(type(uint128).max) + 1);
    }

    function test_pointsFreezeAtClaimOpensAt() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _toWindow(2);
        _callAs(alice, A, 2, NVDA, Direction.Up);
        _post(NVDA, 1, 101e8);
        _post(NVDA, 2, 102e8);
        _toSnap(1);
        _snap(NVDA, 1);
        _toSnap(2);
        _snap(NVDA, 2);
        bell.settle(A, 1); // 1 point
        vm.warp(closeOf_(N) + CLAIM_DELAY); // frozen
        vm.expectEmit(true, true, false, true);
        emit IQZCloseBell.Settled(A, 2, Result.Win, 0, 2);
        bell.settle(A, 2); // heat and burn still happen, points do not
        assertEq(bell.seasonPoints(S1, A), 1);
        assertEq(bell.seasonTotalPoints(S1), 1);
        (uint32 st,,,) = _heat(A);
        assertEq(st, 2);
        assertEq(bell.totalBurned(), 2 * ANTE);
    }

    function test_claimWindowAndSweep() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _winSession(1, 101e8);
        bell.settle(A, 1);
        vm.prank(treasury);
        bell.fundPurse(S1, 100e6);
        uint64 opens = closeOf_(N) + CLAIM_DELAY;
        vm.warp(opens + 180 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.TooEarly.selector, opens + 180 days));
        bell.sweepPurse(S1);
        vm.warp(opens + 180 days);
        vm.expectRevert(IQZCloseBell.TooLate.selector);
        bell.claimPurse(A, S1);
        uint256 tBefore = usdg.balanceOf(treasury);
        vm.expectEmit(true, false, false, true);
        emit IQZCloseBell.PurseSwept(S1, 100e6);
        vm.prank(keeper);
        bell.sweepPurse(S1);
        assertEq(usdg.balanceOf(treasury) - tBefore, 100e6);
        (uint128 f, uint128 p, bool sw) = bell.purseOf(S1);
        assertEq(f, p);
        assertTrue(sw);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NothingToSweep.selector, S1));
        bell.sweepPurse(S1);
        assertEq(usdg.balanceOf(address(bell)), 0);
    }

    function test_sweepRejectsUnknownSeason() public {
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NoSeason.selector, 9));
        bell.sweepPurse(9);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NoSeason.selector, 9));
        bell.claimPurse(A, 9);
    }

    function test_sweepReturnsOnlyUnclaimedPart() public {
        _baseline(NVDA, 100e8);
        _baseline(TSLA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _callAs(bob, B, 1, TSLA, Direction.Up);
        _post(NVDA, 1, 101e8);
        _post(TSLA, 1, 101e8);
        _toSnap(1);
        _snap(NVDA, 1);
        _snap(TSLA, 1);
        bell.settle(A, 1);
        bell.settle(B, 1);
        vm.prank(sponsor);
        bell.fundPurse(S1, 101e6);
        vm.warp(closeOf_(N) + CLAIM_DELAY);
        bell.claimPurse(A, S1); // 50_500_000
        vm.warp(closeOf_(N) + CLAIM_DELAY + 180 days);
        uint256 before_ = usdg.balanceOf(treasury);
        bell.sweepPurse(S1);
        assertEq(usdg.balanceOf(treasury) - before_, 101e6 - 50_500_000);
    }

    function test_pursesOfDifferentSeasonsAreSeparate() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _winSession(1, 101e8);
        bell.settle(A, 1);
        uint64 start = closeOf_(N) + 1 hours;
        _createSeason(2, N + 1, closeOf_(N), ANTE, start, 1);
        vm.prank(treasury);
        bell.fundPurse(S1, 10e6);
        vm.prank(treasury);
        bell.fundPurse(2, 90e6);
        vm.warp(closeOf_(N) + CLAIM_DELAY);
        bell.claimPurse(A, S1);
        assertEq(usdg.balanceOf(alice), 10e6); // season 1 only
        (uint128 f2, uint128 p2,) = bell.purseOf(2);
        assertEq(f2, 90e6);
        assertEq(p2, 0);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.TooEarly.selector, start + 6 minutes + CLAIM_DELAY));
        bell.claimPurse(A, 2);
    }

    function test_claimWithNoFundingReverts() public {
        _baseline(NVDA, 100e8);
        _toWindow(1);
        _callAs(alice, A, 1, NVDA, Direction.Up);
        _winSession(1, 101e8);
        bell.settle(A, 1);
        vm.warp(closeOf_(N) + CLAIM_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NothingToClaim.selector, A, S1));
        bell.claimPurse(A, S1);
        // no points at all in the season: total 0
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NothingToClaim.selector, B, S1));
        bell.claimPurse(B, S1);
    }

    // ───────────── heat bands ─────────────

    function test_heatBand() public {
        uint64 start = closeOf_(N) + 1 hours;
        _createSeason(2, N + 1, closeOf_(N), ANTE, start, 8);
        _snapshotSeason1(NVDA);
        src.setAnswer(NVDA, closeOf_(N), 100e8, PriceStatus.Ok);
        vm.warp(start);
        bell.snapshotBaseline(2, NVDA, 0);
        uint8[8] memory bands = [1, 1, 2, 2, 2, 3, 3, 3];
        (,,,, uint8 band) = bell.heatOf(A);
        assertEq(band, 0);
        for (uint32 i; i < 8; ++i) {
            uint32 k = N + 1 + i;
            uint64 o = start + 8 minutes * i;
            vm.warp(o + 1);
            _callAs(alice, A, k, NVDA, Direction.Up);
            src.setAnswer(NVDA, o + 6 minutes, uint128(101e8 + i), PriceStatus.Ok);
            vm.warp(o + 6 minutes + SNAP_DELAY);
            bell.snapshot(NVDA, k, 0);
            bell.settle(A, k);
            (,,,, band) = bell.heatOf(A);
            assertEq(band, bands[i]);
        }
    }

    // ───────────── reentrancy ─────────────

    function test_reentrancyOnAntePullIsRejected() public {
        ReentrantQZ rq = new ReentrantQZ();
        QZCloseBell b = _newBell(address(rq), address(usdg));
        vm.prank(calendar);
        b.createSeason(1, 1, BASE - 1 hours, ANTE, _times(BASE + 5 minutes, 2));
        rq.mint(alice, 10_000e18);
        vm.prank(alice);
        rq.approve(address(b), type(uint256).max);
        _toWindow(1);
        rq.arm(b, abi.encodeCall(QZCloseBell.call, (A, 1, NVDA, Direction.Down)));
        vm.prank(alice);
        b.call(A, 1, NVDA, Direction.Up);
        assertEq(rq.lastRevert(), IQZCloseBell.Reentrancy.selector);
        assertFalse(rq.reentered());
        assertEq(b.openAntes(), ANTE);
    }

    function test_reentrancyOnBurnIsRejected() public {
        ReentrantQZ rq = new ReentrantQZ();
        QZCloseBell b = _newBell(address(rq), address(usdg));
        vm.prank(calendar);
        b.createSeason(1, 1, BASE - 1 hours, ANTE, _times(BASE + 5 minutes, 2));
        rq.mint(alice, 10_000e18);
        vm.prank(alice);
        rq.approve(address(b), type(uint256).max);
        src.setAnswer(NVDA, BASE - 1 hours, 100e8, PriceStatus.Ok);
        b.snapshotBaseline(1, NVDA, 0);
        _toWindow(1);
        vm.prank(alice);
        b.call(A, 1, NVDA, Direction.Up);
        _post(NVDA, 1, 101e8);
        _toSnap(1);
        b.snapshot(NVDA, 1, 0);
        rq.arm(b, abi.encodeCall(QZCloseBell.settle, (A, 1)));
        b.settle(A, 1);
        assertEq(rq.lastRevert(), IQZCloseBell.Reentrancy.selector);
        assertEq(b.totalBurned(), ANTE);
    }

    // ───────────── fuzz ─────────────

    /// @dev Any ante and any price pair: money is conserved, the direction follows the prices.
    function testFuzz_anteMoneyConservation(uint128 ante, uint128 base, uint128 close, bool up) public {
        ante = uint128(bound(ante, 1, 1e24));
        base = uint128(bound(base, 1, type(uint128).max));
        close = uint128(bound(close, 1, type(uint128).max));
        uint64 s0 = closeOf_(N) + 1 hours;
        _createSeason(2, N + 1, closeOf_(N), ante, s0, 1);
        _snapshotSeason1(NVDA);
        qz.mint(alice, ante);
        src.setAnswer(NVDA, closeOf_(N), base, PriceStatus.Ok);
        vm.warp(s0 + 1);
        bell.snapshotBaseline(2, NVDA, 0);
        uint256 supplyBefore = qz.totalSupply();
        uint256 aliceBefore = qz.balanceOf(alice);
        _callAs(alice, A, N + 1, NVDA, up ? Direction.Up : Direction.Down);
        src.setAnswer(NVDA, s0 + 6 minutes, close, PriceStatus.Ok);
        vm.warp(s0 + 6 minutes + SNAP_DELAY);
        bell.snapshot(NVDA, N + 1, 0);
        bell.settle(A, N + 1);
        CloseStatus cs = _status(NVDA, N + 1);
        if (close == base) {
            assertEq(uint8(cs), uint8(CloseStatus.Flat));
            assertEq(qz.balanceOf(alice), aliceBefore);
            assertEq(bell.totalBurned(), 0);
        } else {
            assertEq(uint8(cs), close > base ? uint8(CloseStatus.Up) : uint8(CloseStatus.Down));
            assertEq(qz.balanceOf(alice), aliceBefore - ante);
            assertEq(qz.balanceOf(DEAD), ante);
            assertEq(bell.totalBurned(), ante);
            (uint32 st,,,) = _heat(A);
            assertEq(st, (close > base) == up ? 1 : 0);
        }
        assertEq(qz.totalSupply(), supplyBefore); // nothing minted, nothing lost to a third party
        assertEq(qz.balanceOf(address(bell)), 0);
        assertEq(bell.openAntes(), 0);
        assertEq(bell.totalAnteIn(), bell.totalBurned() + bell.totalRefunded());
    }

    /// @dev A random win/loss/void string on one machine: streak, best, points follow a model.
    function testFuzz_streakModel(uint256 seed) public {
        uint32 n = 12;
        uint64 s0 = closeOf_(N) + 1 hours;
        _createSeason(2, N + 1, closeOf_(N), ANTE, s0, n);
        _snapshotSeason1(NVDA);
        src.setAnswer(NVDA, closeOf_(N), 1000e8, PriceStatus.Ok);
        vm.warp(s0);
        bell.snapshotBaseline(2, NVDA, 0);
        uint128 px = 1000e8;
        uint32 streak;
        uint32 best;
        uint256 points;
        bool lastWasOk; // previous session was a settled Up/Down for this machine
        for (uint32 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint64 o = s0 + 8 minutes * i;
            uint32 k = N + 1 + i;
            bool wantCall = r % 5 != 0;
            uint256 kind = (r >> 8) % 4; // 0 up, 1 down, 2 flat, 3 closed
            bool callUp = (r >> 16) % 2 == 0;
            vm.warp(o + 1);
            if (wantCall) _callAs(alice, A, k, NVDA, callUp ? Direction.Up : Direction.Down);
            vm.warp(o + 6 minutes + SNAP_DELAY);
            if (kind == 3) {
                bell.snapshot(NVDA, k, 0);
            } else {
                if (kind == 0) px += 1e8;
                else if (kind == 1) px -= 1e8;
                src.setAnswer(NVDA, o + 6 minutes, px, PriceStatus.Ok);
                bell.snapshot(NVDA, k, 0);
            }
            if (wantCall) bell.settle(A, k);
            bool decisive = kind <= 1;
            if (decisive && wantCall) {
                bool win = (kind == 0) == callUp;
                if (win) {
                    streak = (lastWasOk ? streak : 0) + 1;
                    if (streak > best) best = streak;
                    points += 1 + (streak - 1 > 6 ? 6 : streak - 1);
                } else {
                    streak = 0;
                }
                lastWasOk = true;
            } else if (decisive) {
                lastWasOk = false; // a real Up/Down session without a call breaks the chain
            }
        }
        (uint32 st, uint32 b,,) = _heat(A);
        assertEq(st, streak);
        assertEq(b, best);
        assertEq(bell.seasonPoints(2, A), points);
    }

    /// @dev Purse payouts: each equals funded * points / total rounded down; the sum never exceeds the purse.
    function testFuzz_purseProRata(uint256 seed, uint96 fund) public {
        uint256 funded = bound(fund, 1, 1e12);
        uint32 n = 3;
        _baseline(NVDA, 100e8);
        _baseline(TSLA, 100e8);
        uint256[3] memory ids = [A, A2, B];
        address[3] memory who = [alice, alice, bob];
        uint8[3] memory tr = [NVDA, NVDA, TSLA];
        for (uint32 k = 1; k <= n; ++k) {
            _toWindow(k);
            for (uint256 j; j < 3; ++j) {
                uint256 r = uint256(keccak256(abi.encode(seed, k, j)));
                if (r % 3 != 0) _callAs(who[j], ids[j], k, tr[j], r % 2 == 0 ? Direction.Up : Direction.Down);
            }
            _post(NVDA, k, uint128(100e8 + (uint256(keccak256(abi.encode(seed, k))) % 2 == 0 ? k : 0) + k * 2));
            _post(TSLA, k, uint128(100e8 + k));
            _toSnap(k);
            _snap(NVDA, k);
            _snap(TSLA, k);
            for (uint256 j; j < 3; ++j) {
                if (_state(ids[j], k) == CallState.Open) bell.settle(ids[j], k);
            }
        }
        vm.prank(treasury);
        bell.fundPurse(S1, funded);
        vm.warp(closeOf_(N) + CLAIM_DELAY);
        uint256 total = bell.seasonTotalPoints(S1);
        uint256 paid;
        for (uint256 j; j < 3; ++j) {
            uint256 pts = bell.seasonPoints(S1, ids[j]);
            uint256 expect = total == 0 ? 0 : funded * pts / total;
            if (expect == 0) {
                vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NothingToClaim.selector, ids[j], S1));
                bell.claimPurse(ids[j], S1);
            } else {
                uint256 b0 = usdg.balanceOf(machine.ownerOf(ids[j]));
                bell.claimPurse(ids[j], S1);
                assertEq(usdg.balanceOf(machine.ownerOf(ids[j])) - b0, expect);
                paid += expect;
            }
        }
        assertLe(paid, funded);
        (, uint128 pd,) = bell.purseOf(S1);
        assertEq(pd, paid);
    }
}
