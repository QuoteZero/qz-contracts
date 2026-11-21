// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QZMachine} from "../../src/machine/QZMachine.sol";
import {IQZMachine} from "../../src/interfaces/IQZMachine.sol";
import {QZOnion} from "../random/QZOnion.sol";
import {MachineFixture} from "./MachineFixture.sol";

/// @notice The reveal reads a hash locked once from `blockhash(F + 1)` (`F` = block of `finalizeMint`): unknown when
///         the finalize transaction is built, and fixed for good by `lockHash`. Withholding the entropy link buys no
///         redraw. Window edges, re-arm of a window nobody used, and the timeout without the link.
contract QZMachineRevealWindowTest is MachineFixture {
    bytes32 internal constant BH = keccak256("block F+1");

    /// @dev Sell 3, close the mint and finalize at index 0 in block `F`.
    function _finalizeAtF() internal returns (uint256 f) {
        _sellPublic(0, 3);
        _warpAfterPublic();
        machine.finalizeMint();
        f = vm.getBlockNumber();
    }

    /// @dev Move to block `n`; make `blockhash(f + 1)` readable as `h` if it still is.
    function _at(uint256 n, uint256 f, bytes32 h) internal {
        vm.roll(n);
        if (n > f + 1 && n - (f + 1) <= 256) vm.setBlockhash(f + 1, h);
    }

    // ───────────── grinding ─────────────

    /// @notice What a finalizer or onion holder can compute when it builds the finalize transaction: the seed and
    ///         `blockhash(block.number - 1)`. The offset the contract produces does not use that hash.
    function test_offsetIsNotTheOneComputableAtFinalizeTime() public {
        uint256 f = _finalizeAtF();
        bytes32 knownAtSend = blockhash(f - 1);
        uint256 guess = uint256(keccak256(abi.encode(QZOnion.seedOf(chain[1], 1), knownAtSend))) % MAX;

        _at(f + 2, f, BH);
        machine.lockHash();
        _revealLink(1);
        machine.reveal();
        assertEq(machine.revealOffset(), _expectedOffset(1, BH));
        assertTrue(machine.revealOffset() != guess, "offset differs from the pre-computed one");
    }

    /// @notice Whatever the hashes of the blocks up to and including `F` are, the offset depends on `blockhash(F + 1)`
    ///         only.
    function testFuzz_offsetOnlyDependsOnTheNextBlockHash(bytes32 beforeHash, bytes32 atF, bytes32 next) public {
        next = next == bytes32(0) ? BH : next;
        uint256 f = _finalizeAtF();
        vm.roll(f + 2);
        vm.setBlockhash(f, atF);
        vm.setBlockhash(f - 1, beforeHash);
        vm.setBlockhash(f + 1, next);
        machine.lockHash();
        _revealLink(1);
        machine.reveal();
        assertEq(machine.revealOffset(), _expectedOffset(1, next));
    }

    /// @notice Two different `F + 1` hashes give (almost surely) different offsets.
    function test_theNextBlockHashSteersTheOffset() public {
        uint256 a = _expectedOffset(1, keccak256("h1"));
        uint256 b = _expectedOffset(1, keccak256("h2"));
        uint256 c = _expectedOffset(1, keccak256("h3"));
        assertTrue(a != b || b != c);
    }

    /// @notice Regression of the redraw case: the onion holder reads the outcome from the public block hash at
    ///         `F + 2`, dislikes it, withholds link `i + 1` and tries to draw again. Anyone locks the hash first, and
    ///         once it is locked nothing re-arms, so the draw that follows the lock is the draw.
    function test_withholdingTheLinkCannotBuyARedraw() public {
        _sellPublic(0, 40); // the attacker's wallets hold ids 1..40
        _warpAfterPublic();
        machine.finalizeMint();
        uint256 f = vm.getBlockNumber();
        bytes32 seed = QZOnion.seedOf(chain[1], 1); // known in advance to the onion holder only

        _at(f + 2, f, keccak256("hash of the last block of F+1"));
        uint256 expected = uint256(keccak256(abi.encode(seed, blockhash(f + 1)))) % MAX; // the attacker's preview
        vm.prank(nobody); // anybody, here an honest keeper
        machine.lockHash();
        assertEq(machine.lockedHash(), blockhash(f + 1));

        // withheld link: reveal fails, and every way to redraw fails
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.EntropyNotReady.selector, uint64(0), uint64(1)));
        machine.reveal();
        vm.roll(f + 258);
        vm.expectRevert(IQZMachine.HashAlreadyLocked.selector);
        machine.rearmReveal();
        vm.expectRevert(IQZMachine.HashAlreadyLocked.selector);
        machine.lockHash();
        vm.roll(f + 100_000);
        vm.expectRevert(IQZMachine.HashAlreadyLocked.selector);
        machine.rearmReveal();

        // when the link finally comes, the outcome is the one the attacker saw at F + 2
        _revealLink(1);
        machine.reveal();
        assertEq(machine.revealOffset(), expected);
    }

    /// @notice A revealer that gets both: whether the hash is locked is not its choice (anyone locks), so it cannot
    ///         let the window lapse by itself while a keeper is awake.
    function test_anyoneCanLockAndTheRevealerIsNotNeeded() public {
        uint256 f = _finalizeAtF();
        _at(f + 2, f, BH);
        vm.prank(nobody);
        machine.lockHash();
        assertTrue(machine.hashLocked());
        assertEq(machine.lockedAt(), vm.getBlockTimestamp());
    }

    // ───────────── window edges ─────────────

    function test_lockTooEarly() public {
        uint256 f = _finalizeAtF();
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.RevealTooEarly.selector, f + 2));
        machine.lockHash(); // same block as the finalize
        vm.roll(f + 1);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.RevealTooEarly.selector, f + 2));
        machine.lockHash(); // blockhash(F + 1) is not final yet
        vm.roll(f + 2);
        vm.setBlockhash(f + 1, BH);
        machine.lockHash();
        assertTrue(machine.hashLocked());
    }

    function test_windowEnds256BlocksAfterTheHashedBlock() public {
        uint256 f = _finalizeAtF();
        uint256 snap = vm.snapshotState();
        _at(f + 257, f, BH);
        machine.lockHash();
        assertEq(machine.lockedHash(), BH);
        vm.revertToState(snap);
        _at(f + 258, f, BH);
        vm.expectRevert(IQZMachine.RevealWindowMissed.selector);
        machine.lockHash();
        assertFalse(machine.hashLocked());
    }

    function test_zeroBlockHashIsRefused() public {
        uint256 f = _finalizeAtF();
        _at(f + 2, f, bytes32(0));
        vm.expectRevert(IQZMachine.ZeroBlockHash.selector);
        machine.lockHash();
    }

    function test_revealBeforeLockReverts() public {
        uint256 f = _finalizeAtF();
        _revealLink(1);
        vm.expectRevert(IQZMachine.HashNotLocked.selector);
        machine.reveal();
        _at(f + 2, f, BH);
        vm.expectRevert(IQZMachine.HashNotLocked.selector);
        machine.reveal();
    }

    function test_lockAndRearmBeforeFinalizeRevert() public {
        vm.expectRevert(IQZMachine.NotFinalized.selector);
        machine.lockHash();
        vm.expectRevert(IQZMachine.NotFinalized.selector);
        machine.rearmReveal();
        vm.expectRevert(IQZMachine.NotFinalized.selector);
        machine.reveal();
    }

    // ───────────── re-arm: a window nobody locked ─────────────

    function test_unusedWindowIsRearmedByAnyoneAndGetsAFreshHash() public {
        uint256 f = _finalizeAtF();
        _at(f + 258, f, keccak256("stale"));
        vm.expectRevert(IQZMachine.RevealWindowMissed.selector);
        machine.lockHash();

        vm.expectEmit(address(machine));
        emit IQZMachine.RevealRearmed(f + 258);
        vm.prank(nobody);
        machine.rearmReveal();
        assertEq(machine.finalizeBlock(), f + 258);

        vm.expectRevert(abi.encodeWithSelector(IQZMachine.RevealTooEarly.selector, f + 260));
        machine.lockHash();
        vm.roll(f + 260);
        vm.setBlockhash(f + 259, BH);
        machine.lockHash();
        _revealLink(1);
        machine.reveal();
        assertEq(machine.revealOffset(), _expectedOffset(1, BH));
    }

    function test_rearmOnlyAfterTheWindowHasPassed() public {
        uint256 f = _finalizeAtF();
        vm.expectRevert(IQZMachine.RevealWindowOpen.selector);
        machine.rearmReveal();
        vm.roll(f + 257);
        vm.expectRevert(IQZMachine.RevealWindowOpen.selector);
        machine.rearmReveal();
        vm.roll(f + 258);
        machine.rearmReveal();
        vm.expectRevert(IQZMachine.RevealWindowOpen.selector); // and not again right away
        machine.rearmReveal();
    }

    function test_rearmAfterRevealReverts() public {
        uint256 f = _finalizeAtF();
        _at(f + 2, f, BH);
        machine.lockHash();
        _revealLink(1);
        machine.reveal();
        vm.roll(f + 1000);
        vm.expectRevert(IQZMachine.HashAlreadyLocked.selector);
        machine.rearmReveal();
    }

    function test_rearmCanRepeatAndLockStillWorks() public {
        uint256 f = _finalizeAtF();
        vm.roll(f + 300);
        machine.rearmReveal();
        vm.roll(f + 700);
        machine.rearmReveal();
        vm.roll(f + 702);
        vm.setBlockhash(f + 701, BH);
        machine.lockHash();
        _revealLink(1);
        machine.reveal();
        assertEq(machine.revealOffset(), _expectedOffset(1, BH));
    }

    function test_lockAndRearmAreNotPaused() public {
        uint256 f = _finalizeAtF();
        vm.prank(pauser);
        machine.pause();
        vm.roll(f + 258);
        machine.rearmReveal();
        vm.roll(f + 260);
        vm.setBlockhash(f + 259, BH);
        machine.lockHash();
    }

    // ───────────── timeout without the link ─────────────

    function test_revealWithoutTheLinkOnlyAfterTheTimeout() public {
        uint256 f = _finalizeAtF();
        _at(f + 2, f, BH);
        machine.lockHash();
        uint256 lockedAt = vm.getBlockTimestamp();

        vm.expectRevert(abi.encodeWithSelector(IQZMachine.EntropyNotReady.selector, uint64(0), uint64(1)));
        machine.reveal();
        vm.warp(lockedAt + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.EntropyNotReady.selector, uint64(0), uint64(1)));
        machine.reveal();

        vm.warp(lockedAt + 7 days);
        vm.prank(nobody);
        machine.reveal();
        assertEq(machine.revealOffset(), uint256(keccak256(abi.encode(bytes32(0), BH))) % MAX);
        assertTrue(machine.revealed());
    }

    function test_timeoutEmitsSeedZeroAndLaterLinkIsIgnored() public {
        uint256 f = _finalizeAtF();
        _at(f + 2, f, BH);
        machine.lockHash();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectEmit(address(machine));
        emit IQZMachine.Revealed(uint256(keccak256(abi.encode(bytes32(0), BH))) % MAX, bytes32(0));
        machine.reveal();
        _revealLink(1); // too late: the machine is already revealed
        vm.expectRevert(IQZMachine.AlreadyRevealed.selector);
        machine.reveal();
    }

    /// @notice After the timeout the link still wins when it is there: the real seed is used, not zero.
    function test_linkPublishedBeforeTheTimeoutCallIsUsed() public {
        uint256 f = _finalizeAtF();
        _at(f + 2, f, BH);
        machine.lockHash();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _revealLink(1);
        machine.reveal();
        assertEq(machine.revealOffset(), _expectedOffset(1, BH));
    }

    /// @notice The bijection holds for any offset reached through a re-arm or the timeout.
    function testFuzz_rotationStaysInjectiveAfterRearmAndTimeout(bytes32 hash, uint16 extra, bool timeout) public {
        hash = hash == bytes32(0) ? BH : hash;
        uint256 f = _finalizeAtF();
        vm.roll(f + 258 + bound(extra, 0, 5_000));
        machine.rearmReveal();
        uint256 g = vm.getBlockNumber();
        vm.roll(g + 2);
        vm.setBlockhash(g + 1, hash);
        machine.lockHash();
        uint256 expected;
        if (timeout) {
            vm.warp(vm.getBlockTimestamp() + 7 days);
            expected = uint256(keccak256(abi.encode(bytes32(0), hash))) % MAX;
        } else {
            _revealLink(1);
            expected = _expectedOffset(1, hash);
        }
        machine.reveal();
        assertEq(machine.revealOffset(), expected);
        bool[] memory seen = new bool[](MAX + 1);
        for (uint256 id = 1; id <= 3; ++id) {
            uint256 t = machine.traitIdOf(id);
            assertTrue(t >= 1 && t <= MAX);
            assertFalse(seen[t]);
            seen[t] = true;
        }
    }
}
