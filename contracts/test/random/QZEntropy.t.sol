// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZEntropy} from "../../src/random/QZEntropy.sol";
import {IQZEntropy} from "../../src/interfaces/IQZEntropy.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {QZOnion} from "./QZOnion.sol";

/// @notice B2: the trimmed `QZEntropy`. Hash-onion verification and `seedOf`, nothing else.
contract QZEntropyTest is Test {
    uint256 internal constant N = 3_000;
    bytes32 internal constant S = keccak256("qz entropy onion");
    address internal constant REVEALER = address(0xBEEF);

    QZEntropy internal entropy;
    bytes32[] internal chain;

    function setUp() public {
        chain = QZOnion.build(S, N);
        entropy = new QZEntropy(REVEALER, chain[0]);
    }

    function _reveal(uint64 index) internal {
        vm.prank(REVEALER);
        entropy.reveal(index, chain[index]);
    }

    // ───────────── construction ─────────────

    function test_constructorStoresImmutables() public view {
        assertEq(entropy.revealer(), REVEALER);
        assertEq(entropy.onionRoot(), chain[0]);
        assertEq(entropy.revealedIndex(), 0);
        (uint64 index, bytes32 r) = entropy.lastRevealed();
        assertEq(index, 0);
        assertEq(r, chain[0]);
    }

    function test_constructorRejectsZeroes() public {
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZEntropy(address(0), chain[0]);
        vm.expectRevert(IQZEntropy.ZeroOnionRoot.selector);
        new QZEntropy(REVEALER, bytes32(0));
    }

    function test_noAdminSurface() public {
        bytes4[6] memory forbidden = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("setRevealer(address)")),
            bytes4(keccak256("setOnionRoot(bytes32)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("rotateOnion(bytes32)")),
            bytes4(keccak256("pause()"))
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool ok,) = address(entropy).call(abi.encodeWithSelector(forbidden[i]));
            assertFalse(ok);
        }
    }

    // ───────────── reveal ─────────────

    function test_firstRevealAdvancesOneLink() public {
        vm.expectEmit(address(entropy));
        emit IQZEntropy.OnionRevealed(1, QZOnion.seedOf(chain[1], 1));
        _reveal(1);
        assertEq(entropy.revealedIndex(), 1);
        (uint64 index, bytes32 r) = entropy.lastRevealed();
        assertEq(index, 1);
        assertEq(r, chain[1]);
        assertEq(entropy.seedOf(1), QZOnion.seedOf(chain[1], 1));
    }

    function test_revealOnlyByTheRevealer() public {
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.NotRevealer.selector, address(this)));
        entropy.reveal(1, chain[1]);
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.NotRevealer.selector, address(0xDEAD)));
        entropy.reveal(1, chain[1]);
    }

    function test_revealRejectsAWrongValue() public {
        vm.startPrank(REVEALER);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.BadReveal.selector, uint64(1), bytes32(uint256(1))));
        entropy.reveal(1, bytes32(uint256(1)));
        // a real link at the wrong index
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.BadReveal.selector, uint64(2), chain[1]));
        entropy.reveal(2, chain[1]);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.BadReveal.selector, uint64(1), chain[2]));
        entropy.reveal(1, chain[2]);
        // the root itself is not a later link
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.BadReveal.selector, uint64(1), chain[0]));
        entropy.reveal(1, chain[0]);
        // a link of another onion
        bytes32[] memory other = QZOnion.build(keccak256("other"), 5);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.BadReveal.selector, uint64(1), other[1]));
        entropy.reveal(1, other[1]);
        vm.stopPrank();
        assertEq(entropy.revealedIndex(), 0);
    }

    function test_revealRejectsStaleOrRepeatedIndex() public {
        _reveal(5);
        vm.startPrank(REVEALER);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.IndexNotAhead.selector, uint64(5), uint64(5)));
        entropy.reveal(5, chain[5]);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.IndexNotAhead.selector, uint64(4), uint64(5)));
        entropy.reveal(4, chain[4]);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.IndexNotAhead.selector, uint64(0), uint64(5)));
        entropy.reveal(0, chain[0]);
        vm.stopPrank();
        assertEq(entropy.revealedIndex(), 5);
    }

    function test_revealGapLimit() public {
        uint64 max = QZConstants.MAX_REVEAL_GAP;
        vm.startPrank(REVEALER);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.GapTooLarge.selector, max + 1, uint64(0), max));
        entropy.reveal(max + 1, chain[max + 1]);
        entropy.reveal(max, chain[max]); // exactly the limit passes
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.GapTooLarge.selector, 2 * max + 1, max, max));
        entropy.reveal(2 * max + 1, chain[2 * max + 1]);
        entropy.reveal(2 * max, chain[2 * max]);
        vm.stopPrank();
        assertEq(entropy.revealedIndex(), 2 * max);
    }

    function test_revealHugeIndexDoesNotOverflow() public {
        vm.prank(REVEALER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IQZEntropy.GapTooLarge.selector, type(uint64).max, uint64(0), QZConstants.MAX_REVEAL_GAP
            )
        );
        entropy.reveal(type(uint64).max, chain[1]);
    }

    function test_chainOfSingleStepsAndJumps() public {
        _reveal(1);
        _reveal(2);
        _reveal(40);
        _reveal(41);
        _reveal(1040);
        assertEq(entropy.revealedIndex(), 1040);
        for (uint64 k = 0; k <= 1040; ++k) {
            assertEq(entropy.seedOf(k), QZOnion.seedOf(chain[k], k), "seed");
        }
    }

    // ───────────── seedOf ─────────────

    function test_seedOfIndexZeroIsDefinedFromTheStart() public view {
        assertEq(entropy.seedOf(0), QZOnion.seedOf(chain[0], 0));
    }

    function test_seedOfAheadOfRevealedIsZero() public {
        assertEq(entropy.seedOf(1), bytes32(0));
        _reveal(3);
        assertTrue(entropy.seedOf(3) != bytes32(0));
        assertEq(entropy.seedOf(4), bytes32(0));
        assertEq(entropy.seedOf(type(uint64).max), bytes32(0));
    }

    function test_skippedLinkSeedsAreDerived() public {
        _reveal(7);
        for (uint64 k = 1; k <= 7; ++k) {
            assertEq(entropy.seedOf(k), QZOnion.seedOf(chain[k], k));
        }
        // seeds of different links differ
        assertTrue(entropy.seedOf(1) != entropy.seedOf(2));
    }

    function test_skippedSeedDoesNotChangeWhenLaterLinksArrive() public {
        _reveal(10);
        bytes32 before = entropy.seedOf(4);
        _reveal(500);
        assertEq(entropy.seedOf(4), before);
        assertEq(entropy.seedOf(4), QZOnion.seedOf(chain[4], 4));
    }

    function test_worstCaseDerivationGas() public {
        uint64 max = QZConstants.MAX_REVEAL_GAP;
        _reveal(max);
        uint256 g = gasleft();
        entropy.seedOf(1);
        uint256 used = g - gasleft();
        emit log_named_uint("gas of seedOf over a full gap", used);
        assertLt(used, 120_000);
    }

    // ───────────── fuzz ─────────────

    /// @notice Any sequence of in-range jumps yields exactly the onion's seeds for every index up to the last one,
    ///         zero above, and `lastRevealed` returns the last link.
    function testFuzz_anySequenceOfJumps(uint16[8] memory raw) public {
        uint64 index;
        for (uint256 i; i < 8; ++i) {
            uint64 gap = uint64(bound(raw[i], 1, QZConstants.MAX_REVEAL_GAP));
            if (uint256(index) + gap >= N) break;
            index += gap;
            _reveal(index);
        }
        assertEq(entropy.revealedIndex(), index);
        (uint64 last, bytes32 r) = entropy.lastRevealed();
        assertEq(last, index);
        assertEq(r, chain[index]);
        // a spread of indices, including both ends
        for (uint64 k = 0; k <= index; k += (index / 17) + 1) {
            assertEq(entropy.seedOf(k), QZOnion.seedOf(chain[k], k));
        }
        assertEq(entropy.seedOf(index), QZOnion.seedOf(chain[index], index));
        assertEq(entropy.seedOf(index + 1), bytes32(0));
    }

    /// @notice No value other than the true link is accepted at an index.
    function testFuzz_onlyTheTrueLinkIsAccepted(bytes32 r, uint16 gap) public {
        uint64 index = uint64(bound(gap, 1, QZConstants.MAX_REVEAL_GAP));
        vm.assume(r != chain[index]);
        vm.prank(REVEALER);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.BadReveal.selector, index, r));
        entropy.reveal(index, r);
    }

    /// @notice A different onion root never accepts a link of this onion.
    function testFuzz_foreignRootRejectsOurLinks(bytes32 root, uint16 gap) public {
        vm.assume(root != chain[0] && root != bytes32(0));
        QZEntropy e = new QZEntropy(REVEALER, root);
        uint64 index = uint64(bound(gap, 1, QZConstants.MAX_REVEAL_GAP));
        vm.prank(REVEALER);
        vm.expectRevert(abi.encodeWithSelector(IQZEntropy.BadReveal.selector, index, chain[index]));
        e.reveal(index, chain[index]);
    }
}
