// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZConstants} from "../../src/lib/QZConstants.sol";
import {QZForge} from "../../src/light/QZForge.sol";
import {MockQZ, MockMachine, MockVault} from "./mocks/LightMocks.sol";

/// @dev Shared deployment: the vault address is computed first, exactly as the deploy script does it, so the vault
///      knows its forge and the forge knows its vault.
abstract contract QZForgeBase is Test {
    uint256 internal constant N = QZConstants.LIGHT_AMOUNT;
    uint64 internal constant OPENS_AT = 1_800_000_000;

    address internal constant TEAM = address(0x7EA4);
    address internal constant PAUSER = address(0x9A05E);

    MockQZ internal qz;
    MockMachine internal nft;
    MockVault internal vault;
    QZForge internal forge;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        vm.warp(OPENS_AT);
        qz = new MockQZ();
        nft = new MockMachine();
        vault = new MockVault(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        forge = new QZForge(address(qz), address(nft), address(vault), TEAM, PAUSER, OPENS_AT);
        nft.setRevealed(true);
    }

    function _give(address who, uint256 id) internal {
        nft.mint(who, id);
        qz.mint(who, N);
        vm.prank(who);
        qz.approve(address(forge), type(uint256).max);
    }
}
