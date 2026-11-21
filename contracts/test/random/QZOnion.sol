// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title QZOnion
/// @notice Test-side (and keeper-reference) construction of the QZEntropy hash onion and of its seeds.
///         `chain[0] = onionRoot = H^n(s)`, `chain[k] = r_k = H^(n-k)(s)` is link k, `chain[n] = s`.
library QZOnion {
    function hashOnce(bytes32 x) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(x));
    }

    /// @dev `H^times(x)`. Hashes in the scratch space, so memory does not grow and `times` can be the production N.
    function hashN(bytes32 x, uint256 times) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, times) { i := add(i, 1) } {
                mstore(0x00, x)
                x := keccak256(0x00, 0x20)
            }
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

    /// @dev `seedOf(index) = keccak256(abi.encode(r, index))`, two 32 byte words.
    function seedOf(bytes32 r, uint64 index) internal pure returns (bytes32) {
        return keccak256(abi.encode(r, index));
    }
}
