// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZCore} from "../../src/core/QZCore.sol";
import {QZDarkMirror} from "../../src/core/QZDarkMirror.sol";
import {QZEntropy} from "../../src/random/QZEntropy.sol";
import {QZMachine} from "../../src/machine/QZMachine.sol";
import {QZAddresses} from "../../src/lib/QZAddresses.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MockVault, MockHook} from "../core/mocks/CoreMocks.sol";
import {QZOnion} from "../random/QZOnion.sol";

/// @notice The real `QZCore` + `QZDarkMirror` + `QZEntropy` + `QZMachine`, wired the way the C9 deploy script has to
///         wire them (core address pre-computed from the deployer nonce). Only the vault and the hook are mocks.
abstract contract MachineFixture is Test {
    uint64 internal constant E0 = 14_166_667;
    uint256 internal constant N = 600;
    uint256 internal constant EPOCH = QZConstants.EPOCH_DURATION;
    uint256 internal constant UNIT = QZConstants.UNIT;
    bytes32 internal constant TRAITS_HASH = 0x8c678f953f7895e038bb93558be897518034e8d7daa6385c4c7ff2e5df5c8102;
    address internal constant REVEALER = address(0xBEEF);

    QZCore internal core;
    QZDarkMirror internal mirror;
    QZEntropy internal entropy;
    QZMachine internal machine;
    MockVault internal vault;
    MockHook internal hook;
    bytes32[] internal chain;

    address internal owner = makeAddr("owner");
    address internal pauser = makeAddr("pauser");
    address internal curve = makeAddr("curve");
    address internal royaltyReceiver = makeAddr("royaltyReceiver");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        chain = QZOnion.build(keccak256("qz machine onion"), N);
        _warpTo(E0);

        address coreAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        mirror = new QZDarkMirror(address(this));
        entropy = new QZEntropy(coreAddr, REVEALER, chain[0]);
        machine = new QZMachine(coreAddr, TRAITS_HASH, royaltyReceiver);
        vault = new MockVault(coreAddr);
        hook = new MockHook(coreAddr);
        core = new QZCore(
            owner,
            pauser,
            address(mirror),
            curve,
            address(entropy),
            address(machine),
            address(vault),
            address(hook),
            QZAddresses.POOL_MANAGER
        );
        assertEq(address(core), coreAddr, "core address prediction");
    }

    // ───────────── time and reveals ─────────────

    /// @dev Seven seconds into `epoch`.
    function _warpTo(uint64 epoch) internal {
        vm.warp(uint256(epoch) * EPOCH + 7);
    }

    function _epoch() internal view returns (uint64) {
        return entropy.currentEpoch();
    }

    function _link(uint64 epoch) internal view returns (bytes32) {
        return chain[epoch - E0 + 1];
    }

    function _seed(uint64 epoch) internal view returns (bytes32) {
        return QZOnion.seedOf(_link(epoch), epoch);
    }

    /// @dev Reveal every closed epoch that is still unrevealed, in order.
    function _revealClosed() internal {
        for (uint64 e = entropy.nextReveal(); e < _epoch(); ++e) {
            vm.prank(REVEALER);
            entropy.reveal(e, _link(e));
        }
    }

    /// @dev Move into the next epoch, reveal what closed, draw every queued ticket.
    function _nextEpochAndDraw() internal {
        _warpTo(_epoch() + 1);
        _revealClosed();
        entropy.processQueue(type(uint256).max);
    }

    // ───────────── balances and tickets ─────────────

    function _give(address to, uint256 amount) internal {
        vm.prank(curve);
        core.transfer(to, amount);
    }

    function _ids(address who) internal view returns (uint256[] memory) {
        return core.ownedIds(who, 0, type(uint256).max);
    }

    function _contains(uint256[] memory ids, uint256 id) internal pure returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    function _machineOfTicket(uint256 ticketId) internal view returns (uint256 machineId, bool revealed) {
        (,,, machineId, revealed) = core.ticketInfo(ticketId);
    }

    function _assertI1I3() internal view {
        assertEq(core.totalSupply() + core.totalHardwired() * UNIT, QZConstants.TOTAL_SUPPLY, "I1");
        assertEq(machine.totalMinted(), core.totalHardwired(), "I3 totalMinted == totalHardwired");
    }
}
