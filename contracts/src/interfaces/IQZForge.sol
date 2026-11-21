// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZPausable} from "./IQZCommon.sol";

/// @title IQZForge
/// @notice Where a machine is lit (SPEC Model B, B.5). The holder of a revealed machine locks exactly `LIGHT_AMOUNT`
///         (N = 100,000 QZ) here, once per machine, and the machine starts earning from the reward vault.
///
///         The lock is final: there is no withdraw, no release, no sweep, no owner call that moves QZ. `lockedPrincipal`
///         only goes up. A machine is lit once; after a transfer the new owner holds the lit machine, the lock stays
///         with the machine, and the reward rights follow the token. `light` pulls the QZ with `transferFrom` (the
///         caller approves `LIGHT_AMOUNT` first), checks the exact amount arrived, and registers the machine in the
///         reward vault in the same transaction.
///
///         Only `light` can be paused (by the pauser). Nothing else here can be switched off or changed.
interface IQZForge is IQZPausable {
    // ───────────── events ─────────────

    /// @notice `owner` locked `LIGHT_AMOUNT` QZ and lit `machineId`.
    event Lit(uint256 indexed machineId, address indexed owner);

    // ───────────── errors ─────────────

    /// @notice `light` before `lightingOpensAt()`.
    error LightingNotOpen(uint64 opensAt);
    error NotMachineOwner(uint256 machineId, address caller);
    /// @notice The machine's traits are not revealed yet.
    error NotRevealed();
    error AlreadyLit(uint256 machineId);
    /// @notice The QZ balance of the forge did not grow by exactly `LIGHT_AMOUNT`.
    error LockAmountMismatch(uint256 expected, uint256 received);

    // ───────────── functions ─────────────

    /// @notice Lock `LIGHT_AMOUNT` QZ and light `machineId`. Caller must be `ownerOf(machineId)`; the machine must be
    ///         revealed and not lit. Reverts when paused or before `lightingOpensAt()`. Calls `QZRewardVault.register`.
    function light(uint256 machineId) external;

    // ───────────── views ─────────────

    /// @notice Number of lit machines.
    function litCount() external view returns (uint256);
    function isLit(uint256 machineId) external view returns (bool);
    /// @notice QZ locked in total, always `litCount() * LIGHT_AMOUNT`.
    function lockedPrincipal() external view returns (uint256);
    /// @notice N, 100,000 QZ with 18 decimals.
    function lightAmount() external view returns (uint256);
    /// @notice The first moment `light` is allowed.
    function lightingOpensAt() external view returns (uint64);
    /// @notice The QZ token that is locked.
    function token() external view returns (address);
    function machine() external view returns (address);
    function vault() external view returns (address);
    function owner() external view returns (address);
}
