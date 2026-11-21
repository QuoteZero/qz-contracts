// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {QZMerkle} from "./QZMerkle.sol";

/// @notice Pins `QZMerkle` to the roots `@openzeppelin/merkle-tree` produces for `["address"]` leaves (the same three
///         vectors `apps/api/test/waitlist.test.ts` pins for the Season 0 export).
contract QZMerkleTest is Test {
    function test_rootsMatchStandardMerkleTree() public pure {
        address[] memory one = new address[](1);
        one[0] = address(0xa1);
        assertEq(QZMerkle.rootOf(one), 0xd7297f74554f60b569bd6b30021b4a14a22b05de10b2f8793aa2f1b95e101289);

        address[] memory three = new address[](3);
        three[0] = address(0xa1);
        three[1] = address(0xb2);
        three[2] = address(0xc3);
        assertEq(QZMerkle.rootOf(three), 0xbd5649f34918cb07e0ecddbce0c349e18fa31bc72a847ad7bbd3d7739944fa1a);

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = address(uint160(0x1111111111111111111111111111111111111111) * uint160(i + 1));
        }
        assertEq(QZMerkle.rootOf(five), 0xd21ca6424df344c7bdcd3d65c364ffa0cfbe7e04510d81fa57c175716da06376);
    }

    function test_rootIgnoresInputOrder() public pure {
        address[] memory a = new address[](4);
        address[] memory b = new address[](4);
        for (uint256 i; i < 4; ++i) {
            a[i] = address(uint160(0x1000 + i));
            b[3 - i] = a[i];
        }
        assertEq(QZMerkle.rootOf(a), QZMerkle.rootOf(b));
    }

    function test_everyLeafProvesAgainstOzMerkleProof() public pure {
        uint256 n = 37;
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = address(uint160(0xBEEF00 + i * 7919));
        }
        bytes32[] memory tree = QZMerkle.buildTree(list);
        for (uint256 i; i < n; ++i) {
            bytes32[] memory proof = QZMerkle.proofOf(tree, list[i]);
            assertTrue(MerkleProof.verify(proof, tree[0], QZMerkle.leafOf(list[i])));
        }
        // A wallet outside the list does not verify with someone else's proof.
        assertFalse(MerkleProof.verify(QZMerkle.proofOf(tree, list[0]), tree[0], QZMerkle.leafOf(address(0xdead))));
    }

    function test_largeListBuildsAndSorts() public pure {
        uint256 n = 600;
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = address(uint160(uint256(keccak256(abi.encode("w", i)))));
        }
        bytes32[] memory tree = QZMerkle.buildTree(list);
        assertEq(tree.length, 2 * n - 1);
        bytes32[] memory proof = QZMerkle.proofOf(tree, list[599]);
        assertTrue(MerkleProof.verify(proof, tree[0], QZMerkle.leafOf(list[599])));
    }

    function test_duplicateAddressReverts() public {
        address[] memory list = new address[](2);
        list[0] = address(0xa1);
        list[1] = address(0xa1);
        vm.expectRevert("QZMerkle: duplicate address");
        this.build(list);
    }

    function test_unknownAccountHasNoProof() public {
        address[] memory list = new address[](2);
        list[0] = address(0xa1);
        list[1] = address(0xb2);
        vm.expectRevert("QZMerkle: account not in tree");
        this.proofFor(list, address(0xc3));
    }

    function build(address[] memory l) external pure returns (bytes32) {
        return QZMerkle.rootOf(l);
    }

    function proofFor(address[] memory l, address a) external pure returns (bytes32[] memory) {
        return QZMerkle.proofOf(l, a);
    }
}
