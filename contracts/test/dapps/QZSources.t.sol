// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZBoardSource} from "../../src/dapps/QZBoardSource.sol";
import {QZChainlinkSource} from "../../src/dapps/QZChainlinkSource.sol";
import {QZCloseBell} from "../../src/dapps/QZCloseBell.sol";
import {PriceStatus} from "../../src/interfaces/IQZPriceSource.sol";
import {IQZCloseBell, Direction, CallState, CloseStatus} from "../../src/interfaces/IQZCloseBell.sol";
import {BellFixture} from "./BellFixture.sol";

/// @dev A Chainlink feed proxy with explicit round ids, so phase jumps and bad rounds can be scripted.
contract MockFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        uint80 answeredIn;
        bool exists;
    }

    uint8 public decimals = 8;
    uint80 public latestId;
    bool public latestReverts;
    mapping(uint80 => Round) public rounds;

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setLatestReverts(bool v) external {
        latestReverts = v;
    }

    function push(uint80 id, int256 answer, uint256 updatedAt) external {
        rounds[id] = Round(answer, updatedAt, id, true);
        latestId = id;
    }

    function pushRaw(uint80 id, int256 answer, uint256 updatedAt, uint80 answeredIn) external {
        rounds[id] = Round(answer, updatedAt, answeredIn, true);
        latestId = id;
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[id];
        require(r.exists, "No data present");
        return (id, r.answer, r.updatedAt, r.updatedAt, r.answeredIn);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!latestReverts, "feed down");
        Round memory r = rounds[latestId];
        return (latestId, r.answer, r.updatedAt, r.updatedAt, r.answeredIn);
    }
}

