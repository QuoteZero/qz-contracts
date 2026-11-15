// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";

/// @notice Errors shared by every QuoteZero contract.
interface IQZErrors {
    error ZeroAddress();
    error NotOwner(address caller);
    error NotPauser(address caller);
    error NotCore(address caller);
    error DeadlineExpired(uint256 deadline, uint256 nowTs);
    error Slippage(uint256 minOut, uint256 actualOut);
    error ZeroAmount();
    error EnforcedPause();
    error ExpectedPause();
}

/// @notice Pause scope (§4.2): hardwire, curve buys, outbound `send`, swaps through the hook, `convert`.
///         NEVER paused: sell to the curve, wallet-to-wallet transfers, `claim`, `claimCircuit`, inbound `lzReceive`.
///         Pausing has no power to move assets. Owner and pauser are the same single EOA (decision of 16 Nov, no Safe);
///         the pauser may be a different address on a given chain (role PAUSER, §4.2 table).
interface IQZPausable is IQZErrors {
    /// @dev `by` = caller.
    event Paused(address by);
    event Unpaused(address by);

    function paused() external view returns (bool);
    function pauser() external view returns (address);
    /// @notice Pauser only.
    function pause() external;
    /// @notice Pauser only (the single EOA; "guardian" of §4.2 is the same EOA and may only pause, but one EOA holds both).
    function unpause() external;
}

/// @notice `activate()` of the six OApp instances (I7, §4.2): reverts until `owner() == address(0)` and
///         `EndpointV2.delegates(this) == address(0)`; `send` reverts until activated. Callable by anyone, once.
interface IQZActivatable is IQZErrors {
    event Activated();

    error NotFrozen(address owner, address delegate);
    error NotActivated();
    error AlreadyActivated();

    function activated() external view returns (bool);
    function activate() external;
}

/// @notice Owner-only configuration surface of the four R2 OApps until the freeze procedure (§4.2): set peers and
///         enforced options, then `setDelegate(0)`, then `renounceOwnership()`. After that `activate()` is open to anyone.
interface IQZFreezable is IQZErrors {
    /// @notice Owner only; reverts once ownership is renounced. Enforced gas per path is in `QZConstants` (`GAS_*`).
    function setEnforcedOptions(EnforcedOptionParam[] calldata enforcedOptions) external;
    /// @notice Owner only. Irreversible: `owner()` becomes `address(0)`, which is the precondition of `activate()`.
    function renounceOwnership() external;
}
