// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZMachine} from "../../src/interfaces/IQZMachine.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MintPhase} from "../../src/lib/QZTypes.sol";
import {MachineFixture} from "./MachineFixture.sol";

/// @notice B1 at the supply cap and the reveal fuzz. `setUp` sells all 2222 machines once; fuzz runs start from that
///         state.
contract QZMachineSoldOutTest is MachineFixture {
    function setUp() public override {
        super.setUp();
        _sellPublic(0, MAX);
    }

    function test_supplyCapStopsTheMint() public {
        assertEq(machine.mintedCount(), 2222);
        assertEq(machine.totalSupply(), 2222);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Closed));
        _fund(nobody, PUBLIC_PRICE);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.SoldOut.selector);
        machine.mint(_noProof());
        vm.expectRevert(IQZMachine.SoldOut.selector);
        machine.priceOf(nobody, _noProof());
        assertEq(machine.mintedCount(), 2222);
        assertEq(usdg.balanceOf(address(machine)), 0);
    }

    function test_soldOutMintMovedExactlyTheSumOfPrices() public view {
        assertEq(usdg.balanceOf(converter), MAX * PUBLIC_PRICE * 25 / 100);
        assertEq(usdg.balanceOf(treasury), MAX * PUBLIC_PRICE * 75 / 100);
        assertEq(usdg.balanceOf(converter) + usdg.balanceOf(treasury), MAX * PUBLIC_PRICE);
        assertEq(usdg.balanceOf(address(machine)), 0);
    }

    function test_soldOutCanFinalizeBeforeTheWindowEnds() public {
        _finalizeWith(keccak256("x"));
        assertTrue(machine.mintFinalized());
        assertTrue(block.timestamp < machine.publicEnd());
        vm.expectRevert(IQZMachine.AlreadyFinalized.selector);
        machine.finalizeMint();
        // still sold out after finalizing
        _fund(nobody, PUBLIC_PRICE);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.SoldOut.selector);
        machine.mint(_noProof());
    }

    function test_noIdAbove2222() public {
        vm.expectRevert();
        machine.ownerOf(2223);
        assertEq(machine.ownerOf(2222), address(uint160(0xA0000 + 2221)));
    }

    /// @notice After the rotation every machine id maps to exactly one trait id and every trait id is used once; the
    ///         tier counts of the table survive the rotation. The revealer may land on any link in range.
    function testFuzz_rotationIsABijection(bytes32 blockHash, uint16 gap) public {
        vm.assume(blockHash != bytes32(0)); // a zero block hash is refused by `lockHash`
        uint64 jump = uint64(bound(gap, 1, QZConstants.MAX_REVEAL_GAP));
        _finalizeWith(blockHash);
        _revealLink(jump);
        machine.reveal();

        uint256 offset = machine.revealOffset();
        assertEq(offset, _expectedOffset(1, blockHash));
        assertTrue(offset < MAX);

        bool[] memory seen = new bool[](MAX + 1);
        uint256[5] memory tiers;
        uint256 relics;
        for (uint256 id = 1; id <= MAX; ++id) {
            uint256 traitId = machine.traitIdOf(id);
            assertTrue(traitId >= 1 && traitId <= MAX, "trait id in range");
            assertEq(traitId, (id - 1 + offset) % MAX + 1);
            assertFalse(seen[traitId], "trait id used twice");
            seen[traitId] = true;
            (uint8 tier,, bool relic) = machine.traitsOf(id);
            ++tiers[tier];
            if (relic) ++relics;
        }
        for (uint256 t = 1; t <= MAX; ++t) {
            assertTrue(seen[t], "trait id unused");
        }
        // the table has 2 relics (tier 0); the other tiers sum to 2220 whatever the offset is
        assertEq(relics, 2);
        assertEq(tiers[0], 2);
        assertEq(tiers[1] + tiers[2] + tiers[3] + tiers[4], 2220);
    }

    function testFuzz_tierCountsDoNotDependOnTheOffset(bytes32 blockHash) public {
        vm.assume(blockHash != bytes32(0)); // a zero block hash is refused by `lockHash`
        _finalizeWith(blockHash);
        _revealLink(1);
        machine.reveal();
        uint256[5] memory tiers;
        for (uint256 id = 1; id <= MAX; ++id) {
            (uint8 tier,,) = machine.traitsOf(id);
            ++tiers[tier];
        }
        // 1200 / 650 / 280 / 90 per the tier table of SPEC B.5
        assertEq(tiers[1], 1200);
        assertEq(tiers[2], 650);
        assertEq(tiers[3], 280);
        assertEq(tiers[4], 90);
    }
}

/// @notice The same bijection property with a partial supply: only the minted ids are valid and they never collide.
contract QZMachinePartialSupplyTest is MachineFixture {
    function testFuzz_partialSupplyRotatesInjectively(uint16 supply, bytes32 blockHash) public {
        vm.assume(blockHash != bytes32(0)); // a zero block hash is refused by `lockHash`
        uint256 n = bound(supply, 0, 120);
        _sellPublic(0, n);
        _warpAfterPublic();
        _finalizeWith(blockHash);
        _revealLink(1);
        machine.reveal();
        assertEq(machine.mintedCount(), n);

        uint256 off = machine.revealOffset();
        bool[] memory seen = new bool[](MAX + 1);
        for (uint256 id = 1; id <= n; ++id) {
            uint256 traitId = machine.traitIdOf(id);
            assertTrue(traitId >= 1 && traitId <= MAX);
            assertEq(traitId, (id - 1 + off) % MAX + 1);
            assertFalse(seen[traitId]);
            seen[traitId] = true;
        }
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NonexistentMachine.selector, n + 1));
        machine.traitIdOf(n + 1);
    }

    /// @dev A listed wallet trying at any time in any window mints at most once, whatever proof it brings.
    function testFuzz_walletMintsAtMostOnceAcrossWindows(uint32 t0, uint32 t1, uint32 t2, uint32 t3) public {
        uint32[4] memory ts = [t0, t1, t2, t3];
        _fund(both, 4 * PUBLIC_PRICE);
        uint256 sold;
        for (uint256 i; i < 4; ++i) {
            vm.warp(START + (ts[i] % 66 hours));
            MintPhase p = machine.phase();
            bytes32[] memory proof =
                p == MintPhase.Gtd ? _gtdProof(both) : p == MintPhase.Fcfs ? _fcfsProof(both) : _noProof();
            vm.prank(both);
            try machine.mint(proof) returns (uint256) {
                ++sold;
            } catch {}
        }
        assertTrue(sold <= 1);
        assertEq(machine.mintedCount(), sold);
        assertEq(machine.balanceOf(both), sold);
        assertEq(usdg.balanceOf(address(machine)), 0);
    }
}