contract QZBoardSourceTest is Test {
    QZBoardSource internal board;
    address internal owner = makeAddr("owner");
    address internal poster = makeAddr("poster");
    uint64 internal constant T = 1_900_000_000;
    uint64 internal constant MAX_AGE = 120;

    function setUp() public {
        vm.warp(T);
        board = new QZBoardSource(owner, poster, MAX_AGE, 0x3FF & ~uint16(1 << 6) & ~uint16(1 << 7));
    }

    function _post(uint8 track, uint64 ts, uint128 px) internal {
        vm.prank(poster);
        board.post(track, ts, px);
    }

    function test_constructor() public {
        assertEq(board.owner(), owner);
        assertEq(board.poster(), poster);
        assertEq(board.maxAge(), MAX_AGE);
        vm.expectRevert(QZBoardSource.ZeroAddress.selector);
        new QZBoardSource(address(0), poster, 1, 1);
        vm.expectRevert(QZBoardSource.ZeroAddress.selector);
        new QZBoardSource(owner, address(0), 1, 1);
        vm.expectRevert(QZBoardSource.BadMaxAge.selector);
        new QZBoardSource(owner, poster, 0, 1);
    }

    function test_supportedMask() public view {
        assertTrue(board.isSupported(0));
        assertTrue(board.isSupported(9));
        assertFalse(board.isSupported(6));
        assertFalse(board.isSupported(7));
        assertFalse(board.isSupported(10));
        assertFalse(board.isSupported(200));
    }

    function test_postRules() public {
        vm.expectRevert(abi.encodeWithSelector(QZBoardSource.NotPoster.selector, owner));
        vm.prank(owner);
        board.post(0, T, 1);
        vm.startPrank(poster);
        vm.expectRevert(abi.encodeWithSelector(QZBoardSource.Unsupported.selector, 6));
        board.post(6, T, 1);
        vm.expectRevert(QZBoardSource.BadEntry.selector); // zero price
        board.post(0, T, 0);
        vm.expectRevert(QZBoardSource.BadEntry.selector); // future
        board.post(0, T + 1, 1);
        board.post(0, T - 10, 5);
        vm.expectRevert(QZBoardSource.BadEntry.selector); // not strictly increasing
        board.post(0, T - 10, 6);
        vm.expectRevert(QZBoardSource.BadEntry.selector);
        board.post(0, T - 11, 6);
        vm.stopPrank();
        assertEq(board.lastTs(0), T - 10);
        assertEq(board.firstTs(0), T - 10);
    }

    function test_postEmits() public {
        vm.expectEmit(true, true, false, true);
        emit QZBoardSource.Posted(2, T - 1, 77);
        _post(2, T - 1, 77);
    }

    function test_setPoster() public {
        vm.expectRevert(abi.encodeWithSelector(QZBoardSource.NotOwner.selector, poster));
        vm.prank(poster);
        board.setPoster(owner);
        vm.startPrank(owner);
        vm.expectRevert(QZBoardSource.ZeroAddress.selector);
        board.setPoster(address(0));
        board.setPoster(owner);
        vm.stopPrank();
        assertEq(board.poster(), owner);
        vm.expectRevert(abi.encodeWithSelector(QZBoardSource.NotPoster.selector, poster));
        vm.prank(poster);
        board.post(0, T, 1);
    }

    function test_pausedAnswersPaused() public {
        _post(0, T - 5, 10);
        vm.expectRevert(abi.encodeWithSelector(QZBoardSource.NotPoster.selector, owner));
        vm.prank(owner);
        board.setPaused(0, true);
        vm.expectRevert(abi.encodeWithSelector(QZBoardSource.Unsupported.selector, 6));
        vm.prank(poster);
        board.setPaused(6, true);
        vm.prank(poster);
        board.setPaused(0, true);
        (, , PriceStatus s) = board.priceAt(0, T, T - 5);
        assertEq(uint8(s), uint8(PriceStatus.Paused));
        vm.prank(poster);
        board.setPaused(0, false);
        (uint256 p,, PriceStatus s2) = board.priceAt(0, T, T - 5);
        assertEq(uint8(s2), uint8(PriceStatus.Ok));
        assertEq(p, 10);
    }

    function test_priceAtHints() public {
        _post(0, T - 300, 10);
        _post(0, T - 100, 20);
        _post(0, T - 50, 30);
        // exact last entry before ts
        (uint256 p, uint64 at, PriceStatus s) = board.priceAt(0, T - 60, T - 100);
        assertEq(p, 20);
        assertEq(at, T - 100);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
        // a hint to an earlier entry while a later one exists at or before ts: rejected
        vm.expectRevert(QZBoardSource.BadHint.selector);
        board.priceAt(0, T - 60, T - 300);
        // a hint after ts
        vm.expectRevert(QZBoardSource.BadHint.selector);
        board.priceAt(0, T - 60, T - 50);
        // a hint that is not an entry
        vm.expectRevert(QZBoardSource.BadHint.selector);
        board.priceAt(0, T - 60, T - 99);
        // hint 0 while an entry exists at or before ts
        vm.expectRevert(QZBoardSource.BadHint.selector);
        board.priceAt(0, T - 60, 0);
        // ts exactly an entry time: that entry
        (p,, s) = board.priceAt(0, T - 50, T - 50);
        assertEq(p, 30);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
    }

    function test_priceAtNoEntryAndStale() public {
        // empty series: hint 0 is the only valid hint, status MarketClosed
        (uint256 p, uint64 at, PriceStatus s) = board.priceAt(0, T, 0);
        assertEq(p, 0);
        assertEq(at, 0);
        assertEq(uint8(s), uint8(PriceStatus.MarketClosed));
        // before the first entry: also hint 0
        _post(0, T - 10, 5);
        (,, s) = board.priceAt(0, T - 11, 0);
        assertEq(uint8(s), uint8(PriceStatus.MarketClosed));
        // entry exactly maxAge old is Ok, one second older is a stale close
        (p,, s) = board.priceAt(0, T - 10 + MAX_AGE, T - 10);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
        (p, at, s) = board.priceAt(0, T - 10 + MAX_AGE + 1, T - 10);
        assertEq(uint8(s), uint8(PriceStatus.MarketClosed));
        assertEq(p, 5);
        assertEq(at, T - 10);
    }

    function test_priceAtUnsupportedIsNoSource() public view {
        (,, PriceStatus s) = board.priceAt(6, T, 0);
        assertEq(uint8(s), uint8(PriceStatus.NoSource));
        (,, s) = board.priceAt(77, T, 0);
        assertEq(uint8(s), uint8(PriceStatus.NoSource));
    }
}

