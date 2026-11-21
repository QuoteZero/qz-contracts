// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZEntropy} from "../interfaces/IQZEntropy.sol";
import {QZConstants} from "../lib/QZConstants.sol";

/// @title QZEntropy
/// @notice The random seed of the machine reveal (SPEC Model B, B.4, B.6): a hash onion and nothing else. No owner, no
///         admin function; `onionRoot` and `revealer` are immutable.
///
/// Hash onion. `onionRoot = H^N(s)` with `H = keccak256` over one 32 byte word. Link `k` is `r_k = H^(N-k)(s)` and
///         `r_0 = onionRoot`, so `H(r_k) = r_(k-1)`. The revealer publishes links in order of increasing index. A call
///         `reveal(index, r)` is accepted when `index` is past the last accepted link, at most `MAX_REVEAL_GAP` ahead,
///         and hashing `r` forward `index - revealedIndex` times gives the last accepted link. The revealer can only
///         choose the moment, never a value: every link is fixed by `onionRoot` since deployment.
///
/// Seeds. `seedOf(k) = keccak256(abi.encode(r_k, k))`. A link the revealer skipped is not lost: `r_k` of a skipped
///         `k` is `H^(a - k)(r_a)` for the first accepted link `a >= k`, so `seedOf` derives it on the fly (at most
///         `MAX_REVEAL_GAP - 1` hashes). The seed of a link past `revealedIndex()` is zero.
contract QZEntropy is IQZEntropy {
    address public immutable override revealer;
    bytes32 public immutable override onionRoot;

    uint64 private _index;
    /// @dev Accepted link indices, strictly increasing. Link 0 (the root) is implicit.
    uint64[] private _anchors;
    mapping(uint64 index => bytes32 r) private _rOf;

    constructor(address revealer_, bytes32 onionRoot_) {
        if (revealer_ == address(0)) revert ZeroAddress();
        if (onionRoot_ == bytes32(0)) revert ZeroOnionRoot();
        revealer = revealer_;
        onionRoot = onionRoot_;
    }

    // ───────────── reveal ─────────────

    /// @inheritdoc IQZEntropy
    function reveal(uint64 index, bytes32 r) external {
        if (msg.sender != revealer) revert NotRevealer(msg.sender);
        uint64 current = _index;
        if (index <= current) revert IndexNotAhead(index, current);
        uint64 gap = index - current;
        if (gap > QZConstants.MAX_REVEAL_GAP) revert GapTooLarge(index, current, QZConstants.MAX_REVEAL_GAP);
        if (_hashN(r, gap) != _lastR(current)) revert BadReveal(index, r);

        _index = index;
        _anchors.push(index);
        _rOf[index] = r;
        emit OnionRevealed(index, _seed(r, index));
    }

    // ───────────── views ─────────────

    /// @inheritdoc IQZEntropy
    function seedOf(uint64 index) external view returns (bytes32) {
        if (index > _index) return bytes32(0);
        if (index == 0) return _seed(onionRoot, 0);

        uint64[] storage anchors = _anchors;
        uint256 lo;
        uint256 hi = anchors.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (anchors[mid] < index) lo = mid + 1;
            else hi = mid;
        }
        uint64 anchor = anchors[lo];
        return _seed(_hashN(_rOf[anchor], anchor - index), index);
    }

    /// @inheritdoc IQZEntropy
    function revealedIndex() external view returns (uint64) {
        return _index;
    }

    /// @inheritdoc IQZEntropy
    function lastRevealed() external view returns (uint64 index, bytes32 r) {
        index = _index;
        r = _lastR(index);
    }

    // ───────────── internals ─────────────

    function _lastR(uint64 index) private view returns (bytes32) {
        return index == 0 ? onionRoot : _rOf[index];
    }

    function _seed(bytes32 r, uint64 index) private pure returns (bytes32) {
        return keccak256(abi.encode(r, index));
    }

    /// @dev `H^times(x)`, hashed in the scratch space so memory does not grow.
    function _hashN(bytes32 x, uint256 times) private pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, times) { i := add(i, 1) } {
                mstore(0x00, x)
                x := keccak256(0x00, 0x20)
            }
        }
        return x;
    }
}
