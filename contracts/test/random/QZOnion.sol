// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title QZOnion
/// @notice Test-side (and keeper-reference) construction of the QZEntropy hash onion and of the draw formulas.
///         `chain[0] = onionRoot = H^n(s)`, `chain[k] = r_k = H^(n-k)(s)` is the value revealed k-th, `chain[n] = s`.
library QZOnion {
    function hashOnce(bytes32 x) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(x));
    }

    /// @dev `H^times(x)`.
    function hashN(bytes32 x, uint256 times) internal pure returns (bytes32) {
        for (uint256 i; i < times; ++i) {
            x = keccak256(abi.encodePacked(x));
        }
        return x;
    }

    function root(bytes32 s, uint256 n) internal pure returns (bytes32) {
        return hashN(s, n);
    }

    /// @dev The whole onion, `n + 1` entries.
    function build(bytes32 s, uint256 n) internal pure returns (bytes32[] memory chain) {
        chain = new bytes32[](n + 1);
        chain[n] = s;
        for (uint256 k = n; k > 0; --k) {
            chain[k - 1] = keccak256(abi.encodePacked(chain[k]));
        }
    }

    /// @dev `seed[e] = keccak256(r_e, e)` as two 32 byte words.
    function seedOf(bytes32 r, uint64 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(r, epoch));
    }
}

/// @title QZModel
/// @notice Reference model of the draw pool (virtual array, swap-and-pop) used to predict machine ids in tests.
library QZModel {
    struct Pool {
        uint16[] a;
        uint256 size;
    }

    function fresh(uint256 total) internal pure returns (Pool memory p) {
        p.a = new uint16[](total + 16);
        for (uint256 i; i < total; ++i) {
            p.a[i] = uint16(i + 1);
        }
        p.size = total;
    }

    /// @dev `machineId = pool[keccak256(seed, ticketId, nonce) % size]`, then swap-and-pop.
    function pick(Pool memory p, bytes32 seed, uint256 ticketId, uint64 nonce) internal pure returns (uint16 m) {
        uint256 i = uint256(keccak256(abi.encode(seed, ticketId, nonce))) % p.size;
        m = p.a[i];
        p.a[i] = p.a[p.size - 1];
        --p.size;
    }

    function push(Pool memory p, uint16 m) internal pure {
        p.a[p.size++] = m;
    }
}
