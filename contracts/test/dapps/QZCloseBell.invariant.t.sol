// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {QZCloseBell} from "../../src/dapps/QZCloseBell.sol";
import {PriceStatus} from "../../src/interfaces/IQZPriceSource.sol";
import {Direction, CallState, CloseStatus} from "../../src/interfaces/IQZCloseBell.sol";
import {MockQZ} from "../light/mocks/LightMocks.sol";
import {MockUSDG} from "../machine/MockUSDG.sol";
import {BellFixture, MockMachineLite, ScriptedSource} from "./BellFixture.sol";

/// @dev Random play against one four-session season. Time only moves forward. Ghost variables record what the handler
///      saw from outside; the invariants compare them with the Bell's own counters.
contract BellHandler is Test {
    QZCloseBell public bell;
    MockQZ public qz;
    MockUSDG public usdg;
    MockMachineLite public machine;
    ScriptedSource public src;
    address public treasury;
    address public sponsor;
    address[5] public players;
    uint256[] public ids;
    uint32 public sessions;
    uint16 public constant SEASON = 1;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint128[4] public px;
    uint256 public ghostFundedUsdg;
    uint256 public ghostClaimedUsdg;
    uint256 public ghostSweptUsdg;
    uint256 public frozenTotal;
    bool public frozenSet;
    bool public violation; // any breach seen from outside
    string public violationWhy;
    bytes32 internal lastHeat;
    uint256 public okCalls;
    uint256 public okSettles;
    uint256 public okVoids;
    uint256 public okClaims;

    constructor(
        QZCloseBell bell_,
        MockQZ qz_,
        MockUSDG usdg_,
        MockMachineLite machine_,
        ScriptedSource src_,
        address treasury_,
        address sponsor_,
        address[5] memory players_,
        uint256[] memory ids_,
        uint32 sessions_
    ) {
        bell = bell_;
        qz = qz_;
        usdg = usdg_;
        machine = machine_;
        src = src_;
        treasury = treasury_;
        sponsor = sponsor_;
        players = players_;
        ids = ids_;
        sessions = sessions_;
        for (uint256 i; i < 4; ++i) {
            px[i] = 100e8;
        }
        lastHeat = _heatHash();
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    // ───────────── helpers ─────────────

    function _flag(string memory why) internal {
        if (!violation) {
            violation = true;
            violationWhy = why;
        }
    }

    function _heatHash() internal view returns (bytes32 h) {
        for (uint256 i; i < ids.length; ++i) {
            (uint32 a, uint32 b, uint32 c, uint32 d,) = bell.heatOf(ids[i]);
            h = keccak256(abi.encode(h, a, b, c, d));
        }
    }

    /// @dev Heat may only change inside settle / settleMany.
    function _afterAction(bool mayChangeHeat) internal {
        bytes32 h = _heatHash();
        if (!mayChangeHeat && h != lastHeat) _flag("heat changed without a settle");
        lastHeat = h;
    }

    function _warpTo(uint64 t) internal {
        if (t > block.timestamp) vm.warp(t);
    }

    function _session(uint256 seed) internal view returns (uint32) {
        return uint32(1 + seed % sessions);
    }

    function _id(uint256 seed) internal view returns (uint256) {
        return ids[seed % ids.length];
    }

    function _times(uint32 s) internal view returns (uint64 opens, uint64 cutoff, uint64 closeTs) {
        (opens, cutoff, closeTs,) = bell.sessionTimes(s);
    }

    // ───────────── actions ─────────────

    function advance(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 150));
        _afterAction(false);
    }

    function call(uint256 idSeed, uint256 sSeed, uint256 trackSeed, bool up) external {
        uint256 id = _id(idSeed);
        uint32 s = _session(sSeed);
        (uint64 opens, uint64 cutoff,) = _times(s);
        if (block.timestamp >= cutoff) return;
        _warpTo(opens);
        (, uint8 ownTrack, bool relic) = machine.traitsOf(id);
        uint8 track = relic ? uint8(trackSeed % 4) : ownTrack;
        address owner = machine.ownerOf(id);
        vm.prank(owner);
        try bell.call(id, s, track, up ? Direction.Up : Direction.Down) {
            ++okCalls;
        } catch {}
        _afterAction(false);
    }

    /// @param mode 0 up, 1 down, 2 flat, 3 market closed, 4 paused, 5 expire
    function snapshot(uint256 trackSeed, uint256 mode, uint256 moveSeed) external {
        uint8 track = uint8(trackSeed % 4);
        uint32 s = bell.lastSnapshotted(track) + 1;
        if (s > sessions) return;
        (,, uint64 closeTs) = _times(s);
        mode = mode % 6;
        _warpTo(closeTs + bell.snapshotDelay());
        if (mode == 5 && moveSeed % 4 == 0) _warpTo(closeTs + bell.voidAfter());
        uint128 move = uint128(1e8 + moveSeed % 5e8);
        uint128 price = px[track];
        if (mode == 0) price += move;
        else if (mode == 1) price -= move / 2;
        if (mode <= 2) src.setAnswer(track, closeTs, price, PriceStatus.Ok);
        else if (mode == 3) src.setAnswer(track, closeTs, 0, PriceStatus.MarketClosed);
        else if (mode == 4) src.setAnswer(track, closeTs, 0, PriceStatus.Paused);
        try bell.snapshot(track, s, 0) {
            if (mode <= 1) px[track] = price;
        } catch {}
        _afterAction(false);
    }

    function settle(uint256 idSeed, uint256 sSeed) external {
        uint256 id = _id(idSeed);
        uint32 s = _session(sSeed);
        (,,, CallState before_) = bell.callOf(id, s);
        uint64 total = bell.seasonTotalPoints(SEASON);
        (,,,, uint64 claimOpensAt,) = _season();
        try bell.settle(id, s) {
            ++okSettles;
            (,, uint32 prevOk, CloseStatus cs) = bell.closeOf(_trackOf(id, s), s);
            prevOk;
            (,,, CallState after_) = bell.callOf(id, s);
            if (before_ != CallState.Open) _flag("finalised a call that was not open");
            bool decisive = cs == CloseStatus.Up || cs == CloseStatus.Down;
            if (decisive != (after_ == CallState.Settled)) _flag("burn/refund does not follow the snapshot");
            if (block.timestamp >= claimOpensAt && bell.seasonTotalPoints(SEASON) != total) {
                _flag("points added after the freeze");
            }
        } catch {}
        _afterAction(true);
    }

    function settleMany(uint256 sSeed) external {
        uint32 s = _session(sSeed);
        uint256 n = ids.length;
        uint64 total = bell.seasonTotalPoints(SEASON);
        (,,,, uint64 claimOpensAt,) = _season();
        try bell.settleMany(ids, s) returns (uint256 c) {
            okSettles += c;
        } catch {}
        if (block.timestamp >= claimOpensAt && bell.seasonTotalPoints(SEASON) != total) {
            _flag("points added after the freeze");
        }
        n;
        _afterAction(true);
    }

    function voidExpired(uint256 idSeed, uint256 sSeed, bool warp) external {
        uint256 id = _id(idSeed);
        uint32 s = _session(sSeed);
        (,, uint64 closeTs) = _times(s);
        if (warp && idSeed % 8 == 0) _warpTo(closeTs + bell.voidAfter());
        uint8 track = _trackOf(id, s);
        (,, uint32 prevOk, CloseStatus cs) = bell.closeOf(track, s);
        prevOk;
        try bell.voidExpired(id, s) {
            ++okVoids;
            if (cs != CloseStatus.None) _flag("voided a call whose session had a snapshot");
        } catch {}
        _afterAction(false);
    }

    function transferMachine(uint256 idSeed, uint256 toSeed) external {
        uint256 id = _id(idSeed);
        address owner = machine.ownerOf(id);
        address to = players[toSeed % players.length];
        if (to == owner) return;
        vm.prank(owner);
        machine.transferFrom(owner, to, id);
        _afterAction(false);
    }

    function hostileSource(uint256 modeSeed) external {
        uint256 m = modeSeed % 8;
        // mostly honest: only 3 of 8 values are hostile
        ScriptedSource.Mode mode = m == 0
            ? ScriptedSource.Mode.Revert
            : m == 1 ? ScriptedSource.Mode.Bomb : m == 2 ? ScriptedSource.Mode.Garbage : ScriptedSource.Mode.Normal;
        src.setMode(mode);
        _afterAction(false);
    }

    function fund(uint256 amount, bool bySponsor) external {
        (,,,, uint64 claimOpensAt,) = _season();
        if (block.timestamp >= claimOpensAt) return;
        amount = bound(amount, 1, 1e9);
        address from = bySponsor ? sponsor : treasury;
        vm.prank(from);
        try bell.fundPurse(SEASON, amount) {
            ghostFundedUsdg += amount;
        } catch {}
        _afterAction(false);
    }

    function claim(uint256 idSeed, bool warp) external {
        (,,,, uint64 claimOpensAt,) = _season();
        if (warp && idSeed % 8 == 0) _warpTo(claimOpensAt);
        uint256 id = _id(idSeed);
        address to = machine.ownerOf(id);
        uint256 before_ = usdg.balanceOf(to);
        uint64 total = bell.seasonTotalPoints(SEASON);
        try bell.claimPurse(id, SEASON) {
            ++okClaims;
            ghostClaimedUsdg += usdg.balanceOf(to) - before_;
            if (!frozenSet) {
                frozenSet = true;
                frozenTotal = total;
            }
        } catch {}
        _afterAction(false);
    }

    function sweep(bool warp) external {
        (,,,, uint64 claimOpensAt,) = _season();
        if (warp && block.number % 8 == 0) _warpTo(claimOpensAt + bell.SWEEP_AFTER());
        uint256 before_ = usdg.balanceOf(treasury);
        try bell.sweepPurse(SEASON) {
            ghostSweptUsdg += usdg.balanceOf(treasury) - before_;
        } catch {}
        _afterAction(false);
    }

    function _season() internal view returns (uint32 a, uint32 b, uint64 c, uint128 d, uint64 claimOpensAt, bool e) {
        return bell.seasons(SEASON);
    }

    function _trackOf(uint256 id, uint32 s) internal view returns (uint8 track) {
        (, track,,) = bell.callOf(id, s);
    }
}

