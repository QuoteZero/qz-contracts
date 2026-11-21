// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZMachine} from "../../src/interfaces/IQZMachine.sol";
import {MintPhase} from "../../src/lib/QZTypes.sol";
import {MachineFixture} from "./MachineFixture.sol";

/// @notice A pause freezes the mint clock: boundaries still ahead move by the paused time, so a pause never shortens a
///         phase, and `finalizeMint` cannot close the supply on a clock that did not run.
abstract contract QZMachinePauseWindowBase is MachineFixture {
    uint64 internal GTD;
    uint64 internal FCFS;
    uint64 internal PUB;

    function setUp() public virtual override {
        super.setUp();
        GTD = _gtdWindow();
        FCFS = _fcfsWindow();
        PUB = _publicWindow();
    }

    function _pause() internal {
        vm.prank(pauser);
        machine.pause();
    }

    function _unpause() internal {
        vm.prank(pauser);
        machine.unpause();
    }

    function test_pauseInGtdMovesEveryBoundaryAhead() public {
        uint64 p = GTD / 4; // length of the pause
        vm.warp(START + GTD / 8);
        _pause();
        vm.warp(START + GTD / 8 + p);
        vm.expectEmit(address(machine));
        emit IQZMachine.MintWindowExtended(p, START + GTD + FCFS + PUB + p);
        _unpause();
        assertEq(machine.mintStart(), START);
        assertEq(machine.gtdEnd(), START + GTD + p);
        assertEq(machine.fcfsEnd(), START + GTD + FCFS + p);
        assertEq(machine.publicEnd(), START + GTD + FCFS + PUB + p);
        // the pause is not taken out of GTD: it still has `7/8 GTD` from now
        vm.warp(START + GTD + p - 1);
        assertEq(uint256(machine.phase()), uint256(MintPhase.Gtd));
        vm.warp(START + GTD + p);
        assertEq(uint256(machine.phase()), uint256(MintPhase.Fcfs));
    }

    function test_pauseInTheMiddleOfPublicKeepsTheRemainingTime() public {
        uint64 at = PUB / 3;
        uint64 length = 30 * PUB;
        vm.warp(START + GTD + FCFS + at);
        _pause();
        vm.warp(START + GTD + FCFS + at + length);
        _unpause();
        assertEq(machine.gtdEnd(), START + GTD); // already behind the pause point
        assertEq(machine.fcfsEnd(), START + GTD + FCFS);
        assertEq(machine.publicEnd(), START + GTD + FCFS + PUB + length);
        assertEq(machine.publicEnd() - vm.getBlockTimestamp(), PUB - at);
        assertEq(uint256(machine.phase()), uint256(MintPhase.Public));
        _mintAs(nobody, PUBLIC_PRICE, _noProof());
    }

    function test_finalizeCannotUseTheStoppedClock() public {
        _sellPublic(0, 2);
        vm.warp(START + GTD + FCFS + PUB / 24);
        _pause();
        // far past the old public end: the clock did not run
        vm.warp(START + GTD + FCFS + PUB + 10 * PUB);
        assertEq(uint256(machine.phase()), uint256(MintPhase.Public));
        vm.expectRevert(IQZMachine.CannotFinalizeYet.selector);
        machine.finalizeMint();
        _unpause();
        vm.expectRevert(IQZMachine.CannotFinalizeYet.selector);
        machine.finalizeMint();
        // after the moved end it works
        vm.warp(machine.publicEnd());
        machine.finalizeMint();
        assertEq(machine.mintedCount(), 2);
    }

    function test_pauseAfterThePublicWindowEndedStillLetsFinalize() public {
        _sellPublic(0, 2);
        _warpAfterPublic();
        _pause();
        machine.finalizeMint();
        assertTrue(machine.mintFinalized());
        assertEq(uint256(machine.phase()), uint256(MintPhase.Closed));
    }

    function test_pauseBeforeStartThatEndsBeforeStartMovesNothing() public {
        vm.warp(START - 10 hours);
        _pause();
        vm.warp(START - 2 hours);
        _unpause();
        assertEq(machine.gtdEnd(), START + GTD);
        assertEq(machine.publicEnd(), START + GTD + FCFS + PUB);
    }

    function test_pauseBeforeStartThatEndsAfterStartMovesFromTheStart() public {
        uint64 d = GTD / 2;
        vm.warp(START - 10 hours);
        _pause();
        vm.warp(START + d);
        _unpause();
        assertEq(machine.mintStart(), START);
        assertEq(machine.gtdEnd(), START + GTD + d);
        assertEq(machine.publicEnd(), START + GTD + FCFS + PUB + d);
        assertEq(uint256(machine.phase()), uint256(MintPhase.Gtd));
    }

    function test_twoPausesAdd() public {
        uint64 u = GTD / 16;
        vm.warp(START + u);
        _pause();
        vm.warp(START + 2 * u);
        _unpause();
        vm.warp(START + 5 * u);
        _pause();
        vm.warp(START + 9 * u);
        _unpause();
        assertEq(machine.publicEnd(), START + GTD + FCFS + PUB + 5 * u);
    }

    /// @notice Whatever the pause point and length inside the public window: the time left after the pause equals the
    ///         time left before it.
    function testFuzz_pauseNeverShortensThePublicWindow(uint32 at, uint32 length) public {
        uint256 offset = bound(at, 0, PUB - 1);
        uint256 duration = bound(length, 0, 400 days);
        uint256 pubStart = START + GTD + FCFS;
        vm.warp(pubStart + offset);
        uint256 leftBefore = machine.publicEnd() - vm.getBlockTimestamp();
        _pause();
        vm.warp(pubStart + offset + duration);
        _unpause();
        assertEq(machine.publicEnd() - vm.getBlockTimestamp(), leftBefore);
        assertEq(uint256(machine.phase()), uint256(MintPhase.Public));
    }

    function testFuzz_pauseNeverShortensGtdOrFcfs(uint32 at, uint32 length, bool inFcfs) public {
        uint256 base = inFcfs ? START + GTD : START;
        uint256 span = inFcfs ? FCFS : GTD;
        uint256 offset = bound(at, 0, span - 1);
        uint256 duration = bound(length, 0, 400 days);
        vm.warp(base + offset);
        uint256 end = inFcfs ? machine.fcfsEnd() : machine.gtdEnd();
        uint256 leftBefore = end - vm.getBlockTimestamp();
        _pause();
        vm.warp(base + offset + duration);
        _unpause();
        uint256 endAfter = inFcfs ? machine.fcfsEnd() : machine.gtdEnd();
        assertEq(endAfter - vm.getBlockTimestamp(), leftBefore);
    }
}

/// @notice The production windows: 24 h, 12 h, 24 h.
contract QZMachinePauseWindowDefaultTest is QZMachinePauseWindowBase {}

/// @notice A short schedule (the testnet one): the same behaviour on 12 min / 6 min / 18 min.
contract QZMachinePauseWindowShortTest is QZMachinePauseWindowBase {
    function _gtdWindow() internal pure override returns (uint64) {
        return 12 minutes;
    }

    function _fcfsWindow() internal pure override returns (uint64) {
        return 6 minutes;
    }

    function _publicWindow() internal pure override returns (uint64) {
        return 18 minutes;
    }
}