contract QZChainlinkSourceTest is Test {
    QZChainlinkSource internal cl;
    MockFeed internal feed;
    address internal owner = makeAddr("owner");
    uint64 internal constant T = 1_900_000_000;
    uint64 internal constant MAX_AGE = 2 hours;

    function setUp() public {
        vm.warp(T);
        cl = new QZChainlinkSource(owner, MAX_AGE);
        feed = new MockFeed();
        vm.prank(owner);
        cl.setFeed(0, address(feed));
    }

    function test_constructor() public {
        assertEq(cl.owner(), owner);
        assertEq(cl.maxAge(), MAX_AGE);
        vm.expectRevert(QZChainlinkSource.ZeroAddress.selector);
        new QZChainlinkSource(address(0), 1);
        vm.expectRevert(QZChainlinkSource.BadMaxAge.selector);
        new QZChainlinkSource(owner, 0);
    }

    function test_setFeedRules() public {
        vm.expectRevert(abi.encodeWithSelector(QZChainlinkSource.NotOwner.selector, address(this)));
        cl.setFeed(1, address(feed));
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(QZChainlinkSource.BadTrack.selector, 10));
        cl.setFeed(10, address(feed));
        vm.expectRevert(QZChainlinkSource.ZeroAddress.selector);
        cl.setFeed(1, address(0));
        vm.expectRevert(abi.encodeWithSelector(QZChainlinkSource.BadFeed.selector, address(0xBEEF)));
        cl.setFeed(1, address(0xBEEF)); // no code
        vm.expectRevert(abi.encodeWithSelector(QZChainlinkSource.BadFeed.selector, address(cl)));
        cl.setFeed(1, address(cl)); // a contract without decimals()
        feed.setDecimals(0);
        vm.expectRevert(abi.encodeWithSelector(QZChainlinkSource.BadFeed.selector, address(feed)));
        cl.setFeed(1, address(feed));
        feed.setDecimals(19);
        vm.expectRevert(abi.encodeWithSelector(QZChainlinkSource.BadFeed.selector, address(feed)));
        cl.setFeed(1, address(feed));
        feed.setDecimals(8);
        vm.expectEmit(true, false, false, true);
        emit QZChainlinkSource.FeedSet(1, address(feed));
        cl.setFeed(1, address(feed));
        vm.stopPrank();
        assertEq(cl.feeds(1), address(feed));
    }

    function test_sealFreezesFeeds() public {
        vm.expectRevert(abi.encodeWithSelector(QZChainlinkSource.NotOwner.selector, address(this)));
        cl.seal();
        vm.startPrank(owner);
        assertFalse(cl.isSealed());
        vm.expectEmit(false, false, false, true);
        emit QZChainlinkSource.SealedFeeds();
        cl.seal();
        assertTrue(cl.isSealed());
        vm.expectRevert(QZChainlinkSource.Sealed.selector);
        cl.seal();
        vm.expectRevert(QZChainlinkSource.Sealed.selector);
        cl.setFeed(1, address(feed));
        vm.stopPrank();
    }

    function test_isSupported() public view {
        assertTrue(cl.isSupported(0));
        assertFalse(cl.isSupported(1));
        assertFalse(cl.isSupported(10));
        assertFalse(cl.isSupported(255));
    }

    function test_noSource() public view {
        (,, PriceStatus s) = cl.priceAt(1, T, 0);
        assertEq(uint8(s), uint8(PriceStatus.NoSource));
        (,, s) = cl.priceAt(200, T, 0);
        assertEq(uint8(s), uint8(PriceStatus.NoSource));
    }

    function test_okWithRightHint() public {
        feed.push(1, 100e8, T - 1000);
        feed.push(2, 101e8, T - 500);
        // latest round, hint = latest
        (uint256 p, uint64 at, PriceStatus s) = cl.priceAt(0, T, 2);
        assertEq(p, 101e8);
        assertEq(at, T - 500);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
        // ts between the rounds: hint round 1, the next one is later than ts
        (p, at, s) = cl.priceAt(0, T - 600, 1);
        assertEq(p, 100e8);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
        // ts exactly at a round time
        (p,, s) = cl.priceAt(0, T - 500, 2);
        assertEq(p, 101e8);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
    }

    function test_wrongHintReverts() public {
        feed.push(1, 100e8, T - 1000);
        feed.push(2, 101e8, T - 500);
        feed.push(3, 102e8, T - 100);
        vm.expectRevert(QZChainlinkSource.BadHint.selector); // not the last round before ts
        cl.priceAt(0, T, 2);
        vm.expectRevert(QZChainlinkSource.BadHint.selector); // next round is exactly at ts
        cl.priceAt(0, T - 100, 2);
        vm.expectRevert(QZChainlinkSource.BadHint.selector); // round after ts
        cl.priceAt(0, T - 200, 3);
        vm.expectRevert(QZChainlinkSource.BadHint.selector); // nonexistent round
        cl.priceAt(0, T, 9);
        vm.expectRevert(QZChainlinkSource.BadHint.selector); // round 0
        cl.priceAt(0, T, 0);
        vm.expectRevert(QZChainlinkSource.BadHint.selector); // not a uint80
        cl.priceAt(0, T, uint256(type(uint80).max) + 1);
    }

    function test_phaseBoundaryNeedsRightHint() public {
        uint80 phase1Last = 5;
        uint80 phase2First = (uint80(1) << 64) + 1;
        feed.push(phase1Last, 100e8, T - 1000);
        feed.push(phase2First, 101e8, T - 100);
        // ts between the phases: round 5 is the right one but round 6 does not exist, so the hint cannot be proven
        vm.expectRevert(QZChainlinkSource.BadHint.selector);
        cl.priceAt(0, T - 500, phase1Last);
        // after the new phase's first round, the hint is its id
        (uint256 p,, PriceStatus s) = cl.priceAt(0, T, phase2First);
        assertEq(p, 101e8);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
    }

    function test_pausedCases() public {
        feed.push(1, 100e8, T - 100);
        feed.setLatestReverts(true);
        (,, PriceStatus s) = cl.priceAt(0, T, 1);
        assertEq(uint8(s), uint8(PriceStatus.Paused));
        feed.setLatestReverts(false);
        feed.pushRaw(2, 100e8, 0, 2); // round with no update time
        (,, s) = cl.priceAt(0, T, 2);
        assertEq(uint8(s), uint8(PriceStatus.Paused));
        feed.pushRaw(3, 0, T - 50, 3); // zero answer
        (,, s) = cl.priceAt(0, T, 3);
        assertEq(uint8(s), uint8(PriceStatus.Paused));
        feed.pushRaw(4, -5, T - 40, 4); // negative answer
        (,, s) = cl.priceAt(0, T, 4);
        assertEq(uint8(s), uint8(PriceStatus.Paused));
        feed.pushRaw(5, 100e8, T - 30, 4); // answered in an earlier round
        (,, s) = cl.priceAt(0, T, 5);
        assertEq(uint8(s), uint8(PriceStatus.Paused));
        feed.pushRaw(6, int256(uint256(type(uint128).max) + 1), T - 20, 6); // does not fit 128 bits
        (,, s) = cl.priceAt(0, T, 6);
        assertEq(uint8(s), uint8(PriceStatus.Paused));
    }

    function test_staleRoundIsMarketClosed() public {
        feed.push(1, 100e8, T - 1000);
        (uint256 p, uint64 at, PriceStatus s) = cl.priceAt(0, T - 1000 + MAX_AGE, 1);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
        (p, at, s) = cl.priceAt(0, T - 1000 + MAX_AGE + 1, 1);
        assertEq(uint8(s), uint8(PriceStatus.MarketClosed));
        assertEq(p, 100e8);
        assertEq(at, T - 1000);
    }
}

