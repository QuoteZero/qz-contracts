// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployCloseBell} from "../../script/dapps/DeployCloseBell.s.sol";
import {QZCloseBell} from "../../src/dapps/QZCloseBell.sol";
import {QZBoardSource} from "../../src/dapps/QZBoardSource.sol";
import {BellFixture} from "./BellFixture.sol";

/// @dev Runs the deploy script in-process against the fixture's mocks.
contract DeployCloseBellTest is BellFixture {
    uint256 internal constant PK = 0xA11CE5;

    function _env() internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(PK));
        vm.setEnv("QZ_MACHINE", vm.toString(address(machine)));
        vm.setEnv("QZ_FORGE", vm.toString(address(forge)));
        vm.setEnv("QZ_TOKEN", vm.toString(address(qz)));
        vm.setEnv("QZ_USDG", vm.toString(address(usdg)));
    }

    function test_scriptRefusesOtherChains() public {
        _env();
        DeployCloseBell s = new DeployCloseBell();
        vm.chainId(1);
        vm.expectRevert("DeployCloseBell: not the Robinhood testnet");
        s.run();
    }

    function test_scriptDeploysBoardAndBell() public {
        _env();
        DeployCloseBell s = new DeployCloseBell();
        vm.chainId(46_630);
        s.run();
        // the deployer is calendar, treasury and poster by default
        address deployer = vm.addr(PK);
        address board = vm.computeCreateAddress(deployer, 0);
        address bellAddr = vm.computeCreateAddress(deployer, 1);
        assertEq(QZBoardSource(board).owner(), deployer);
        assertEq(QZBoardSource(board).poster(), deployer);
        assertTrue(QZBoardSource(board).isSupported(0));
        assertFalse(QZBoardSource(board).isSupported(6));
        QZCloseBell b = QZCloseBell(bellAddr);
        assertEq(b.source(), board);
        assertEq(b.calendar(), deployer);
        assertEq(b.treasury(), deployer);
        assertEq(b.sponsor(), address(0));
        assertEq(b.voidAfter(), 1200);
        assertEq(b.claimDelay(), 1200);
        assertEq(b.snapshotDelay(), 60);
        assertEq(b.machine(), address(machine));

        // a dependency with no code is refused (same test: env vars are process-global, tests run in parallel)
        vm.setEnv("QZ_FORGE", vm.toString(address(0xBEEF)));
        vm.chainId(46_630);
        vm.expectRevert("DeployCloseBell: a dependency has no code");
        s.run();
    }
}
