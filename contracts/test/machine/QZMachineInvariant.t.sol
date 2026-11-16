// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {QZCore} from "../../src/core/QZCore.sol";
import {QZEntropy} from "../../src/random/QZEntropy.sol";
import {QZMachine} from "../../src/machine/QZMachine.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MachineFixture} from "./MachineFixture.sol";

/// @notice Drives the real core + entropy + machine with random wallet-to-wallet moves, 1-wei bounces (rerolls), epoch
///         advances with reveals, pauses and hardwires, and records every machine id it saw minted.
contract MachineHandler is Test {
    uint256 internal constant EPOCH = QZConstants.EPOCH_DURATION;
    uint64 internal immutable E0;
    address internal immutable revealer;

    QZCore internal immutable core;
    QZEntropy internal immutable entropy;
    QZMachine internal immutable machine;
    address internal immutable curve;
    address internal immutable pauser;
    bytes32[] internal chain;
    address[4] internal users;

    bool public machineIssuedTwice;
    bool public machineOutOfRange;
    uint256 public hardwires;
    uint256[] public mintedIds;
    mapping(uint256 => bool) public isMinted;

    constructor(
        QZCore core_,
        QZEntropy entropy_,
        QZMachine machine_,
        address curve_,
        address pauser_,
        address revealer_,
        bytes32[] memory chain_,
        uint64 e0,
        address[4] memory users_
    ) {
        core = core_;
        entropy = entropy_;
        machine = machine_;
        curve = curve_;
        pauser = pauser_;
        revealer = revealer_;
        E0 = e0;
        users = users_;
        for (uint256 i; i < chain_.length; ++i) {
            chain.push(chain_[i]);
        }
    }

    function usersAt(uint256 i) external view returns (address) {
        return users[i];
    }

    function mintedCount() external view returns (uint256) {
        return mintedIds.length;
    }

    function give(uint256 userSeed, uint256 amount) external {
        uint256 left = core.balanceOf(curve);
        amount = bound(amount, 0, left < 6e18 ? left : 6e18);
        vm.prank(curve);
        core.transfer(users[userSeed % 4], amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = users[fromSeed % 4];
        address to = users[toSeed % 4];
        uint256 bal = core.balanceOf(from);
        // mostly dust and fractions of a unit: those are the moves that dissolve and re-mint tickets
        amount = amount % 3 == 0 ? bound(amount, 0, bal) : bound(amount, 0, bal < 3 ? bal : 3);
        vm.prank(from);
        core.transfer(to, amount);
    }

    /// @dev Rerolls `user`: 1 wei out and back through `other`.
    function bounce(uint256 userSeed) external {
        address a = users[userSeed % 4];
        address b = users[(userSeed % 4 + 1) % 4];
        if (core.balanceOf(a) == 0) return;
        vm.prank(a);
        core.transfer(b, 1);
        vm.prank(b);
        core.transfer(a, 1);
    }

    function advance(uint256 k) external {
        k = bound(k, 1, 3);
        vm.warp(block.timestamp + k * EPOCH);
        for (uint64 e = entropy.nextReveal(); e < entropy.currentEpoch(); ++e) {
            vm.prank(revealer);
            entropy.reveal(e, chain[e - E0 + 1]);
        }
        entropy.processQueue(type(uint256).max);
    }

    function setPaused(bool on) external {
        if (core.paused() == on) return;
        vm.prank(pauser);
        if (on) core.pause();
        else core.unpause();
    }

    function hardwire(uint256 userSeed, uint256 pick) external {
        address u = users[userSeed % 4];
        uint256[] memory ids = core.ownedIds(u, 0, type(uint256).max);
        if (ids.length == 0 || core.paused()) return;
        uint256 ticketId = ids[pick % ids.length];
        (,,, uint256 machineId, bool revealed) = core.ticketInfo(ticketId);
        uint256 supplyBefore = core.totalSupply();
        vm.prank(u);
        try core.hardwire(ticketId) returns (uint256 minted) {
            ++hardwires;
            if (minted < 1 || minted > QZConstants.TOTAL_MACHINES) machineOutOfRange = true;
            if (isMinted[minted]) machineIssuedTwice = true;
            if (!revealed || minted != machineId) machineIssuedTwice = true; // wrong id: flagged by the same invariant
            isMinted[minted] = true;
            mintedIds.push(minted);
            assertEq(core.totalSupply(), supplyBefore - QZConstants.UNIT, "exactly 1 QZ burned");
        } catch {
            assertTrue(
                !revealed || core.balanceOf(u) < QZConstants.UNIT, "a revealed ticket of a funded owner hardwires"
            );
        }
    }
}

/// @notice SPEC §2.4: I1 supply and I3 machine id uniqueness, with `QZMachine` and `QZCore` as deployed.
contract QZMachineInvariantTest is StdInvariant, MachineFixture {
    MachineHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[4] memory users = [alice, bob, carol, makeAddr("dave")];
        handler = new MachineHandler(core, entropy, machine, curve, pauser, REVEALER, chain, E0, users);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I1_supplyPlusHardwiredIsConstant() public view {
        assertEq(core.totalSupply() + core.totalHardwired() * UNIT, QZConstants.TOTAL_SUPPLY);
        assertEq(core.economicUnits(), QZConstants.TOTAL_SUPPLY);
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I3_machineIdsAreUniqueAndCountMatches() public view {
        assertEq(machine.totalMinted(), core.totalHardwired(), "totalMinted == totalHardwired");
        assertEq(handler.mintedCount(), core.totalHardwired());
        assertFalse(handler.machineIssuedTwice(), "a machine id was issued twice");
        assertFalse(handler.machineOutOfRange(), "a machine id out of 1..4444");
    }

    /// @dev Every id the handler saw minted still has an owner: nothing is ever burned.
    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I3_mintedMachinesStayMinted() public view {
        uint256 n = handler.mintedCount();
        for (uint256 i; i < n; ++i) {
            assertTrue(machine.ownerOf(handler.mintedIds(i)) != address(0));
        }
        assertLe(n, QZConstants.TOTAL_MACHINES);
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noQzStuckInTheCore() public view {
        assertEq(core.balanceOf(address(core)), 0, "the hardwire burn sink is empty after every call");
    }
}
