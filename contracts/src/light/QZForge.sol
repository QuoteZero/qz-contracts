// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {QZConstants} from "../lib/QZConstants.sol";
import {IQZForge} from "../interfaces/IQZForge.sol";
import {IQZPausable} from "../interfaces/IQZCommon.sol";
import {IQZMachine} from "../interfaces/IQZMachine.sol";
import {IQZRewardVault} from "../interfaces/IQZRewardVault.sol";

/// @title QZForge
/// @notice Where a machine is lit (SPEC Model B, B.5). The holder of a revealed machine locks exactly
///         `LIGHT_AMOUNT` ($QZ, 18 decimals) here, once per machine and for good, and the machine is registered in
///         the reward vault in the same transaction.
///
///         The lock is final. The contract has no function that sends the token anywhere: no withdraw, no release,
///         no sweep or rescue, no arbitrary call, no delegatecall, no upgrade. `token`, `machine`, `vault` and
///         `lightingOpensAt` are immutable. `lockedPrincipal()` is `litCount() * LIGHT_AMOUNT`, computed from the
///         number of lit machines, never from the token balance, so QZ sent to this address directly is not counted
///         and does not change any state of the forge; it stays here too.
///
///         The lock belongs to the machine, not to the wallet that lit it. After a transfer the new owner holds a
///         lit machine, nothing moves in the forge, and the reward right follows the token in the vault.
///
///         Powers: the pauser can pause `light` and unpause it. That is all; nobody can change the amount, the token,
///         the vault or the opening time, and nobody can touch locked QZ. `owner` is informational (the team EOA).
///
///         Deployment: the vault stores this contract's address (`vault.forge()`) and this contract stores the vault's
///         (`vault()`), so one of the two addresses has to be computed before the other contract exists. The deploy
///         script computes the vault address from the deployer's nonce and `CheckDeploy` rejects a pair that does not
///         point at each other.
///
///         `light` checks, in order: not paused, lighting open, caller owns the machine, traits revealed, not
///         lit yet. It flips the machine to lit before it pulls the QZ (checks-effects-interactions) and also holds a
///         reentrancy lock, then verifies that the balance of the forge grew by exactly `LIGHT_AMOUNT` so a token that
///         takes a fee on transfer (or pays a bonus) makes the call revert instead of locking a different amount.
contract QZForge is IQZForge {
    using SafeERC20 for IERC20;

    /// @notice `lightingOpensAt` is zero, which would remove the head start the converter's first epoch relies on.
    error ZeroOpensAt();
    /// @notice A call into `light` while another `light` is running.
    error Reentrancy();

    // ───────────── immutables ─────────────

    address public immutable token;
    address public immutable machine;
    address public immutable vault;
    address public immutable owner;
    address public immutable pauser;
    uint64 public immutable lightingOpensAt;

    // ───────────── state ─────────────

    uint256 public litCount;
    bool public paused;
    mapping(uint256 machineId => bool) public isLit;
    uint256 private _entered;

    constructor(
        address token_,
        address machine_,
        address vault_,
        address owner_,
        address pauser_,
        uint64 lightingOpensAt_
    ) {
        if (
            token_ == address(0) || machine_ == address(0) || vault_ == address(0) || owner_ == address(0)
                || pauser_ == address(0)
        ) revert ZeroAddress();
        if (lightingOpensAt_ == 0) revert ZeroOpensAt();
        token = token_;
        machine = machine_;
        vault = vault_;
        owner = owner_;
        pauser = pauser_;
        lightingOpensAt = lightingOpensAt_;
    }

    // ───────────── light ─────────────

    /// @inheritdoc IQZForge
    function light(uint256 machineId) external {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;

        if (paused) revert EnforcedPause();
        if (block.timestamp < lightingOpensAt) revert LightingNotOpen(lightingOpensAt);
        if (IERC721(machine).ownerOf(machineId) != msg.sender) revert NotMachineOwner(machineId, msg.sender);
        if (!IQZMachine(machine).revealed()) revert NotRevealed();
        if (isLit[machineId]) revert AlreadyLit(machineId);

        isLit[machineId] = true;
        unchecked {
            ++litCount;
        }

        IERC20 qz = IERC20(token);
        uint256 before = qz.balanceOf(address(this));
        qz.safeTransferFrom(msg.sender, address(this), QZConstants.LIGHT_AMOUNT);
        uint256 received = qz.balanceOf(address(this)) - before;
        if (received != QZConstants.LIGHT_AMOUNT) revert LockAmountMismatch(QZConstants.LIGHT_AMOUNT, received);

        IQZRewardVault(vault).register(machineId);

        emit Lit(machineId, msg.sender);
        _entered = 0;
    }

    // ───────────── pause (light only) ─────────────

    /// @inheritdoc IQZPausable
    function pause() external {
        if (msg.sender != pauser) revert NotPauser(msg.sender);
        if (paused) revert EnforcedPause();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IQZPausable
    function unpause() external {
        if (msg.sender != pauser) revert NotPauser(msg.sender);
        if (!paused) revert ExpectedPause();
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ───────────── views ─────────────

    /// @inheritdoc IQZForge
    function lockedPrincipal() external view returns (uint256) {
        return litCount * QZConstants.LIGHT_AMOUNT;
    }

    /// @inheritdoc IQZForge
    function lightAmount() external pure returns (uint256) {
        return QZConstants.LIGHT_AMOUNT;
    }
}
