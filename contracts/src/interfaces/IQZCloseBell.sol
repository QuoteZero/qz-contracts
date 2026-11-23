// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZErrors} from "./IQZCommon.sol";

/// @notice The direction a lit machine calls for the close-to-close move of its ticker.
enum Direction {
    None, // 0: no call
    Up, // 1: close above the previous close
    Down // 2: close below the previous close
}

/// @notice Life of one (machine, session) call. `Open` holds the ante in the Bell; `Settled` burned it; `Refunded`
///         returned it to the payer. Both final states are terminal.
enum CallState {
    None,
    Open,
    Settled,
    Refunded
}

/// @notice What `snapshot` recorded for one (track, session). `Up` and `Down` are the only statuses that settle a call
///         as a win or a loss; the other three refund every call of the session.
enum CloseStatus {
    None, // 0: not snapshotted yet
    Up, // 1: the close is above the previous Ok close
    Down, // 2: the close is below the previous Ok close
    Closed, // 3: the source says the market was closed (or has no source): a void session
    Flat, // 4: the close equals the previous Ok close: a void session
    Expired // 5: snapshotted at or after `VOID_AFTER` without reading the source: a void session
}

/// @notice The outcome `Settled` reports.
enum Result {
    Win,
    Loss,
    Void
}

/// @notice Time constants fixed at deployment (testnet: minutes, mainnet: hours and days).
/// @param voidAfter seconds after a session's `closeTs` when an unsnapshotted call is refundable and a snapshot no
///        longer reads the source
/// @param claimDelay seconds after a season's last `closeTs` when season points freeze and the purse opens; at least
///        `voidAfter`
/// @param minLead minimum seconds between `createSeason` and the first `opensAt` (mainnet 48 h)
/// @param snapshotDelay seconds after `closeTs` before `snapshot` may run; at least 1 and below `voidAfter`
struct Profile {
    uint64 voidAfter;
    uint64 claimDelay;
    uint64 minLead;
    uint64 snapshotDelay;
}

/// @notice Times of one session. The call window is `[opensAt, cutoff)`; the close is read at `closeTs`.
struct SessionTimes {
    uint64 opensAt;
    uint64 cutoff;
    uint64 closeTs;
}

/// @title IQZCloseBell
/// @notice Closing Bell: a lit machine calls UP or DOWN on the close-to-close move of its own ticker before a cutoff,
///         pays an ante in $QZ that is burned to a dead address when the call settles (refunded when the session is
///         void), and builds a heat streak that follows the NFT. Nothing is wagered between players: antes never reach
///         a player. An optional USDG purse, funded only by the treasury or the sponsor fixed at deploy, is split
///         by season points after the season ends.
///
///         No pause, no owner, no upgrade, no withdrawal. The calendar address may only call `createSeason`.
interface IQZCloseBell is IQZErrors {
    // ───────────── events ─────────────

    event SeasonCreated(uint16 indexed season, uint32 firstSession, uint32 lastSession, uint128 ante);
    event Called(uint256 indexed id, uint32 indexed session, uint8 track, Direction dir, address payer);
    event BaselineSet(uint16 indexed season, uint8 indexed track, uint128 price);
    event Snapshotted(uint8 indexed track, uint32 indexed session, uint128 price, int32 moveBps, CloseStatus status);
    /// @param points points added to the season; 0 for a loss, a void or a settle at or after `claimOpensAt`
    /// @param streak the machine's streak after this settle
    event Settled(uint256 indexed id, uint32 indexed session, Result result, uint32 points, uint32 streak);
    event AnteBurned(uint256 indexed id, uint32 indexed session, uint256 amount);
    event AnteRefunded(uint256 indexed id, uint32 indexed session, address to, uint256 amount);
    event PurseFunded(uint16 indexed season, address indexed from, uint256 amount);
    event PurseClaimed(uint256 indexed id, uint16 indexed season, address to, uint256 amount);
    event PurseSwept(uint16 indexed season, uint256 amount);

    // ───────────── errors ─────────────

