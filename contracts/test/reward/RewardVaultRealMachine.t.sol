// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {QZRewardVault} from "../../src/reward/QZRewardVault.sol";
import {IQZRewardVault} from "../../src/interfaces/IQZRewardVault.sol";
import {QZTraitsTable} from "../../src/machine/QZTraitsTable.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MockConverter, MockStock} from "./mocks/RewardMocks.sol";

/// @notice The machine as the vault sees it: a real ERC-721, the committed trait table, and the reveal rotation
///         `traitId = ((tokenId - 1 + offset) mod 2222) + 1` with `traitsOf` reverting before the reveal. Mirrors the
///         `IQZMachine` surface the vault reads (`ownerOf`, `traitsOf`).
contract RotatedMachine is ERC721 {
    error NotRevealed();

    bool public revealed;
    uint256 public revealOffset;

    constructor() ERC721("Machine", "QZM") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function reveal(uint256 offset) external {
        revealed = true;
        revealOffset = offset % QZConstants.TOTAL_MACHINES;
    }

    function traitsOf(uint256 id) external view returns (uint8 tier, uint8 track, bool relic) {
        if (!revealed) revert NotRevealed();
        uint256 traitId = ((id - 1 + revealOffset) % QZConstants.TOTAL_MACHINES) + 1;
        uint8 packed = uint8(QZTraitsTable.TABLE[traitId - 1]);
        return (packed >> 4, packed & 0x0f, traitId >= QZConstants.FIRST_RELIC_ID);
    }
}

/// @notice `QZRewardVault` against an ERC-721 machine that carries the real trait table and the real reveal rotation:
///         traits come from the table by rotated id, ownership from the ERC-721. This test contract plays the Forge
///         (`register`). The converter is a mock.
contract RewardVaultRealMachineTest is Test {
    RotatedMachine internal machine;
    QZRewardVault internal vault;
    MockConverter internal conv;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        machine = new RotatedMachine();
        conv = new MockConverter();
        vault = new QZRewardVault(address(this), address(machine), address(conv));
    }

    function _find(bool relic) internal view returns (uint256 id, uint8 tier, uint8 track) {
        for (id = 1; id <= QZConstants.TOTAL_MACHINES; ++id) {
            bool r;
            (tier, track, r) = machine.traitsOf(id);
            if (r == relic && (relic || tier > 0)) return (id, tier, track);
        }
        revert("no machine of that kind");
    }

    function test_realMachine_lightNotifyClaimAfterTransfer() public {
        machine.reveal(777);
        (uint256 id,, uint8 track) = _find(false);
        (uint256 relicId,,) = _find(true);
        machine.mint(alice, id);
        machine.mint(alice, relicId);
        vault.register(id);
        vault.register(relicId);

        uint256 w = vault.weightOf(track);
        assertGt(w, 0, "tier weight");
        conv.deliver(vault, track, 1e18);
        uint256 standard = vault.claimable(id, track);
        uint256 relicShare = vault.claimable(relicId, track);
        assertGt(standard, 0);
        assertGt(relicShare, 0);
        assertLe(standard + relicShare, 1e18, "I6: never above what was notified");

        // the new owner of a transferred machine, not the old one, collects
        vm.prank(alice);
        machine.transferFrom(alice, bob, id);
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tracks = new uint8[](1);
        ids[0] = id;
        tracks[0] = track;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.NotOwnerOfMachine.selector, id, alice));
        vault.claim(ids, tracks);
        vm.prank(bob);
        vault.claim(ids, tracks);
        MockStock s = conv.stocks(track);
        assertEq(s.balanceOf(bob), standard);
        assertEq(vault.claimable(id, track), 0);
    }

    /// A machine cannot be lit before the reveal: `register` reverts with the machine's own error and enrols nothing.
    function test_realMachine_cannotRegisterBeforeReveal() public {
        machine.mint(alice, 1);
        vm.expectRevert(RotatedMachine.NotRevealed.selector);
        vault.register(1);
        assertEq(vault.weightOf(0), 0);
        assertEq(vault.relicCount(), 0);
    }

    /// Whatever the rotation, the two relic traits land on exactly two ids and every other id is a standard machine
    /// with weight 10/15/25/40 on a track 0..9.
    function testFuzz_realMachine_rotationKeepsTheTableShape(uint256 offset) public {
        machine.reveal(offset);
        uint256 relics;
        for (uint256 id = 1; id <= QZConstants.TOTAL_MACHINES; ++id) {
            (uint8 tier, uint8 track, bool relic) = machine.traitsOf(id);
            if (relic) {
                ++relics;
            } else {
                assertTrue(tier >= 1 && tier <= 4, "tier");
                assertLt(track, QZConstants.TRACK_COUNT, "track");
            }
        }
        assertEq(relics, QZConstants.RELIC_COUNT);
    }
}
