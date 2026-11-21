// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QZMachine} from "../../src/machine/QZMachine.sol";
import {IQZMachine} from "../../src/interfaces/IQZMachine.sol";
import {MachineFixture} from "./MachineFixture.sol";

/// @dev A USDG that calls back into `mint` from inside `transferFrom`.
contract ReentrantUsdg {
    QZMachine public machine;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public tried;
    bool public reenterSucceeded;

    function setMachine(QZMachine m) external {
        machine = m;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        if (!tried) {
            tried = true;
            // the payer is the caller of `mint`; the machine is the caller here
            try machine.mint(new bytes32[](0)) returns (uint256) {
                reenterSucceeded = true;
            } catch {}
        }
        allowance[from][msg.sender] -= a;
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract QZMachineAttackTest is MachineFixture {
    function test_reentrantUsdgCannotMintTwice() public {
        ReentrantUsdg bad = new ReentrantUsdg();
        QZMachine m = new QZMachine(
            owner,
            pauser,
            address(bad),
            converter,
            treasury,
            address(entropy),
            TRAITS_HASH,
            GTD_PRICE,
            FCFS_PRICE,
            PUBLIC_PRICE,
            QZMachine.MintWindows(_gtdWindow(), _fcfsWindow(), _publicWindow())
        );
        bad.setMachine(m);
        vm.prank(owner);
        m.configureMint(gtdRoot, fcfsRoot, uint64(block.timestamp));
        vm.warp(block.timestamp + 36 hours);
        bad.mint(nobody, 100e6);
        vm.prank(nobody);
        bad.approve(address(m), 100e6);
        vm.prank(nobody);
        m.mint(_noProof());
        assertTrue(bad.tried());
        assertFalse(bad.reenterSucceeded(), "reentrant mint refused");
        assertEq(m.mintedCount(), 1);
        assertEq(bad.balanceOf(address(m)), 0);
    }

    function test_converterEqualTreasuryStillSplitsCleanly() public {
        QZMachine m = new QZMachine(
            owner,
            pauser,
            address(usdg),
            treasury,
            treasury,
            address(entropy),
            TRAITS_HASH,
            GTD_PRICE,
            FCFS_PRICE,
            PUBLIC_PRICE,
            QZMachine.MintWindows(_gtdWindow(), _fcfsWindow(), _publicWindow())
        );
        vm.prank(owner);
        m.configureMint(gtdRoot, fcfsRoot, uint64(block.timestamp));
        vm.warp(block.timestamp + 36 hours);
        usdg.mint(nobody, 5e6);
        vm.prank(nobody);
        usdg.approve(address(m), 5e6);
        vm.prank(nobody);
        m.mint(_noProof());
        assertEq(usdg.balanceOf(treasury), 5e6);
        assertEq(usdg.balanceOf(address(m)), 0);
    }

    function test_donatedUsdgDoesNotBreakMintOrAccounting() public {
        _warpPublic();
        usdg.mint(address(machine), 123e6); // a donation to the machine
        _mintAs(nobody, PUBLIC_PRICE, _noProof());
        assertEq(usdg.balanceOf(converter), 1_250_000);
        assertEq(usdg.balanceOf(treasury), 3_750_000);
        assertEq(machine.mintedCount(), 1);
    }

    function test_directEthIsRefused() public {
        (bool ok,) = address(machine).call{value: 0}("");
        assertFalse(ok);
    }
}