    error Reentrancy();
    error BadProfile();
    error NotCalendar(address caller);
    /// @notice `fundPurse` from an address that is neither the treasury nor the sponsor.
    error NotFunder(address caller);
    error SeasonExists(uint16 season);
    /// @notice A season id or first session that does not follow the last created one.
    error BadSeason();
    /// @notice A calendar that is empty, longer than `MAX_SESSIONS`, not strictly increasing or with a zero ante.
    error BadTimes();
    /// @notice The first `opensAt` is closer than `minLead`.
    error TooSoon(uint64 opensAt, uint64 earliest);
    error NoSession(uint32 session);
    error NoSeason(uint16 season);
    error BadTrack(uint8 track);
    error BadDirection();
    error NotLit(uint256 id);
    /// @notice A standard machine called a track that is not its own.
    error WrongTrack(uint8 expected, uint8 got);
    /// @notice The price source has no feed for the track (NFLX and RDDT on mainnet).
    error NotCallable(uint8 track);
    error WindowClosed(uint64 opensAt, uint64 cutoff);
    error AlreadyCalled(uint256 id, uint32 session);
    /// @notice The Bell's token balance did not move by exactly the amount.
    error TransferMismatch(uint256 expected, uint256 actual);
    /// @notice `snapshot` before `closeTs + snapshotDelay`, or a claim before `claimOpensAt`.
    error TooEarly(uint64 readyAt);
    /// @notice `snapshot` for a session that is not the next one of its track.
    error OutOfOrder(uint32 expected, uint32 got);
    /// @notice The source reverted, returned garbage or said `Paused`: nothing was recorded, retry until `VOID_AFTER`.
    error SourceUnavailable();
    /// @notice The first Ok close of a season needs `snapshotBaseline` first.
    error BaselineMissing(uint16 season, uint8 track);
    error BaselineAlreadySet(uint16 season, uint8 track);
    error NoCall(uint256 id, uint32 session);
    error AlreadySettled(uint256 id, uint32 session);
    /// @notice `settle` before the session's snapshot.
    error NotSettleable(uint256 id, uint32 session);
    /// @notice An Up or Down call settles after the machine's previous call is final.
    error PrevUnsettled(uint256 id, uint32 session, uint32 prev);
    /// @notice `voidExpired` before `closeTs + voidAfter`, or after a snapshot exists (then `settle` is the only path).
    error NotVoidable(uint256 id, uint32 session);
    error TooLate();
    error AlreadyClaimed(uint256 id, uint16 season);
    error NothingToClaim(uint256 id, uint16 season);
    error NothingToSweep(uint16 season);

    // ───────────── calendar ─────────────

    /// @notice Calendar only. Seasons and sessions are numbered from 1 with no gaps; a session's window opens no
    ///         earlier than the previous session's close; the first `opensAt` is at least `minLead` ahead and after
    ///         `baselineCloseTs` (the previous close the first session's move is measured from).
    function createSeason(
        uint16 season,
        uint32 firstSession,
        uint64 baselineCloseTs,
        uint128 ante,
        SessionTimes[] calldata times
    ) external;

    // ───────────── play ─────────────

    /// @notice Owner of a lit machine, inside the session window, once per (machine, session). Pulls the season ante
    ///         in $QZ (approve first). A standard machine calls its own track; a relic calls any callable track.
    function call(uint256 id, uint32 session, uint8 track, Direction dir) external;

    /// @notice Anyone, once per (season, track): records the price at the season's baseline close.
    function snapshotBaseline(uint16 season, uint8 track, uint256 hint) external;

    /// @notice Anyone, strictly in session order per track. Records the close, the move and the status. At or after
    ///         `closeTs + voidAfter` records `Expired` without reading the source.
    function snapshot(uint8 track, uint32 session, uint256 hint) external;

    /// @notice Anyone, once per call, after its snapshot. Burns the ante on Up or Down; refunds it to the payer on a
    ///         void session. Updates heat on Up or Down; adds season points while the season has not frozen.
    function settle(uint256 id, uint32 session) external;

