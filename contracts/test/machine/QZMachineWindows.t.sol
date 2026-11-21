// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QZMachine} from "../../src/machine/QZMachine.sol";
import {IQZMachine} from "../../src/interfaces/IQZMachine.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MintPhase} from "../../src/lib/QZTypes.sol";
import {MachineFixture} from "./MachineFixture.sol";

/// @notice The three window lengths are deployment-time immutables. A schedule that is not 24 h / 12 h / 24 h behaves
///         the same: odd lengths on purpose, so a constant left in one code path shows up.
contract QZMachineWindowsTest is MachineFixture {
    uint64 internal constant G = 7 minutes;
    uint64 internal constant F = 3 minutes;
    uint64 internal constant P = 11 minutes;

    function _gtdWindow() internal pure override returns (uint64) {
        return G;
    }

    function _fcfsWindow() internal pure override returns (uint64) {
        return F;
    }

    function _publicWindow() internal pure override returns (uint64) {
        return P;
    }

    function test_viewsAndScheduleUseTheDeployedWindows() public view {
        assertEq(machine.gtdWindow(), G);
        assertEq(machine.fcfsWindow(), F);
        assertEq(machine.publicWindowMax(), P);
        assertEq(machine.gtdEnd(), START + G);
        assertEq(machine.fcfsEnd(), START + G + F);
        assertEq(machine.publicEnd(), START + G + F + P);
    }

    function test_phaseBoundaries() public {
        vm.warp(START - 1);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Pending));
        vm.warp(START);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Gtd));
        vm.warp(START + G - 1);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Gtd));
        vm.warp(START + G);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Fcfs));
        vm.warp(START + G + F - 1);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Fcfs));
        vm.warp(START + G + F);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Public));
        vm.warp(START + G + F + P - 1);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Public));
        vm.warp(START + G + F + P);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Closed));
    }

    function test_mintsFollowTheShortBoundaries() public {
        vm.warp(START + G - 1);
        assertEq(_mintAs(gtd0, GTD_PRICE, _gtdProof(gtd0)), 1);
        vm.warp(START + G); // the GTD price no longer applies from here on
        _fund(gtd1, GTD_PRICE);
        vm.prank(gtd1);
        vm.expectRevert();
        machine.mint(_gtdProof(gtd1));
        vm.warp(START + G + F - 1);
        assertEq(_mintAs(fcfs0, FCFS_PRICE, _fcfsProof(fcfs0)), 2);
        vm.warp(START + G + F + P - 1);
        assertEq(_mintAs(nobody, PUBLIC_PRICE, _noProof()), 3);
        vm.warp(START + G + F + P);
        _fund(fcfs1, PUBLIC_PRICE);
        vm.prank(fcfs1);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.MintNotOpen.selector, MintPhase.Closed));
        machine.mint(_noProof());
    }

    function test_finalizeTimingFollowsThePublicEnd() public {
        _sellPublic(0, 2);
        vm.warp(START + G + F + P - 1);
        vm.expectRevert(IQZMachine.CannotFinalizeYet.selector);
        machine.finalizeMint();
        vm.warp(START + G + F + P);
        machine.finalizeMint();
        assertTrue(machine.mintFinalized());
    }

    function test_configureMintOnAFreshMachineUsesItsOwnWindows() public {
        QZMachine m = _deploy(owner, pauser, GTD_PRICE, FCFS_PRICE, PUBLIC_PRICE, G, F, P);
        vm.prank(owner);
        m.configureMint(gtdRoot, fcfsRoot, START + 5 days);
        assertEq(m.gtdEnd(), START + 5 days + G);
        assertEq(m.fcfsEnd(), START + 5 days + G + F);
        assertEq(m.publicEnd(), START + 5 days + G + F + P);
    }
}

/// @notice Out-of-bounds window lengths revert at construction; the production values are the defaults.
contract QZMachineWindowBoundsTest is MachineFixture {
    function test_productionDefaults() public view {
        assertEq(machine.gtdWindow(), QZConstants.GTD_WINDOW);
        assertEq(machine.fcfsWindow(), QZConstants.FCFS_WINDOW);
        assertEq(machine.publicWindowMax(), QZConstants.PUBLIC_WINDOW_MAX);
        assertEq(machine.publicEnd() - machine.mintStart(), 60 hours);
    }

    /// @dev External so that `try` can catch the constructor revert and the test goes on to the next case.
    function attemptDeploy(uint64 g, uint64 f, uint64 p) external returns (QZMachine) {
        return _deploy(owner, pauser, 1, 2, 3, g, f, p);
    }

    /// @notice All 15 cases: each of the three slots at 0, 59 s, 60 s, 7 days and 7 days + 1. Only 60 s and 7 days deploy.
    function test_boundsAreOneMinuteToSevenDays() public {
        uint64[5] memory probe = [uint64(0), 59, 60, 7 days, 7 days + 1];
        bool[5] memory allowed = [false, false, true, true, false];
        uint256 cases;
        for (uint256 slot; slot < 3; ++slot) {
            for (uint256 k; k < 5; ++k) {
                uint64[3] memory w = [uint64(1 days), uint64(1 days), uint64(1 days)];
                w[slot] = probe[k];
                bool ok = true;
                try this.attemptDeploy(w[0], w[1], w[2]) returns (QZMachine m) {
                    assertEq(m.gtdWindow(), w[0]);
                    assertEq(m.fcfsWindow(), w[1]);
                    assertEq(m.publicWindowMax(), w[2]);
                } catch (bytes memory reason) {
                    ok = false;
                    assertEq(bytes4(reason), IQZMachine.BadSchedule.selector, "wrong revert");
                }
                assertEq(ok, allowed[k], "slot/value case");
                ++cases;
            }
        }
        assertEq(cases, 15);
    }

    function testFuzz_onlyInBoundsWindowsDeploy(uint64 g, uint64 f, uint64 p) public {
        bool ok = g >= 1 minutes && g <= 7 days && f >= 1 minutes && f <= 7 days && p >= 1 minutes && p <= 7 days;
        if (!ok) vm.expectRevert(IQZMachine.BadSchedule.selector);
        QZMachine m = _deploy(owner, pauser, 1, 2, 3, g, f, p);
        if (ok) {
            assertEq(m.gtdWindow(), g);
            assertEq(m.fcfsWindow(), f);
            assertEq(m.publicWindowMax(), p);
        }
    }
}