/// @dev The Bell against a Chainlink-shaped source: hints, the calm-day void, a dead feed.
contract QZCloseBellChainlinkTest is BellFixture {
    QZChainlinkSource internal cl;
    MockFeed internal feed;
    QZCloseBell internal cb;
    uint64 internal constant MAX_AGE = 30 minutes;

    function setUp() public override {
        super.setUp();
        cl = new QZChainlinkSource(address(this), MAX_AGE);
        feed = new MockFeed();
        cl.setFeed(NVDA, address(feed));
        cl.seal();
        cb = new QZCloseBell(
            address(machine), address(forge), address(qz), address(usdg), address(cl), calendar, treasury, sponsor, _profile()
        );
        vm.prank(calendar);
        cb.createSeason(1, 1, BASE - 1 hours, ANTE, _times(BASE + 5 minutes, N));
        vm.prank(alice);
        qz.approve(address(cb), type(uint256).max);
        // r1 is a fresh close for the baseline; r2 is more than maxAge before session 1's close (a calm day)
        feed.push(1, 100e8, BASE - 1 hours - 10 minutes);
        feed.push(2, 100e8 + 1e8, closeOf_(1) - MAX_AGE - 1);
        // session 2 has a fresh round
        feed.push(3, 105e8, closeOf_(2) - 100);
    }

    function test_calmDayVoidsSessionAndRefunds() public {
        vm.warp(BASE);
        cb.snapshotBaseline(1, NVDA, 1);
        _toWindow(1);
        vm.prank(alice);
        cb.call(A, 1, NVDA, Direction.Up);
        _toSnap(1);
        // the adapter wants the last round before the close; it is older than maxAge: MarketClosed -> Closed
        cb.snapshot(NVDA, 1, 2);
        (,,, CloseStatus s) = cb.closeOf(NVDA, 1);
        assertEq(uint8(s), uint8(CloseStatus.Closed));
        uint256 before_ = qz.balanceOf(alice);
        cb.settle(A, 1);
        assertEq(qz.balanceOf(alice) - before_, ANTE); // refunded, not burned
        assertEq(cb.totalBurned(), 0);
        (uint32 streak,,,,) = cb.heatOf(A);
        assertEq(streak, 0);
    }

    function test_wrongHintDoesNotRecordAVoid() public {
        vm.warp(BASE);
        cb.snapshotBaseline(1, NVDA, 1);
        _toSnap(1);
        // hint 1 is not the last round before the close: the source reverts, the Bell cannot record anything
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        cb.snapshot(NVDA, 1, 1);
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        cb.snapshot(NVDA, 1, 3); // a later round
        assertEq(cb.lastSnapshotted(NVDA), 0);
    }

    function test_freshRoundSettlesNormally() public {
        vm.warp(BASE);
        cb.snapshotBaseline(1, NVDA, 1);
        _toSnap(1);
        cb.snapshot(NVDA, 1, 2); // Closed, calm day
        _toWindow(2);
        vm.prank(alice);
        cb.call(A, 2, NVDA, Direction.Up);
        _toSnap(2);
        cb.snapshot(NVDA, 2, 3);
        (uint128 price, int32 mv,, CloseStatus s) = cb.closeOf(NVDA, 2);
        assertEq(price, 105e8);
        assertEq(mv, 500);
        assertEq(uint8(s), uint8(CloseStatus.Up));
        cb.settle(A, 2);
        assertEq(cb.totalBurned(), ANTE);
        assertEq(cb.seasonPoints(1, A), 1);
    }

    function test_deadFeedExpiresInsteadOfBlocking() public {
        vm.warp(BASE);
        cb.snapshotBaseline(1, NVDA, 1);
        _toWindow(1);
        vm.prank(alice);
        cb.call(A, 1, NVDA, Direction.Up);
        feed.setLatestReverts(true); // Paused
        _toSnap(1);
        vm.expectRevert(IQZCloseBell.SourceUnavailable.selector);
        cb.snapshot(NVDA, 1, 2);
        vm.warp(closeOf_(1) + VOID_AFTER);
        cb.voidExpired(A, 1);
        assertEq(cb.totalRefunded(), ANTE);
        assertEq(cb.totalBurned(), 0);
    }

    function test_unregisteredTrackIsNotCallable() public {
        assertFalse(cb.isCallable(TSLA));
        _toWindow(1);
        vm.prank(bob);
        qz.approve(address(cb), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZCloseBell.NotCallable.selector, TSLA));
        vm.prank(bob);
        cb.call(B, 1, TSLA, Direction.Up);
    }
}
