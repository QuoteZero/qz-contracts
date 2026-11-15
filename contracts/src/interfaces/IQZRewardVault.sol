// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZErrors} from "./IQZCommon.sol";

/// @title IQZRewardVault
/// @notice Stock-token reward accounting per machine and track (§2.5, I6). Per-weight accumulator `acc[t]` (scale
///         P = 1e36) with `debtP[id][t]` per machineId, not per owner: transferring a machine needs no callback.
///         Weights: tier I 10, II 15, III 25, IV 40; the 4 relics take 10% of every track's `notify` (2.5% each, unlit
///         slots fall to the standard machines) and draw from all ten tracks. Claim only at home:
///         `QZMachine.ownerOf(id) == msg.sender` (design B, §2.2), the adapter has no claim path.
///         `claim` is never paused and is isolated per track (a frozen stock reverts only its own track).
///         `claimFor` (compose-driven claim) is NOT in this release (§2.3 "tahap berikut").
interface IQZRewardVault is IQZErrors {
    // ───────────── events (SPEC §5.1) ─────────────

    /// @param accPerWeight `acc[track]` after the notify (scale 1e36)
    event RewardNotified(uint8 indexed track, uint256 amount, uint256 accPerWeight);
    /// @param to msg.sender (owner of the machine at claim time)
    /// @param amount stock raw units paid
    event Claimed(uint256 indexed id, uint8 indexed track, address indexed to, uint256 amount);
    /// @notice A track's stock reverted (paused, blocklisted, adminBurn): that track is frozen, others unaffected (T10).
    event TrackFrozen(uint8 indexed track, bytes reason);
    event TrackThawed(uint8 indexed track);

    // ───────────── errors ─────────────

    error NotConverter(address caller);
    error NotOwnerOfMachine(uint256 id, address caller);
    error LengthMismatch();
    error BadTrack(uint8 track);
    error TrackNotActive(uint8 track);
    error TrackFrozenError(uint8 track);
    error NothingToClaim(uint256 id, uint8 track);
    error AlreadyEnrolled(uint256 id);
    error Reentrancy();

    // ───────────── functions (SPEC §5.1) ─────────────

    /// @notice Claim `(ids[i], tracks[i])` pairs; caller must own every `ids[i]` at home. A relic claims each track in
    ///         its own pair. Pays `claimable(id, track)` of that track's stock to msg.sender; `debt` is updated before the
    ///         transfer (CEI + nonReentrant).
    function claim(uint256[] calldata ids, uint8[] calldata tracks) external;

    function claimable(uint256 id, uint8 track) external view returns (uint256);

    /// @notice `QZConverter` only, after the stock arrived. Reverts if `W[track] == 0` and R == 0.
    ///         Note: a track with no standard weight lit (`W[track] == 0`) stays ineligible for rewards even when relics
    ///         are lit; relics never make an empty track payable.
    function notify(uint8 track, uint256 amount) external;

    /// @notice `QZCore` only. Enrol the freshly minted machine (`W[t] += weight`, `debtP = weight * acc[t]`; relics:
    ///         `R += 1`, `relicStart[r][t] = relicAcc[t]` for all t).
    function onHardwire(uint256 id) external;

    // ───────────── views for UI / indexer ─────────────

    /// @notice `W[track]` total standard weight lit.
    function weightOf(uint8 track) external view returns (uint256);
    function relicCount() external view returns (uint256);
    function accPerWeight(uint8 track) external view returns (uint256);
    function relicAccPerUnit(uint8 track) external view returns (uint256);
    function stockOf(uint8 track) external view returns (address);
    function trackFrozen(uint8 track) external view returns (bool);
    /// @notice Total raw stock units notified / claimed per track.
    function totalNotified(uint8 track) external view returns (uint256);
    function totalClaimed(uint8 track) external view returns (uint256);
    function isEnrolled(uint256 id) external view returns (bool);
    function core() external view returns (address);
    function converter() external view returns (address);
    function machine() external view returns (address);
}
