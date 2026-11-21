// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZErrors} from "./IQZCommon.sol";

/// @title IQZEntropy
/// @notice The random seed of the machine reveal (SPEC Model B, B.4). A hash onion and nothing else: no queue, no
///         draws, no machine accounting.
///
///         `onionRoot = H^N(s)` with `H = keccak256` over one 32 byte word, fixed at deployment. The revealer publishes
///         links in order of decreasing depth: link `k` is `r_k = H^(N-k)(s)`, verified on chain by hashing it forward
///         until it meets the last accepted link (`r_0 = onionRoot`). The revealer can skip at most `MAX_REVEAL_GAP`
///         links in one call. It cannot choose a value, only the moment, so the seed of a link is fixed before anyone
///         asks for it.
///         `seedOf(k) = keccak256(abi.encode(r_k, k))`.
///         No owner and no admin function. `onionRoot` and `revealer` are immutable.
interface IQZEntropy is IQZErrors {
    // ───────────── events ─────────────

    /// @param index the onion link `k` that was accepted
    /// @param seed `seedOf(index)`
    event OnionRevealed(uint64 indexed index, bytes32 seed);

    // ───────────── errors ─────────────

    error NotRevealer(address caller);
    error ZeroOnionRoot();
    /// @notice `index` is not past the last accepted link.
    error IndexNotAhead(uint64 index, uint64 current);
    error GapTooLarge(uint64 index, uint64 current, uint64 maxGap);
    /// @notice `keccak256`-hashing `r` forward `index - current` times did not give the last accepted link.
    error BadReveal(uint64 index, bytes32 r);

    // ───────────── functions ─────────────

    /// @notice Revealer only. Accept link `index` (> `revealedIndex()`, at most `MAX_REVEAL_GAP` ahead).
    function reveal(uint64 index, bytes32 r) external;

    // ───────────── views ─────────────

    /// @notice The seed of link `index`; zero while `index > revealedIndex()`.
    function seedOf(uint64 index) external view returns (bytes32);
    /// @notice The last accepted link index, 0 before the first reveal.
    function revealedIndex() external view returns (uint64);
    /// @notice The last accepted link and its value; `(0, onionRoot)` before the first reveal.
    function lastRevealed() external view returns (uint64 index, bytes32 r);
    function onionRoot() external view returns (bytes32);
    function revealer() external view returns (address);
}
