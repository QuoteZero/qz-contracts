// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {QZForge} from "../../src/light/QZForge.sol";
import {QZForgeBase} from "./QZForgeBase.sol";
import {MockQZ, MockMachine, MockVault} from "./mocks/LightMocks.sol";

/// @dev Random sequence of lights, machine transfers, direct QZ donations, funding, reveal, time and pause calls.
///      Keeps its own count of the lights that went through, so the checks compare the forge against something it
///      does not compute itself.
contract LightHandler is CommonBase, StdUtils {
    uint256 public constant N = 100_000e18;
    uint256 public constant MACHINES = 10;
    uint256 public constant ACTORS = 4;

    QZForge public immutable forge;
    MockQZ public immutable qz;
    MockMachine public immutable nft;
    address public immutable pauser;
    address[ACTORS] public actors;

    uint256 public ghostLit;
    uint256 public ghostDonated;
    mapping(uint256 => bool) public ghostIsLit;
    uint256 public lightAttempts;

    constructor(QZForge forge_, MockQZ qz_, MockMachine nft_, address pauser_) {
        forge = forge_;
        qz = qz_;
        nft = nft_;
        pauser = pauser_;
        for (uint256 i = 0; i < ACTORS; ++i) {
            address a = address(uint160(0xA000 + i));
            actors[i] = a;
            qz.mint(a, 50 * N);
            vm.prank(a);
            qz.approve(address(forge), type(uint256).max);
        }
        for (uint256 id = 1; id <= MACHINES; ++id) {
            nft.mint(actors[id % ACTORS], id);
        }
    }

    function light(uint256 callerSeed, uint256 idSeed) external {
        address caller = actors[callerSeed % ACTORS];
        uint256 id = bound(idSeed, 1, MACHINES);
        ++lightAttempts;
        vm.prank(caller);
        try forge.light(id) {
            assertFalseLit(id);
            ghostIsLit[id] = true;
            ++ghostLit;
        } catch {}
    }

    function assertFalseLit(uint256 id) internal view {
        require(!ghostIsLit[id], "lit twice");
    }

    function transferMachine(uint256 idSeed, uint256 toSeed) external {
        uint256 id = bound(idSeed, 1, MACHINES);
        address from = nft.ownerOf(id);
        address to = actors[toSeed % ACTORS];
        vm.prank(from);
        nft.transferFrom(from, to, id);
    }

    function donate(uint256 fromSeed, uint256 amount) external {
        address from = actors[fromSeed % ACTORS];
        amount = bound(amount, 0, qz.balanceOf(from));
        vm.prank(from);
        qz.transfer(address(forge), amount);
        ghostDonated += amount;
    }

    function fund(uint256 toSeed, uint256 amount) external {
        qz.mint(actors[toSeed % ACTORS], bound(amount, 0, 10 * N));
    }

    function reveal() external {
        nft.setRevealed(true);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3 days));
    }

    function pause(bool on) external {
        vm.prank(pauser);
        if (on && !forge.paused()) forge.pause();
        else if (!on && forge.paused()) forge.unpause();
    }
}

contract QZForgeInvariantTest is QZForgeBase {
    LightHandler internal handler;

    function setUp() public override {
        vm.warp(OPENS_AT - 1 days);
        qz = new MockQZ();
        nft = new MockMachine();
        vault = new MockVault(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        forge = new QZForge(address(qz), address(nft), address(vault), TEAM, PAUSER, OPENS_AT);
        handler = new LightHandler(forge, qz, nft, PAUSER);
        targetContract(address(handler));
    }

    /// @dev The headline: the token held always covers the principal, and the principal is N per lit machine.
    function invariant_balanceCoversPrincipalWhichIsNPerLitMachine() public view {
        uint256 principal = forge.lockedPrincipal();
        assertGe(qz.balanceOf(address(forge)), principal, "balance below principal");
        assertEq(principal, handler.N() * forge.litCount(), "principal != N * litCount");
        assertEq(forge.litCount(), handler.ghostLit(), "litCount != ghost");
    }

    /// @dev Everything the forge holds is locked principal or a donation, nothing else moved in or out.
    function invariant_balanceIsPrincipalPlusDonations() public view {
        assertEq(qz.balanceOf(address(forge)), forge.lockedPrincipal() + handler.ghostDonated());
    }

    function invariant_litFlagsMatchGhostAndVault() public view {
        uint256 count;
        for (uint256 id = 1; id <= handler.MACHINES(); ++id) {
            bool lit = forge.isLit(id);
            assertEq(lit, handler.ghostIsLit(id), "isLit != ghost");
            assertEq(lit, vault.isEnrolled(id), "vault out of sync");
            if (lit) ++count;
        }
        assertEq(count, forge.litCount());
        assertEq(vault.registered(), forge.litCount());
    }

    function invariant_litCountNeverExceedsMachines() public view {
        assertLe(forge.litCount(), handler.MACHINES());
    }

    function invariant_immutablesNeverChange() public view {
        assertEq(forge.token(), address(qz));
        assertEq(forge.machine(), address(nft));
        assertEq(forge.vault(), address(vault));
        assertEq(forge.lightAmount(), handler.N());
    }

    function test_handlerReachesLights() public {
        vm.warp(OPENS_AT);
        nft.setRevealed(true);
        handler.light(1, 1);
        handler.light(2, 2);
        assertGt(forge.litCount(), 0);
    }
}