    /// @notice Like `settle` for many machines of one session; entries that are not settleable now are skipped.
    function settleMany(uint256[] calldata ids, uint32 session) external returns (uint256 settled);

    /// @notice Anyone, for a call whose session has no snapshot at `closeTs + voidAfter`: refunds the ante to the payer
    ///         without reading the source. Reverts once any snapshot exists.
    function voidExpired(uint256 id, uint32 session) external;

    // ───────────── purse ─────────────

    /// @notice Treasury or sponsor only, before `claimOpensAt`. Pulls USDG into that season's purse.
    function fundPurse(uint16 season, uint256 amount) external;

    /// @notice Pays `purse * points / totalPoints` (rounded down) to `ownerOf(id)`, once per machine and season, from
    ///         `claimOpensAt` until 180 days later. Points and total are frozen at `claimOpensAt`.
    function claimPurse(uint256 id, uint16 season) external;

    /// @notice Anyone, 180 days after `claimOpensAt`: the unclaimed purse of the season returns to the treasury.
    function sweepPurse(uint16 season) external;

    // ───────────── views ─────────────

    function machine() external view returns (address);
    function forge() external view returns (address);
    function qz() external view returns (address);
    function usdg() external view returns (address);
    function source() external view returns (address);
    function calendar() external view returns (address);
    function treasury() external view returns (address);
    function sponsor() external view returns (address);
    function voidAfter() external view returns (uint64);
    function claimDelay() external view returns (uint64);
    function minLead() external view returns (uint64);
    function snapshotDelay() external view returns (uint64);

    /// @return firstSession first session number
    /// @return lastSession last session number
    /// @return baselineCloseTs the close the first session's move is measured from
    /// @return ante $QZ per call, 18 decimals
    /// @return claimOpensAt points freeze and the purse opens at this time
    /// @return exists whether the season was created
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
        );
    function sessionTimes(uint32 session) external view returns (uint64 opensAt, uint64 cutoff, uint64 closeTs, uint16 season);
    function sessionCount() external view returns (uint32);
    function seasonCount() external view returns (uint16);

    /// @return streak current win streak
    /// @return best best streak
    /// @return wins total wins
    /// @return losses total losses
    /// @return band 0 cold (streak 0), 1 warm (1 to 2), 2 hot (3 to 5), 3 blazing (6 or more)
    function heatOf(uint256 id)
        external
        view
        returns (uint32 streak, uint32 best, uint32 wins, uint32 losses, uint8 band);
    function callOf(uint256 id, uint32 session)
        external
        view
        returns (address payer, uint8 track, Direction dir, CallState state);
    function closeOf(uint8 track, uint32 session)
        external
        view
        returns (uint128 price, int32 moveBps, uint32 prevOkSession, CloseStatus status);
    function baselineOf(uint16 season, uint8 track) external view returns (uint128 price);
    function lastSnapshotted(uint8 track) external view returns (uint32);
    function seasonPoints(uint16 season, uint256 id) external view returns (uint32);
    function seasonTotalPoints(uint16 season) external view returns (uint64);
    function teamPoints(uint16 season, uint8 track) external view returns (uint64);
    /// @return funded USDG funded into the season's purse
    /// @return paidOut USDG claimed or swept out of it
    /// @return swept whether the remainder returned to the treasury
    function purseOf(uint16 season) external view returns (uint128 funded, uint128 paidOut, bool swept);
    function purseClaimed(uint16 season, uint256 id) external view returns (bool);
    function isCallable(uint8 track) external view returns (bool);
    /// @notice $QZ sent to the dead address by settled calls.
    function totalBurned() external view returns (uint256);
    /// @notice $QZ currently held as antes of open calls.
    function openAntes() external view returns (uint256);
    /// @notice $QZ returned to payers.
    function totalRefunded() external view returns (uint256);
    /// @notice $QZ ever pulled as antes.
    function totalAnteIn() external view returns (uint256);
}