contract QZCloseBellInvariantTest is BellFixture {
    BellHandler internal h;
    uint256[] internal allIds;

    function setUp() public override {
        super.setUp();
        machine.mint(bob, 11, 0, false);
        machine.mint(carol, 12, TSLA, false);
        machine.mint(dave, 13, GME, false);
        machine.mint(alice, 14, 1, false);
        forge.setLit(11, true);
        forge.setLit(12, true);
        forge.setLit(13, true);
        forge.setLit(14, true);
        allIds.push(A);
        allIds.push(B);
        allIds.push(A2);
        allIds.push(11);
        allIds.push(12);
        allIds.push(13);
        allIds.push(14);
        allIds.push(R);
        allIds.push(C); // never lit: every call reverts
        address[5] memory players = [alice, bob, carol, rel, dave];
        h = new BellHandler(bell, qz, usdg, machine, src, treasury, sponsor, players, allIds, N);
        for (uint8 t; t < 4; ++t) {
            src.setAnswer(t, BASE - 1 hours, 100e8, PriceStatus.Ok);
            bell.snapshotBaseline(S1, t, 0);
        }
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = h.advance.selector;
        sel[1] = h.call.selector;
        sel[2] = h.snapshot.selector;
        sel[3] = h.settle.selector;
        sel[4] = h.settleMany.selector;
        sel[5] = h.voidExpired.selector;
        sel[6] = h.transferMachine.selector;
        sel[7] = h.hostileSource.selector;
        sel[8] = h.fund.selector;
        sel[9] = h.claim.selector;
        sel[10] = h.sweep.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function _countCalls() internal view returns (uint256 open, uint256 settled, uint256 refunded) {
        for (uint256 i; i < allIds.length; ++i) {
            for (uint32 s = 1; s <= N; ++s) {
                CallState st = _state(allIds[i], s);
                if (st == CallState.Open) ++open;
                else if (st == CallState.Settled) ++settled;
                else if (st == CallState.Refunded) ++refunded;
            }
        }
    }

    /// @dev The Bell holds exactly the open antes and nothing else; every ante is open, burned or refunded.
    function invariant_qzConservation() public view {
        (uint256 open, uint256 settled, uint256 refunded) = _countCalls();
        assertEq(qz.balanceOf(address(bell)), bell.openAntes(), "bell balance == open antes");
        assertEq(bell.openAntes(), open * ANTE, "open antes == open calls");
        assertEq(bell.totalBurned(), settled * ANTE, "burned == settled calls");
        assertEq(bell.totalRefunded(), refunded * ANTE, "refunded == refunded calls");
        assertEq(qz.balanceOf(DEAD), bell.totalBurned(), "dead address == burned");
        assertEq(bell.totalAnteIn(), bell.totalBurned() + bell.totalRefunded() + bell.openAntes(), "in == out + open");
        assertEq(bell.totalAnteIn(), (open + settled + refunded) * ANTE, "in == calls * ante");
    }

    /// @dev A call whose session snapshot was Up/Down is never refunded; a void snapshot is never burned; a call
    ///      without a snapshot is never burned.
    function invariant_burnFollowsTheSnapshot() public view {
        for (uint256 i; i < allIds.length; ++i) {
            for (uint32 s = 1; s <= N; ++s) {
                (, uint8 track,, CallState st) = bell.callOf(allIds[i], s);
                if (st == CallState.None) continue;
                CloseStatus cs = _status(track, s);
                bool decisive = cs == CloseStatus.Up || cs == CloseStatus.Down;
                if (st == CallState.Refunded) assertFalse(decisive, "refunded after an Up/Down snapshot");
                if (st == CallState.Settled) assertTrue(decisive, "burned without an Up/Down snapshot");
            }
        }
    }

    function invariant_heatIsConsistent() public view {
        uint256 pointsSum;
        for (uint256 i; i < allIds.length; ++i) {
            (uint32 streak, uint32 best, uint32 wins, uint32 losses,) = bell.heatOf(allIds[i]);
            assertLe(streak, best, "streak <= best");
            assertLe(best, wins, "best <= wins");
            assertLe(streak, wins, "streak <= wins");
            uint32 pts = bell.seasonPoints(S1, allIds[i]);
            assertGe(pts, 0);
            assertLe(pts, uint256(wins) * 7, "points <= 7 per win");
            // settled Up/Down calls of the machine == wins + losses
            uint256 decisive;
            for (uint32 s = 1; s <= N; ++s) {
                (, uint8 track,, CallState st) = bell.callOf(allIds[i], s);
                if (st == CallState.Settled) {
                    ++decisive;
                    track;
                }
            }
            assertEq(decisive, uint256(wins) + losses, "wins + losses == settled calls");
            pointsSum += pts;
        }
        assertEq(bell.seasonTotalPoints(S1), pointsSum, "total == sum of machine points");
        uint256 teams;
        for (uint8 t; t < 10; ++t) {
            teams += bell.teamPoints(S1, t);
        }
        assertEq(teams, pointsSum, "team points == machine points");
    }

    function invariant_purseAccounting() public view {
        (uint128 funded, uint128 paid, bool swept) = bell.purseOf(S1);
        assertEq(funded, h.ghostFundedUsdg(), "funded == what the funders sent");
        assertLe(paid, funded, "paid out <= funded");
        assertEq(usdg.balanceOf(address(bell)), uint256(funded) - paid, "usdg held == funded - paid");
        assertEq(paid, h.ghostClaimedUsdg() + h.ghostSweptUsdg(), "paid == claims + sweep");
        if (swept) assertEq(funded, paid);
        // claims never exceed funded * points / total for the frozen total
        if (h.frozenSet()) assertEq(bell.seasonTotalPoints(S1), h.frozenTotal(), "points frozen once claims start");
    }

    function invariant_noOutsideViolation() public view {
        assertFalse(h.violation(), h.violationWhy());
    }

    function invariant_everyCallOpensOnlyOnce() public view {
        assertEq(h.okCalls(), _totalCalls(), "ok calls == recorded calls");
    }

    function _totalCalls() internal view returns (uint256 n) {
        (uint256 o, uint256 s, uint256 r) = _countCalls();
        return o + s + r;
    }

    /// @dev Non-vacuity counters for the -vv log: how much real play each run reached.
    function afterInvariant() public view {
        console2.log("ok calls/settles/voids/claims", h.okCalls(), h.okSettles(), h.okVoids());
        console2.log("claims, burned/ante", h.okClaims(), bell.totalBurned() / ANTE);
    }
}
