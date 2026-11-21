// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title QZMerkle
/// @notice Test helper: the allow-list tree of the Season 0 export, built from plain addresses.
///         Same tree as StandardMerkleTree.of(addresses.map((a) => [a]), ["address"]) of
///         the OpenZeppelin merkle-tree package: leaf = `keccak256(bytes.concat(keccak256(abi.encode(address))))`, leaves
///         sorted by hash, commutative pair hash, heap layout (root at 0, children of `i` at `2i + 1` and `2i + 2`,
///         the smallest leaf last). The roots of the three address sets in `QZMerkle.t.sol` are pinned from the
///         JavaScript library, so this file cannot drift from the export without a red test.
///         Inputs must be unique addresses (the export de-duplicates); a duplicate reverts.
library QZMerkle {
    function leafOf(address account) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account))));
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @notice The whole heap-layout tree, `2n - 1` nodes.
    function buildTree(address[] memory accounts) internal pure returns (bytes32[] memory tree) {
        uint256 n = accounts.length;
        require(n != 0, "QZMerkle: empty tree");
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = leafOf(accounts[i]);
        }
        leaves = _sorted(leaves);
        for (uint256 i = 1; i < n; ++i) {
            require(leaves[i - 1] != leaves[i], "QZMerkle: duplicate address");
        }
        tree = new bytes32[](2 * n - 1);
        for (uint256 i; i < n; ++i) {
            tree[tree.length - 1 - i] = leaves[i];
        }
        for (uint256 i = tree.length - n; i > 0; --i) {
            tree[i - 1] = hashPair(tree[2 * (i - 1) + 1], tree[2 * (i - 1) + 2]);
        }
    }

    function rootOf(address[] memory accounts) internal pure returns (bytes32) {
        return buildTree(accounts)[0];
    }

    /// @notice The proof of `account` in `tree`; reverts when the account is not a leaf.
    function proofOf(bytes32[] memory tree, address account) internal pure returns (bytes32[] memory proof) {
        bytes32 leaf = leafOf(account);
        uint256 idx = type(uint256).max;
        for (uint256 i = tree.length; i > 0; --i) {
            if (tree[i - 1] == leaf) {
                idx = i - 1;
                break;
            }
        }
        require(idx != type(uint256).max, "QZMerkle: account not in tree");
        bytes32[] memory tmp = new bytes32[](tree.length);
        uint256 len;
        while (idx > 0) {
            tmp[len++] = tree[idx % 2 == 1 ? idx + 1 : idx - 1];
            idx = (idx - 1) / 2;
        }
        proof = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            proof[i] = tmp[i];
        }
    }

    function proofOf(address[] memory accounts, address account) internal pure returns (bytes32[] memory) {
        return proofOf(buildTree(accounts), account);
    }

    /// @dev Bottom-up merge sort, ascending. Returns the sorted array (it may be the scratch array).
    function _sorted(bytes32[] memory a) private pure returns (bytes32[] memory) {
        uint256 n = a.length;
        bytes32[] memory b = new bytes32[](n);
        for (uint256 width = 1; width < n; width *= 2) {
            for (uint256 lo; lo < n; lo += 2 * width) {
                uint256 mid = lo + width < n ? lo + width : n;
                uint256 hi = lo + 2 * width < n ? lo + 2 * width : n;
                uint256 i = lo;
                uint256 j = mid;
                for (uint256 k = lo; k < hi; ++k) {
                    if (i < mid && (j >= hi || a[i] <= a[j])) b[k] = a[i++];
                    else b[k] = a[j++];
                }
            }
            (a, b) = (b, a);
        }
        return a;
    }
}
