// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZErrors} from "./IQZCommon.sol";

/// @title IQZEntropy
/// @notice Commit-reveal machine draw (§4.3). `onionRoot = H^N(s)` is immutable. An epoch is a 2 minute window
///         (`epoch = timestamp / 120`). Tickets born in epoch e queue FIFO. After e closes the revealer calls
///         `reveal(e, r_e)` with `keccak256(r_e) == r_{e-1}`; `seed[e] = keccak256(r_e, e)`. `processQueue` assigns
///         `machineId = pool[keccak256(seed[e], ticketId, ticketNonce) % poolSize]` with swap-and-pop, FIFO, epoch by
///         epoch. A missing reveal after 1 hour rolls the whole queue to the next open epoch (`EpochRolled`).
///         Freeze rules (step 4): input is fixed at epoch close; a ticket dissolved before close leaves the queue; one
///         dissolved after keeps its slot and its machine returns to the pool via the per-epoch buffer
///         (`MachineReturned`); returns stamped in epoch > e wait in the buffer of their epoch.
interface IQZEntropy is IQZErrors {
    // ───────────── events (SPEC §5.1) ─────────────

    event EpochRevealed(uint64 indexed epoch, bytes32 seed);
    /// @notice The queue of `from` moved whole to `to` because `reveal(from)` did not arrive within 1 hour. Revealer alarm.
    event EpochRolled(uint64 indexed from, uint64 indexed to);
    /// @notice A revealed machine returned to the draw pool (its ticket dissolved), usable from `epoch`.
    event MachineReturned(uint256 indexed machineId, uint64 epoch);

    // ───────────── errors ─────────────

    error NotRevealer(address caller);
    error BadReveal(uint64 epoch, bytes32 r);
    error EpochNotClosed(uint64 epoch, uint64 currentEpoch);
    error EpochAlreadyRevealed(uint64 epoch);
    error EpochOutOfOrder(uint64 epoch, uint64 expected);
    error NothingToProcess();

    // ───────────── functions (SPEC §5.1) ─────────────

    /// @notice Revealer only. Epochs are revealed in order; `epoch` must be closed.
    function reveal(uint64 epoch, bytes32 r) external;

    /// @notice Anyone. Draw up to `max` queued tickets in FIFO order; returns how many were drawn. May be called in pieces.
    ///         Each draw calls `QZCore.onTicketRevealed`.
    function processQueue(uint256 max) external returns (uint256 processed);

    /// @notice `QZCore` only. A ticket was born; it joins the queue of the epoch open now.
    function enqueue(uint256 ticketId, uint64 nonce) external;

    /// @notice `QZCore` only. A ticket dissolved (freeze rules above; a revealed ticket's machine returns to the pool).
    function onDissolve(uint256 ticketId, uint64 nonce) external;

    function seedOf(uint64 epoch) external view returns (bytes32);
    /// @notice `block.timestamp / EPOCH_DURATION` (120 s).
    function currentEpoch() external view returns (uint64);
    /// @notice Tickets queued and not yet drawn.
    function pendingCount() external view returns (uint256);
    /// @notice Lowest epoch whose queue is not fully drawn.
    function nextEpochToProcess() external view returns (uint64);

    // extra views for UI and keeper
    function onionRoot() external view returns (bytes32);
    function revealer() external view returns (address);
    /// @notice Last revealed epoch and its `r`.
    function lastRevealed() external view returns (uint64 epoch, bytes32 r);
    function poolSize() external view returns (uint256);

    /// @notice True while a return merge stopped at its per-call budget: `processQueue` then draws nothing until
    ///         further calls finish the merge.
    function mergeInProgress() external view returns (bool);
    /// @notice Machine drawn for `(ticketId, nonce)`, 0 if not drawn yet.
    function machineOf(uint256 ticketId, uint64 nonce) external view returns (uint256);
    function core() external view returns (address);
}
