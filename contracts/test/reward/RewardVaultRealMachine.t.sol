// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZRewardVault} from "../../src/reward/QZRewardVault.sol";
import {QZMachine} from "../../src/machine/QZMachine.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MockConverter, MockStock} from "./mocks/RewardMocks.sol";

/// @notice `QZRewardVault` against the real `QZMachine` (unit C3): traits come from the real table by id, ownership
///         from the real ERC721. This test contract plays `QZCore` (mint and `onHardwire`). Converter is a mock.
contract RewardVaultRealMachineTest is Test {
    bytes32 internal constant TRAITS_HASH = 0x8c678f953f7895e038bb93558be897518034e8d7daa6385c4c7ff2e5df5c8102;

    QZMachine internal machine;
    QZRewardVault internal vault;
    MockConverter internal conv;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        machine = new QZMachine(address(this), TRAITS_HASH, makeAddr("royalty"));
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

    function test_realMachine_hardwireNotifyClaimAfterTransfer() public {
        (uint256 id,, uint8 track) = _find(false);
        (uint256 relicId,,) = _find(true);
        machine.mint(alice, id);
        machine.mint(alice, relicId);
        vault.onHardwire(id);
        vault.onHardwire(relicId);

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
        vm.expectRevert();
        vault.claim(ids, tracks);
        vm.prank(bob);
        vault.claim(ids, tracks);
        MockStock s = conv.stocks(track);
        assertEq(s.balanceOf(bob), standard);
        assertEq(vault.claimable(id, track), 0);
    }
}
