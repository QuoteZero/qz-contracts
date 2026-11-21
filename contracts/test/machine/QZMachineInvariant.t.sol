// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {QZMachine} from "../../src/machine/QZMachine.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MintPhase} from "../../src/lib/QZTypes.sol";
import {MachineFixture} from "./MachineFixture.sol";
import {MockUSDG} from "./MockUSDG.sol";
import {QZMerkle} from "./QZMerkle.sol";

/// @dev Random buyers (listed and unlisted, honest and underfunded), random time, a paused or blocklisted USDG, a
///      paused machine and bulk fills toward the cap.
contract MintHandler is CommonBase, StdUtils {
    QZMachine public machine;
    MockUSDG public usdg;
    address public converter;
    address public treasury;
    address public pauser;
    uint64 public start;
    bytes32[] public gtdTree;
    bytes32[] public fcfsTree;
    address[] public listed;

    uint256 public successes;
    mapping(address => uint256) public mintsOf;
    uint256 public bulkSeed;

    constructor(
        QZMachine m,
        MockUSDG u,
        address c,
        address t,
        address p,
        uint64 s,
        bytes32[] memory gt,
        bytes32[] memory ft,
        address[] memory l
    ) {
        machine = m;
        usdg = u;
        converter = c;
        treasury = t;
        pauser = p;
        start = s;
        gtdTree = gt;
        fcfsTree = ft;
        listed = l;
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + dt % 20 hours);
    }

    function buy(uint8 who, uint8 funding, bool useProof) external {
        address buyer = who % 2 == 0 ? listed[who % listed.length] : address(uint160(0xD0000 + who));
        uint256 price = funding % 4 == 0 ? 0 : 5e6; // some buyers bring no USDG
        if (price != 0) {
            usdg.mint(buyer, price);
            vm.prank(buyer);
            usdg.approve(address(machine), price);
        }
        MintPhase p = machine.phase();
        bytes32[] memory proof = new bytes32[](0);
        if (useProof && who % 2 == 0) {
            bytes32[] memory tree = p == MintPhase.Fcfs ? fcfsTree : gtdTree;
            try this.proofFor(tree, buyer) returns (bytes32[] memory pr) {
                proof = pr;
            } catch {}
        }
        vm.prank(buyer);
        try machine.mint(proof) returns (uint256) {
            ++successes;
            ++mintsOf[buyer];
        } catch {}
    }

    function proofFor(bytes32[] memory tree, address a) external pure returns (bytes32[] memory) {
        return QZMerkle.proofOf(tree, a);
    }

    /// @dev Sell up to 300 public machines to fresh wallets at once so the cap is reachable in a run.
    function fill(uint16 n) external {
        if (machine.phase() != MintPhase.Public) return;
        uint256 count = bound(n, 1, 300);
        for (uint256 i; i < count; ++i) {
            address buyer = address(uint160(0xE0000 + ++bulkSeed));
            usdg.mint(buyer, 5e6);
            vm.prank(buyer);
            usdg.approve(address(machine), 5e6);
            vm.prank(buyer);
            try machine.mint(new bytes32[](0)) returns (uint256) {
                ++successes;
                ++mintsOf[buyer];
            } catch {
                break;
            }
        }
    }

    function breakUsdg(uint8 kind, bool on) external {
        if (kind % 3 == 0) usdg.setPaused(on);
        else if (kind % 3 == 1) usdg.setBlocked(treasury, on);
        else usdg.setBlocked(converter, on);
    }

    function toggleMachinePause(bool on) external {
        vm.prank(pauser);
        if (on && !machine.paused()) machine.pause();
        else if (!on && machine.paused()) machine.unpause();
    }

    function wallets() external view returns (address[] memory) {
        return listed;
    }
}

contract QZMachineInvariantTest is StdInvariant, MachineFixture {
    MintHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory l = new address[](gtdList.length);
        for (uint256 i; i < l.length; ++i) {
            l[i] = gtdList[i];
        }
        handler = new MintHandler(machine, usdg, converter, treasury, pauser, START, gtdTree, fcfsTree, l);
        vm.warp(START);
        targetContract(address(handler));
    }

    /// @notice B1 row: the supply never passes 2222.
    function invariant_supplyCapped() public view {
        assertLe(machine.mintedCount(), QZConstants.TOTAL_MACHINES);
        assertEq(machine.totalSupply(), machine.mintedCount());
    }

    /// @notice B1 row: the machine never holds USDG, after every call of every sequence.
    function invariant_machineHoldsNoUsdg() public view {
        assertEq(usdg.balanceOf(address(machine)), 0);
    }

    /// @notice Money in = money out: every sold machine paid 3, 4 or 5 USDG in whole, split 25/75.
    function invariant_splitIsExact() public view {
        uint256 c = usdg.balanceOf(converter);
        uint256 t = usdg.balanceOf(treasury);
        assertEq(t, c * 3, "75/25 of every price");
        uint256 sold = machine.mintedCount();
        assertGe(c + t, sold * QZConstants.PRICE_GTD);
        assertLe(c + t, sold * QZConstants.PRICE_PUBLIC);
    }

    /// @notice One mint per wallet: nobody ever got a second machine from `mint`.
    function invariant_oneMintPerWallet() public view {
        address[] memory w = handler.wallets();
        for (uint256 i; i < w.length; ++i) {
            assertLe(handler.mintsOf(w[i]), 1);
        }
    }
}
