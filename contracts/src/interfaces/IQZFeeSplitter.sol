// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZErrors} from "./IQZCommon.sol";

/// @title IQZFeeSplitter
/// @notice Receives the creator fee of the QZ launch and splits it 20:7 (SPEC Model B, B.3). It is the creator-fee
///         recipient the launch is created with, so the fee reaches it without any human step.
///
///         `harvest()` is permissionless. It calls the Pons sweep first when the launch allows it (SPEC B.5.4), then
///         claims the creator fee from the launch escrow, sends
///         `total * REWARD_PART / (REWARD_PART + TREASURY_PART)` (20/27, rounded down) to the converter as ETH, and the rest
///         (7/27 plus the rounding remainder) to the treasury. No dust stays in the contract, except a treasury share
///         whose push failed: that share is parked and only the treasury can pull it (`claimPendingTreasury`). The
///         ratio and both recipients are sealed: the owner calls `bind` once and nothing else; there is no admin
///         withdraw and no
///         path that hands the creator-fee role to another address. Anyone may call `harvest` at any time, so a
///         silent team cannot hold the fee back.
interface IQZFeeSplitter is IQZErrors {
    // ───────────── events ─────────────

    /// @notice Recipients were set (once).
    event Bound(address indexed converter, address indexed treasury);
    /// @param caller who triggered the harvest
    /// @param total the splitter's whole ETH balance after the claim (this call's claim plus any ETH sent to it since
    ///        the last harvest), less any treasury share parked for a pull (`pendingTreasury`)
    /// @param toConverter 20/27 of `total` rounded down, to the converter
    /// @param toTreasury the remainder, to the treasury
    event Harvested(address indexed caller, uint256 total, uint256 toConverter, uint256 toTreasury);
    /// @notice The treasury push failed (or ran out of its gas stipend) and the share was parked for a pull.
    event TreasuryShareParked(address indexed treasury, uint256 amount);
    /// @notice The treasury pulled its parked share to `to`.
    event TreasuryShareClaimed(address indexed to, uint256 amount);

    // ───────────── errors ─────────────

    error AlreadyBound();
    error NotBound();
    error NothingToHarvest();
    /// @notice An ETH transfer to a recipient failed.
    error TransferFailed(address to, uint256 amount);
    error Reentrancy();
    error NotTreasury(address caller);
    error NothingPending();

    // ───────────── functions ─────────────

    /// @notice Owner, once. Set where the reward share and the treasury share go.
    function bind(address converter, address treasury) external;

    /// @notice Anyone. Call the Pons sweep when allowed, claim the creator fee from the launch escrow, then split the
    ///         splitter's whole ETH balance (this call's claim plus any ETH sent to it since the last harvest), less
    ///         the treasury share still parked for a pull (`pendingTreasury`). Reverts with `NotBound` before `bind`
    ///         and with `NothingToHarvest` when there is nothing beyond that parked share.
    function harvest() external returns (uint256 toConverter, uint256 toTreasury);

    /// @notice Pull the treasury share parked by a harvest whose push to the treasury failed. Only the treasury can
    ///         call it; the ETH goes to `to` (so a treasury contract that cannot take a plain push can forward it).
    function claimPendingTreasury(address to) external returns (uint256 amount);

    // ───────────── views ─────────────

    function isBound() external view returns (bool);
    function converter() external view returns (address);
    function treasury() external view returns (address);
    function owner() external view returns (address);
    /// @notice 20.
    function REWARD_PART() external view returns (uint256);
    /// @notice 7.
    function TREASURY_PART() external view returns (uint256);
    /// @notice ETH ever delivered to the converter / the treasury. `totalToTreasury` counts a parked share only once
    ///         the treasury pulled it with `claimPendingTreasury`.
    function totalToConverter() external view returns (uint256);
    function totalToTreasury() external view returns (uint256);
    /// @notice The treasury share whose push failed, held in this contract until the treasury pulls it.
    function pendingTreasury() external view returns (uint256);
}
