// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {QZConstants} from "../lib/QZConstants.sol";
import {IQZMachine} from "../interfaces/IQZMachine.sol";
import {IQZForge} from "../interfaces/IQZForge.sol";
import {IQZPriceSource, PriceStatus} from "../interfaces/IQZPriceSource.sol";
import {
    IQZCloseBell,
    Direction,
    CallState,
    CloseStatus,
    Result,
    Profile,
    SessionTimes
} from "../interfaces/IQZCloseBell.sol";

/// @title QZCloseBell
/// @notice Closing Bell (docs/DAPPS.md, Pick). Each lit machine calls UP or DOWN on the close-to-close move of its own
///         ticker before a cutoff, pays an ante in $QZ held by this contract until the call settles, and builds a heat
///         streak that follows the NFT. The ante is burned (a transfer to the dead address, $QZ has no burn function)
///         when the call settles as a win or a loss, and returned to the payer when the session is void. Nothing is
///         wagered between players and antes never reach a player.
///
///         Lifecycle of a call: `call` (ante in) -> `snapshot` (anyone records the ticker's close, strictly in session
///         order per track) -> `settle` (anyone: burn on Up or Down, refund on a void session). `voidExpired` refunds a
///         call whose session still has no snapshot at `closeTs + voidAfter`; once any snapshot exists, `settle` is the
///         only way out, so a loser cannot dodge the burn by waiting. `snapshot` at or after that time records
///         `Expired` without reading the source, so a reverting, lying or gas-bombing source cannot hold funds.
///
///         Season purse. Points freeze at the season's `claimOpensAt` (last close + `claimDelay`, at least
///         `voidAfter`): a settle after that adds heat but no points. The purse is per season (`funded`, `paidOut`)
///         and is split `purse * points / totalPoints` (rounded down) from the frozen totals, so the sum of claims of a
///         season can never exceed that season's purse. Only the treasury or the sponsor fixed at deploy can fund it.
///
///         Heat. A win extends the streak when the machine's last Up or Down settle is the track's previous Up or
///         Down session (void sessions are invisible, a skipped session breaks the chain); otherwise it restarts at 1.
///         A win scores `1 + min(streak - 1, 6)` points. A loss resets the streak. An Up or Down call settles after the
///         machine's previous call is final, so heat is order-deterministic. Heat is keyed by machine id and follows
///         the NFT; the ante is refunded to the wallet that paid it; the purse pays `ownerOf(id)` at claim time.
///
///         There is no pause, owner, upgrade or withdrawal, and no loop over machines or players. The only loops are
///         bounded by caller input (`createSeason` by `MAX_SESSIONS`, `settleMany` by the array the caller sends).
///         $QZ sent to this contract by hand is not an ante and stays here: all accounting uses counters, never the
///         token balance. The six deployed contracts are read only (`ownerOf`, `traitsOf`, `isLit`, all `view`).
contract QZCloseBell is IQZCloseBell {
    using SafeERC20 for IERC20;

    // ───────────── constants ─────────────

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_SESSIONS = 366;
    uint64 public constant SWEEP_AFTER = 180 days;
    /// @notice Points per win: `1 + min(streak - 1, MAX_STREAK_BONUS)`.
    uint32 public constant MAX_STREAK_BONUS = 6;
    uint256 internal constant SOURCE_GAS = 300_000;
    uint256 internal constant BPS = 10_000;

    // ───────────── types ─────────────

    struct Season {
        uint32 firstSession;
        uint32 lastSession;
        uint64 baselineCloseTs;
        uint128 ante;
        uint64 claimOpensAt;
        bool exists;
    }

    struct Heat {
        uint32 streak;
        uint32 best;
        uint32 wins;
        uint32 losses;
        uint32 lastOkSession;
        uint32 lastCallSession;
    }

    struct Call {
        address payer;
        uint8 track;
        Direction dir;
        CallState state;
        uint32 prev;
    }

    struct Close {
        uint128 price;
        int32 moveBps;
        uint32 prevOkSession;
        CloseStatus status;
    }

    struct LastOk {
        uint32 session;
        uint128 price;
    }

    struct Purse {
        uint128 funded;
        uint128 paidOut;
        bool swept;
    }

    /// @dev Where a call stands for `settle`.
    enum Readiness {
        NoCall,
        Done,
        NotReady,
        PrevOpen,
        Ready
    }

    /// @dev `session` is stored with its season, so one read gives both.
    struct SessionRow {
        uint64 opensAt;
        uint64 cutoff;
        uint64 closeTs;
        uint16 season;
    }

    // ───────────── immutables ─────────────

    address public immutable machine;
    address public immutable forge;
    address public immutable qz;
    address public immutable usdg;
    address public immutable source;
    address public immutable calendar;
    address public immutable treasury;
    address public immutable sponsor;
    uint64 public immutable voidAfter;
    uint64 public immutable claimDelay;
    uint64 public immutable minLead;
    uint64 public immutable snapshotDelay;

    // ───────────── state ─────────────

    uint16 public seasonCount;
    uint32 public sessionCount;
    uint256 public totalBurned;
    uint256 public openAntes;
    uint256 public totalRefunded;
    uint256 public totalAnteIn;
    uint256 private _entered;

    mapping(uint16 season => Season) private _seasons;
    mapping(uint32 session => SessionRow) private _sessions;
    mapping(uint256 id => Heat) private _heat;
    mapping(uint256 id => mapping(uint32 session => Call)) private _calls;
    mapping(uint8 track => mapping(uint32 session => Close)) private _closes;
    mapping(uint8 track => uint32) private _lastSnapshotted;
    mapping(uint8 track => LastOk) private _lastOk;
    mapping(uint16 season => mapping(uint8 track => uint128)) private _baselines;
    mapping(uint16 season => mapping(uint256 id => uint32)) private _seasonPoints;
    mapping(uint16 season => uint64) private _seasonTotalPoints;
    mapping(uint16 season => mapping(uint8 track => uint64)) private _teamPoints;
    mapping(uint16 season => Purse) private _purses;
    mapping(uint16 season => mapping(uint256 id => bool)) private _purseClaimed;

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(
        address machine_,
        address forge_,
        address qz_,
        address usdg_,
        address source_,
        address calendar_,
        address treasury_,
        address sponsor_,
        Profile memory profile
    ) {
        if (
            machine_ == address(0) || forge_ == address(0) || qz_ == address(0) || usdg_ == address(0)
                || source_ == address(0) || calendar_ == address(0) || treasury_ == address(0)
        ) revert ZeroAddress();
        if (
            profile.voidAfter == 0 || profile.claimDelay < profile.voidAfter || profile.snapshotDelay == 0
                || profile.snapshotDelay >= profile.voidAfter
        ) revert BadProfile();
        machine = machine_;
        forge = forge_;
        qz = qz_;
        usdg = usdg_;
        source = source_;
        calendar = calendar_;
        treasury = treasury_;
        sponsor = sponsor_;
        voidAfter = profile.voidAfter;
        claimDelay = profile.claimDelay;
        minLead = profile.minLead;
        snapshotDelay = profile.snapshotDelay;
    }

    // ───────────── calendar ─────────────

    /// @inheritdoc IQZCloseBell
    function createSeason(
        uint16 season,
        uint32 firstSession,
        uint64 baselineCloseTs,
        uint128 ante,
        SessionTimes[] calldata times
    ) external {
        if (msg.sender != calendar) revert NotCalendar(msg.sender);
        if (_seasons[season].exists) revert SeasonExists(season);
        if (season != uint256(seasonCount) + 1 || firstSession != sessionCount + 1) revert BadSeason();
        uint256 n = times.length;
        if (n == 0 || n > MAX_SESSIONS || ante == 0) revert BadTimes();
        uint32 last = sessionCount;
        if (last != 0 && baselineCloseTs < _sessions[last].closeTs) revert BadTimes();
        if (baselineCloseTs == 0) revert BadTimes();
        uint64 earliest = uint64(block.timestamp) + minLead;
        if (times[0].opensAt < earliest) revert TooSoon(times[0].opensAt, earliest);

        uint64 floorTs = baselineCloseTs;
        for (uint256 i; i < n; ++i) {
            SessionTimes calldata t = times[i];
            if (t.opensAt < floorTs || t.opensAt >= t.cutoff || t.cutoff >= t.closeTs) revert BadTimes();
            _sessions[firstSession + uint32(i)] =
                SessionRow({opensAt: t.opensAt, cutoff: t.cutoff, closeTs: t.closeTs, season: season});
            floorTs = t.closeTs;
        }
        uint32 lastSession = firstSession + uint32(n) - 1;
        _seasons[season] = Season({
            firstSession: firstSession,
            lastSession: lastSession,
            baselineCloseTs: baselineCloseTs,
            ante: ante,
            claimOpensAt: floorTs + claimDelay,
            exists: true
        });
        seasonCount = season;
        sessionCount = lastSession;
        emit SeasonCreated(season, firstSession, lastSession, ante);
    }

    // ───────────── play ─────────────

    /// @inheritdoc IQZCloseBell
    function call(uint256 id, uint32 session, uint8 track, Direction dir) external nonReentrant {
        SessionRow memory st = _sessions[session];
        if (st.closeTs == 0) revert NoSession(session);
        if (block.timestamp < st.opensAt || block.timestamp >= st.cutoff) revert WindowClosed(st.opensAt, st.cutoff);
        if (dir != Direction.Up && dir != Direction.Down) revert BadDirection();
        if (track >= QZConstants.TRACK_COUNT) revert BadTrack(track);
        if (IQZMachine(machine).ownerOf(id) != msg.sender) revert NotOwner(msg.sender);
        if (!IQZForge(forge).isLit(id)) revert NotLit(id);
        (, uint8 ownTrack, bool relic) = IQZMachine(machine).traitsOf(id);
        if (!relic && ownTrack != track) revert WrongTrack(ownTrack, track);
        if (!IQZPriceSource(source).isSupported(track)) revert NotCallable(track);
        Call storage c = _calls[id][session];
        if (c.state != CallState.None) revert AlreadyCalled(id, session);

        uint128 ante = _seasons[st.season].ante;
        Heat storage h = _heat[id];
        c.payer = msg.sender;
        c.track = track;
        c.dir = dir;
        c.state = CallState.Open;
        c.prev = h.lastCallSession;
        h.lastCallSession = session;
        openAntes += ante;
        totalAnteIn += ante;
        emit Called(id, session, track, dir, msg.sender);

        _pull(IERC20(qz), msg.sender, ante);
    }

    /// @inheritdoc IQZCloseBell
    function snapshotBaseline(uint16 season, uint8 track, uint256 hint) external {
        Season memory sn = _seasons[season];
        if (!sn.exists) revert NoSeason(season);
        if (track >= QZConstants.TRACK_COUNT) revert BadTrack(track);
        if (!IQZPriceSource(source).isSupported(track)) revert NotCallable(track);
        if (_baselines[season][track] != 0) revert BaselineAlreadySet(season, track);
        uint64 readyAt = sn.baselineCloseTs + snapshotDelay;
        if (block.timestamp < readyAt) revert TooEarly(readyAt);
        (bool ok, uint256 price,, PriceStatus status) = _read(track, sn.baselineCloseTs, hint);
        if (!ok || status != PriceStatus.Ok) revert SourceUnavailable();
        _baselines[season][track] = uint128(price);
        emit BaselineSet(season, track, uint128(price));
    }

    /// @inheritdoc IQZCloseBell
    function snapshot(uint8 track, uint32 session, uint256 hint) external {
        SessionRow memory st = _sessions[session];
        if (st.closeTs == 0) revert NoSession(session);
        if (track >= QZConstants.TRACK_COUNT) revert BadTrack(track);
        uint32 expected = _lastSnapshotted[track] + 1;
        if (session != expected) revert OutOfOrder(expected, session);
        if (!IQZPriceSource(source).isSupported(track)) revert NotCallable(track);
        uint64 readyAt = st.closeTs + snapshotDelay;
        if (block.timestamp < readyAt) revert TooEarly(readyAt);

        Close memory cl = _evaluate(track, session, hint, st);
        _closes[track][session] = cl;
        _lastSnapshotted[track] = session;
        emit Snapshotted(track, session, cl.price, cl.moveBps, cl.status);
    }

    /// @dev Reads the source (unless the session expired) and works out the close record; updates `_lastOk` on Up or
    ///      Down.
    function _evaluate(uint8 track, uint32 session, uint256 hint, SessionRow memory st)
        private
        returns (Close memory cl)
    {
        uint32 prevOk = _lastOk[track].session;
        cl.prevOkSession = prevOk;
        if (block.timestamp >= uint256(st.closeTs) + voidAfter) {
            cl.status = CloseStatus.Expired;
            return cl;
        }
        (bool ok, uint256 p,, PriceStatus ps) = _read(track, st.closeTs, hint);
        if (!ok || ps == PriceStatus.Paused) revert SourceUnavailable();
        if (ps != PriceStatus.Ok) {
            cl.status = CloseStatus.Closed;
            return cl;
        }
        uint128 prev = _reference(track, st.season, prevOk);
        uint128 price = uint128(p);
        if (price == prev) {
            cl.status = CloseStatus.Flat;
            return cl;
        }
        cl.price = price;
        cl.status = price > prev ? CloseStatus.Up : CloseStatus.Down;
        cl.moveBps = _moveBps(price, prev);
        _lastOk[track] = LastOk({session: session, price: price});
    }

    /// @dev The price a close is measured against: the track's last Ok close inside this season, else the baseline.
    function _reference(uint8 track, uint16 season, uint32 prevOk) private view returns (uint128 prev) {
        if (prevOk != 0 && prevOk >= _seasons[season].firstSession) return _lastOk[track].price;
        prev = _baselines[season][track];
        if (prev == 0) revert BaselineMissing(season, track);
    }

    /// @inheritdoc IQZCloseBell
    function settle(uint256 id, uint32 session) external nonReentrant {
        Readiness r = _readiness(id, session);
        if (r == Readiness.NoCall) revert NoCall(id, session);
        if (r == Readiness.Done) revert AlreadySettled(id, session);
        if (r == Readiness.NotReady) revert NotSettleable(id, session);
        if (r == Readiness.PrevOpen) revert PrevUnsettled(id, session, _calls[id][session].prev);
        _settle(id, session);
    }

    /// @inheritdoc IQZCloseBell
    function settleMany(uint256[] calldata ids, uint32 session) external nonReentrant returns (uint256 settled) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            if (_readiness(ids[i], session) != Readiness.Ready) continue;
            _settle(ids[i], session);
            ++settled;
        }
    }

    /// @inheritdoc IQZCloseBell
    function voidExpired(uint256 id, uint32 session) external nonReentrant {
        Call memory c = _calls[id][session];
        if (c.state == CallState.None) revert NoCall(id, session);
        if (c.state != CallState.Open) revert AlreadySettled(id, session);
        SessionRow memory st = _sessions[session];
        if (block.timestamp < uint256(st.closeTs) + voidAfter || _closes[c.track][session].status != CloseStatus.None)
        {
            revert NotVoidable(id, session);
        }
        _refund(id, session, c.payer, _seasons[st.season].ante);
    }

    // ───────────── purse ─────────────

    /// @inheritdoc IQZCloseBell
    function fundPurse(uint16 season, uint256 amount) external nonReentrant {
        if (msg.sender != treasury && msg.sender != sponsor) revert NotFunder(msg.sender);
        Season memory sn = _seasons[season];
        if (!sn.exists) revert NoSeason(season);
        if (block.timestamp >= sn.claimOpensAt) revert TooLate();
        if (amount == 0) revert ZeroAmount();
        _purses[season].funded += SafeCast.toUint128(amount);
        emit PurseFunded(season, msg.sender, amount);
        _pull(IERC20(usdg), msg.sender, amount);
    }

    /// @inheritdoc IQZCloseBell
    function claimPurse(uint256 id, uint16 season) external nonReentrant {
        Season memory sn = _seasons[season];
        if (!sn.exists) revert NoSeason(season);
        if (block.timestamp < sn.claimOpensAt) revert TooEarly(sn.claimOpensAt);
        if (block.timestamp >= uint256(sn.claimOpensAt) + SWEEP_AFTER) revert TooLate();
        if (_purseClaimed[season][id]) revert AlreadyClaimed(id, season);
        Purse storage p = _purses[season];
        uint64 total = _seasonTotalPoints[season];
        uint256 amount = total == 0 ? 0 : uint256(p.funded) * _seasonPoints[season][id] / total;
        if (amount == 0) revert NothingToClaim(id, season);
        address to = IQZMachine(machine).ownerOf(id);
        _purseClaimed[season][id] = true;
        p.paidOut += SafeCast.toUint128(amount);
        emit PurseClaimed(id, season, to, amount);
        _push(IERC20(usdg), to, amount);
    }

    /// @inheritdoc IQZCloseBell
    function sweepPurse(uint16 season) external nonReentrant {
        Season memory sn = _seasons[season];
        if (!sn.exists) revert NoSeason(season);
        if (block.timestamp < uint256(sn.claimOpensAt) + SWEEP_AFTER) revert TooEarly(sn.claimOpensAt + SWEEP_AFTER);
        Purse storage p = _purses[season];
        uint256 amount = uint256(p.funded) - p.paidOut;
        if (p.swept || amount == 0) revert NothingToSweep(season);
        p.swept = true;
        p.paidOut = p.funded;
        emit PurseSwept(season, amount);
        _push(IERC20(usdg), treasury, amount);
    }

    // ───────────── views ─────────────

    function seasons(uint16 season)
        external
        view
        returns (
            uint32 firstSession,
            uint32 lastSession,
            uint64 baselineCloseTs,
            uint128 ante,
            uint64 claimOpensAt,
            bool exists
        )
    {
        Season memory s = _seasons[season];
        return (s.firstSession, s.lastSession, s.baselineCloseTs, s.ante, s.claimOpensAt, s.exists);
    }

    function sessionTimes(uint32 session)
        external
        view
        returns (uint64 opensAt, uint64 cutoff, uint64 closeTs, uint16 season)
    {
        SessionRow memory s = _sessions[session];
        return (s.opensAt, s.cutoff, s.closeTs, s.season);
    }

    function heatOf(uint256 id)
        external
        view
        returns (uint32 streak, uint32 best, uint32 wins, uint32 losses, uint8 band)
    {
        Heat memory h = _heat[id];
        band = h.streak == 0 ? 0 : h.streak < 3 ? 1 : h.streak < 6 ? 2 : 3;
        return (h.streak, h.best, h.wins, h.losses, band);
    }

    function callOf(uint256 id, uint32 session)
        external
        view
        returns (address payer, uint8 track, Direction dir, CallState state)
    {
        Call memory c = _calls[id][session];
        return (c.payer, c.track, c.dir, c.state);
    }

    function closeOf(uint8 track, uint32 session)
        external
        view
        returns (uint128 price, int32 moveBps, uint32 prevOkSession, CloseStatus status)
    {
        Close memory c = _closes[track][session];
        return (c.price, c.moveBps, c.prevOkSession, c.status);
    }

    function baselineOf(uint16 season, uint8 track) external view returns (uint128) {
        return _baselines[season][track];
    }

    function lastSnapshotted(uint8 track) external view returns (uint32) {
        return _lastSnapshotted[track];
    }

    function seasonPoints(uint16 season, uint256 id) external view returns (uint32) {
        return _seasonPoints[season][id];
    }

    function seasonTotalPoints(uint16 season) external view returns (uint64) {
        return _seasonTotalPoints[season];
    }

    function teamPoints(uint16 season, uint8 track) external view returns (uint64) {
        return _teamPoints[season][track];
    }

    function purseOf(uint16 season) external view returns (uint128 funded, uint128 paidOut, bool swept) {
        Purse memory p = _purses[season];
        return (p.funded, p.paidOut, p.swept);
    }

    function purseClaimed(uint16 season, uint256 id) external view returns (bool) {
        return _purseClaimed[season][id];
    }

    function isCallable(uint8 track) external view returns (bool) {
        return track < QZConstants.TRACK_COUNT && IQZPriceSource(source).isSupported(track);
    }

    // ───────────── internals ─────────────

    function _readiness(uint256 id, uint32 session) private view returns (Readiness) {
        Call memory c = _calls[id][session];
        if (c.state == CallState.None) return Readiness.NoCall;
        if (c.state != CallState.Open) return Readiness.Done;
        CloseStatus cs = _closes[c.track][session].status;
        if (cs == CloseStatus.None) return Readiness.NotReady;
        if ((cs == CloseStatus.Up || cs == CloseStatus.Down) && c.prev != 0) {
            if (_calls[id][c.prev].state == CallState.Open) return Readiness.PrevOpen;
        }
        return Readiness.Ready;
    }

    /// @dev Caller checked `_readiness == Ready`.
    function _settle(uint256 id, uint32 session) private {
        Call memory c = _calls[id][session];
        Close memory cl = _closes[c.track][session];
        SessionRow memory st = _sessions[session];
        Season memory sn = _seasons[st.season];
        if (cl.status != CloseStatus.Up && cl.status != CloseStatus.Down) {
            _refund(id, session, c.payer, sn.ante);
            return;
        }

        Heat storage h = _heat[id];
        bool win = (cl.status == CloseStatus.Up) == (c.dir == Direction.Up);
        uint32 streak;
        uint32 points;
        if (win) {
            streak = (h.lastOkSession != 0 && h.lastOkSession == cl.prevOkSession ? h.streak : 0) + 1;
            h.wins += 1;
            if (streak > h.best) h.best = streak;
            if (block.timestamp < sn.claimOpensAt) {
                points = 1 + (streak - 1 < MAX_STREAK_BONUS ? streak - 1 : MAX_STREAK_BONUS);
                _seasonPoints[st.season][id] += points;
                _seasonTotalPoints[st.season] += points;
                _teamPoints[st.season][c.track] += points;
            }
        } else {
            h.losses += 1;
        }
        h.streak = streak;
        h.lastOkSession = session;

        _calls[id][session].state = CallState.Settled;
        openAntes -= sn.ante;
        totalBurned += sn.ante;
        emit Settled(id, session, win ? Result.Win : Result.Loss, points, streak);
        emit AnteBurned(id, session, sn.ante);
        _push(IERC20(qz), DEAD, sn.ante);
    }

    function _refund(uint256 id, uint32 session, address payer, uint256 ante) private {
        _calls[id][session].state = CallState.Refunded;
        openAntes -= ante;
        totalRefunded += ante;
        emit Settled(id, session, Result.Void, 0, _heat[id].streak);
        emit AnteRefunded(id, session, payer, ante);
        _push(IERC20(qz), payer, ante);
    }

    /// @dev Pulls `amount` from `from` and checks this contract's balance grew by exactly `amount`.
    function _pull(IERC20 token, address from, uint256 amount) private {
        uint256 before_ = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 got = token.balanceOf(address(this)) - before_;
        if (got != amount) revert TransferMismatch(amount, got);
    }

    /// @dev Sends `amount` and checks this contract's balance fell by exactly `amount`.
    function _push(IERC20 token, address to, uint256 amount) private {
        uint256 before_ = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        uint256 sent = before_ - token.balanceOf(address(this));
        if (sent != amount) revert TransferMismatch(amount, sent);
    }

    /// @dev Calls the source with STATICCALL, a gas cap and a fixed 96-byte return buffer, so a reverting, garbage or
    ///      gas-bomb source cannot do more than make this answer `ok == false`.
    function _read(uint8 track, uint64 ts, uint256 hint)
        private
        view
        returns (bool ok, uint256 price, uint64 observedAt, PriceStatus status)
    {
        bytes memory data = abi.encodeCall(IQZPriceSource.priceAt, (track, ts, hint));
        address src = source;
        uint256 p;
        uint256 o;
        uint256 s;
        uint256 size;
        bool success;
        assembly ("memory-safe") {
            let out := mload(0x40)
            success := staticcall(300000, src, add(data, 32), mload(data), out, 96)
            size := returndatasize()
            p := mload(out)
            o := mload(add(out, 32))
            s := mload(add(out, 64))
        }
        if (!success || size < 96 || s > uint256(type(PriceStatus).max) || p > type(uint128).max || o > ts) {
            return (false, 0, 0, PriceStatus.Paused);
        }
        status = PriceStatus(s);
        if (status == PriceStatus.Ok && (p == 0 || o == 0)) return (false, 0, 0, PriceStatus.Paused);
        return (true, p, uint64(o), status);
    }

    /// @dev `(price - prev) * 10_000 / prev`, rounded toward zero and clamped to int32. Informational: the direction
    ///      comes from comparing the prices, so a move below 1 bp is 0 here and still Up or Down.
    function _moveBps(uint128 price, uint128 prev) private pure returns (int32) {
        int256 d = (int256(uint256(price)) - int256(uint256(prev))) * int256(BPS) / int256(uint256(prev));
        if (d > type(int32).max) return type(int32).max;
        if (d < type(int32).min) return type(int32).min;
        return int32(d);
    }
}
