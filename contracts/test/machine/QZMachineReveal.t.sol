// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZMachine} from "../../src/interfaces/IQZMachine.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MintPhase} from "../../src/lib/QZTypes.sol";
import {QZTraitsTable} from "../../src/machine/QZTraitsTable.sol";
import {QZOnion} from "../random/QZOnion.sol";
import {MachineFixture} from "./MachineFixture.sol";

/// @notice B1: finalize, the one-rotation reveal, trait lookup, transfers and metadata.
contract QZMachineRevealTest is MachineFixture {
    bytes32 internal constant BH = keccak256("a block hash");

    // ───────────── finalize ─────────────

    function test_finalizeBeforeTheEndReverts() public {
        _sellPublic(0, 3);
        vm.expectRevert(IQZMachine.CannotFinalizeYet.selector);
        machine.finalizeMint();
        _warpAfterPublic();
        vm.warp(block.timestamp - 1);
        vm.expectRevert(IQZMachine.CannotFinalizeYet.selector);
        machine.finalizeMint();
    }

    function test_finalizeAfterWindowClosesTheMint() public {
        _sellPublic(0, 3);
        _warpAfterPublic();
        vm.expectEmit(address(machine));
        emit IQZMachine.MintFinalized(3, 0, bytes32(0));
        _finalizeWith(BH);
        assertTrue(machine.mintFinalized());
        assertEq(uint8(machine.phase()), uint8(MintPhase.Closed));
        assertEq(machine.mintedCount(), 3);

        vm.expectRevert(IQZMachine.AlreadyFinalized.selector);
        machine.finalizeMint();

        _fund(nobody, PUBLIC_PRICE);
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.MintNotOpen.selector, MintPhase.Closed));
        machine.mint(_noProof());
    }

    function test_finalizeWithNoMintsStillWorks() public {
        _warpAfterPublic();
        _finalizeWith(BH);
        assertEq(machine.mintedCount(), 0);
    }

    function test_finalizeRecordsEntropyPosition() public {
        _revealLink(4);
        _sellPublic(0, 1);
        _warpAfterPublic();
        vm.expectEmit(address(machine));
        emit IQZMachine.MintFinalized(1, 4, bytes32(0));
        _finalizeWith(BH);
    }

    function test_finalizeIsNotPaused() public {
        _sellPublic(0, 1);
        _warpAfterPublic();
        vm.prank(pauser);
        machine.pause();
        _finalizeWith(BH);
        assertTrue(machine.mintFinalized());
    }

    // ───────────── reveal ─────────────

    function test_revealBeforeFinalizeReverts() public {
        _revealLink(1);
        vm.expectRevert(IQZMachine.NotFinalized.selector);
        machine.reveal();
    }

    function test_revealWaitsForALaterLink() public {
        _sellPublic(0, 2);
        _warpAfterPublic();
        _revealLink(3);
        _finalizeWith(BH); // recorded index 3
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.EntropyNotReady.selector, uint64(3), uint64(4)));
        machine.reveal();
        _revealLink(4);
        machine.reveal();
        assertTrue(machine.revealed());
    }

    function test_revealOffsetIsTheSpecFormula() public {
        _sellPublic(0, 5);
        _warpAfterPublic();
        _finalizeWith(BH);
        _revealLink(1);

        uint256 expected = _expectedOffset(1, BH);
        vm.expectEmit(address(machine));
        emit IQZMachine.Revealed(expected, QZOnion.seedOf(chain[1], 1));
        machine.reveal();
        assertEq(machine.revealOffset(), expected);
        assertTrue(machine.revealOffset() < 2222);
    }

    function test_revealUsesTheNextLinkEvenWhenTheRevealerJumpedAhead() public {
        _sellPublic(0, 5);
        _warpAfterPublic();
        _finalizeWith(BH);
        // the revealer skips ahead 40 links; the machine still reads the seed of link 1
        _revealLink(40);
        machine.reveal();
        assertEq(machine.revealOffset(), _expectedOffset(1, BH));
    }

    function test_revealIsPermissionlessAndOnce() public {
        _sellPublic(0, 2);
        _warpAfterPublic();
        _finalizeWith(BH);
        _revealLink(1);
        vm.prank(nobody);
        machine.reveal();
        vm.expectRevert(IQZMachine.AlreadyRevealed.selector);
        machine.reveal();
    }

    function test_revealIsNotPaused() public {
        _sellPublic(0, 2);
        _warpAfterPublic();
        vm.prank(pauser);
        machine.pause();
        _finalizeWith(BH);
        _revealLink(1);
        machine.reveal();
        assertTrue(machine.revealed());
    }

    function test_differentBlockHashGivesDifferentOffset() public {
        _sellPublic(0, 2);
        _warpAfterPublic();
        _finalizeWith(BH);
        _revealLink(1);
        uint256 a = _expectedOffset(1, BH);
        uint256 b = _expectedOffset(1, keccak256("another"));
        assertTrue(a != b);
    }

    // ───────────── traits ─────────────

    function test_traitsRevertBeforeReveal() public {
        _sellPublic(0, 2);
        vm.expectRevert(IQZMachine.NotRevealed.selector);
        machine.traitIdOf(1);
        vm.expectRevert(IQZMachine.NotRevealed.selector);
        machine.traitsOf(1);
        vm.expectRevert(IQZMachine.NotRevealed.selector);
        machine.revealOffset();
    }

    function test_traitLookupFollowsTheRotation() public {
        _sellPublic(0, 10);
        _revealAll(BH);
        uint256 off = machine.revealOffset();
        for (uint256 id = 1; id <= 10; ++id) {
            uint256 traitId = machine.traitIdOf(id);
            assertEq(traitId, (id - 1 + off) % 2222 + 1);
            uint8 packed = uint8(QZTraitsTable.TABLE[traitId - 1]);
            (uint8 tier, uint8 track, bool relic) = machine.traitsOf(id);
            assertEq(tier, packed >> 4);
            assertEq(track, packed & 0x0f);
            assertEq(relic, traitId >= QZConstants.FIRST_RELIC_ID);
        }
    }

    function test_traitsOfUnmintedIdsRevert() public {
        _sellPublic(0, 3);
        _revealAll(BH);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NonexistentMachine.selector, uint256(0)));
        machine.traitIdOf(0);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NonexistentMachine.selector, uint256(4)));
        machine.traitsOf(4);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NonexistentMachine.selector, uint256(2223)));
        machine.traitIdOf(2223);
    }

    function test_transferKeepsTheRevealMapping() public {
        _sellPublic(0, 4);
        _revealAll(BH);
        address a = address(uint160(0xA0000));
        uint256 traitBefore = machine.traitIdOf(1);
        (uint8 tier, uint8 track, bool relic) = machine.traitsOf(1);
        uint256 offset = machine.revealOffset();

        vm.prank(a);
        machine.transferFrom(a, nobody, 1);
        vm.prank(nobody);
        machine.transferFrom(nobody, gtd0, 1);

        assertEq(machine.ownerOf(1), gtd0);
        assertEq(machine.traitIdOf(1), traitBefore);
        (uint8 tier2, uint8 track2, bool relic2) = machine.traitsOf(1);
        assertEq(tier2, tier);
        assertEq(track2, track);
        assertEq(relic2, relic);
        assertEq(machine.revealOffset(), offset);
    }

    function test_transferBeforeRevealDoesNotChangeWhatRevealGives() public {
        _sellPublic(0, 2);
        address a = address(uint160(0xA0000));
        vm.prank(a);
        machine.transferFrom(a, nobody, 1);
        _revealAll(BH);
        assertEq(machine.traitIdOf(1), (machine.revealOffset()) % 2222 + 1);
    }

    // ───────────── metadata ─────────────

    function test_tokenUriIsBasePlusId() public {
        _sellPublic(0, 3);
        assertEq(machine.tokenURI(2), "");
        vm.expectEmit(address(machine));
        emit IQZMachine.BaseURISet("ipfs://cid/");
        vm.prank(owner);
        machine.setBaseURI("ipfs://cid/");
        assertEq(machine.tokenURI(2), "ipfs://cid/2");
        assertEq(machine.tokenURI(3), "ipfs://cid/3");
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NonexistentMachine.selector, uint256(4)));
        machine.tokenURI(4);
    }

    function test_baseUriOnlyOwner() public {
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotOwner.selector, nobody));
        machine.setBaseURI("x");
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotOwner.selector, nobody));
        machine.freezeMetadata();
    }

    function test_freezeNeedsReveal() public {
        vm.prank(owner);
        vm.expectRevert(IQZMachine.NotRevealed.selector);
        machine.freezeMetadata();
    }

    function test_freezeLocksTheBaseUri() public {
        _sellPublic(0, 1);
        _revealAll(BH);
        vm.startPrank(owner);
        machine.setBaseURI("ipfs://final/");
        vm.expectEmit(address(machine));
        emit IQZMachine.MetadataFrozen();
        machine.freezeMetadata();
        assertTrue(machine.metadataFrozen());
        vm.expectRevert(IQZMachine.MetadataAlreadyFrozen.selector);
        machine.setBaseURI("ipfs://other/");
        vm.expectRevert(IQZMachine.MetadataAlreadyFrozen.selector);
        machine.freezeMetadata();
        vm.stopPrank();
        assertEq(machine.tokenURI(1), "ipfs://final/1");
    }

    function test_noAdminSurfaceBeyondTheDocumentedOnes() public {
        // royalty cannot be set, prices and split cannot be changed, ownership cannot move
        bytes4[7] memory forbidden = [
            bytes4(keccak256("setPrice(uint256)")),
            bytes4(keccak256("setPrices(uint256,uint256,uint256)")),
            bytes4(keccak256("setSplit(uint256)")),
            bytes4(keccak256("setRoyalty(address,uint96)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("withdraw()")),
            bytes4(keccak256("setTreasury(address)"))
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(machine).call(abi.encodeWithSelector(forbidden[i]));
            assertFalse(ok);
        }
    }

    // ───────────── helpers ─────────────

    /// @dev Finalize with `bh` then reveal with link 1 (the first link after the recorded index 0).
    function _revealAll(bytes32 bh) internal {
        _warpAfterPublic();
        _finalizeWith(bh);
        _revealLink(1);
        machine.reveal();
    }
}
