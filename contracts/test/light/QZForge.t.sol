// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {QZConstants} from "../../src/lib/QZConstants.sol";
import {QZForge} from "../../src/light/QZForge.sol";
import {IQZForge} from "../../src/interfaces/IQZForge.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {QZForgeBase} from "./QZForgeBase.sol";
import {MockQZ, MockMachine, MockVault, FeeToken, BonusToken, ReentrantToken} from "./mocks/LightMocks.sol";

contract QZForgeTest is QZForgeBase {
    event Lit(uint256 indexed machineId, address indexed owner);
    event Paused(address by);
    event Unpaused(address by);

    // ───────────── constructor and views ─────────────

    function test_constructor_storesEverything() public view {
        assertEq(forge.token(), address(qz));
        assertEq(forge.machine(), address(nft));
        assertEq(forge.vault(), address(vault));
        assertEq(forge.owner(), TEAM);
        assertEq(forge.pauser(), PAUSER);
        assertEq(forge.lightingOpensAt(), OPENS_AT);
        assertEq(forge.lightAmount(), 100_000e18);
        assertEq(forge.lightAmount(), QZConstants.LIGHT_AMOUNT);
        assertEq(forge.litCount(), 0);
        assertEq(forge.lockedPrincipal(), 0);
        assertFalse(forge.paused());
        assertEq(vault.forge(), address(forge));
    }

    function test_constructor_revertsOnZeroAddress() public {
        address a = address(qz);
        address z = address(0);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZForge(z, a, a, a, a, OPENS_AT);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZForge(a, z, a, a, a, OPENS_AT);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZForge(a, a, z, a, a, OPENS_AT);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZForge(a, a, a, z, a, OPENS_AT);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZForge(a, a, a, a, z, OPENS_AT);
    }

    function test_constructor_revertsOnZeroOpensAt() public {
        address a = address(qz);
        vm.expectRevert(QZForge.ZeroOpensAt.selector);
        new QZForge(a, a, a, a, a, 0);
    }

    // ───────────── light: happy path ─────────────

    function test_light_locksExactlyN_registers_emits() public {
        _give(alice, 7);
        vm.expectEmit(true, true, false, true, address(forge));
        emit Lit(7, alice);
        vm.prank(alice);
        forge.light(7);

        assertTrue(forge.isLit(7));
        assertEq(forge.litCount(), 1);
        assertEq(forge.lockedPrincipal(), N);
        assertEq(qz.balanceOf(address(forge)), N);
        assertEq(qz.balanceOf(alice), 0);
        assertTrue(vault.isEnrolled(7));
        assertEq(vault.registered(), 1);
    }

    function test_light_atExactOpeningSecond() public {
        vm.warp(OPENS_AT);
        _give(alice, 1);
        vm.prank(alice);
        forge.light(1);
        assertTrue(forge.isLit(1));
    }

    function test_light_manyMachinesAccumulate() public {
        for (uint256 i = 1; i <= 5; ++i) {
            address who = address(uint160(0x1000 + i));
            _give(who, i);
            vm.prank(who);
            forge.light(i);
            assertEq(forge.litCount(), i);
            assertEq(forge.lockedPrincipal(), i * N);
        }
        assertEq(qz.balanceOf(address(forge)), 5 * N);
        assertFalse(forge.isLit(6));
    }

    function test_light_takesOnlyN_whenCallerHoldsMore() public {
        _give(alice, 1);
        qz.mint(alice, 5 * N);
        vm.prank(alice);
        forge.light(1);
        assertEq(qz.balanceOf(alice), 5 * N);
        assertEq(qz.balanceOf(address(forge)), N);
    }

    // ───────────── light: every revert path ─────────────

    function test_light_revertsWhenPaused() public {
        _give(alice, 1);
        vm.prank(PAUSER);
        forge.pause();
        vm.prank(alice);
        vm.expectRevert(IQZErrors.EnforcedPause.selector);
        forge.light(1);
    }

    function test_light_revertsBeforeOpening() public {
        _give(alice, 1);
        vm.warp(OPENS_AT - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.LightingNotOpen.selector, OPENS_AT));
        forge.light(1);
    }

    function test_light_revertsForNonOwner() public {
        _give(alice, 1);
        qz.mint(bob, N);
        vm.startPrank(bob);
        qz.approve(address(forge), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.NotMachineOwner.selector, 1, bob));
        forge.light(1);
        vm.stopPrank();
    }

    function test_light_approvedOperatorIsNotTheOwner() public {
        _give(alice, 1);
        vm.prank(alice);
        nft.approve(bob, 1);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        qz.mint(bob, N);
        vm.startPrank(bob);
        qz.approve(address(forge), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.NotMachineOwner.selector, 1, bob));
        forge.light(1);
        vm.stopPrank();
    }

    function test_light_revertsForNonexistentMachine() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        forge.light(99);
    }

    function test_light_revertsBeforeReveal() public {
        nft.setRevealed(false);
        _give(alice, 1);
        vm.prank(alice);
        vm.expectRevert(IQZForge.NotRevealed.selector);
        forge.light(1);
    }

    function test_light_revertsWhenAlreadyLit() public {
        _give(alice, 1);
        vm.startPrank(alice);
        forge.light(1);
        qz.mint(alice, N);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.AlreadyLit.selector, 1));
        forge.light(1);
        vm.stopPrank();
        assertEq(forge.litCount(), 1);
        assertEq(qz.balanceOf(address(forge)), N);
    }

    function test_light_revertsWithoutAllowance() public {
        nft.mint(alice, 1);
        qz.mint(alice, N);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(forge), 0, N));
        forge.light(1);
        assertFalse(forge.isLit(1));
        assertEq(forge.litCount(), 0);
    }

    function test_light_revertsWithoutBalance() public {
        nft.mint(alice, 1);
        qz.mint(alice, N - 1);
        vm.startPrank(alice);
        qz.approve(address(forge), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, N - 1, N));
        forge.light(1);
        vm.stopPrank();
        assertFalse(forge.isLit(1));
        assertEq(forge.litCount(), 0);
    }

    function test_light_revertsWhenVaultRejects_stateRolledBack() public {
        _give(alice, 1);
        vault.setFailNext(true);
        vm.prank(alice);
        vm.expectRevert(MockVault.Boom.selector);
        forge.light(1);
        assertFalse(forge.isLit(1));
        assertEq(forge.litCount(), 0);
        assertEq(qz.balanceOf(alice), N);
        assertEq(qz.balanceOf(address(forge)), 0);

        vault.setFailNext(false);
        vm.prank(alice);
        forge.light(1);
        assertTrue(forge.isLit(1));
    }

    function test_light_afterUnpause() public {
        _give(alice, 1);
        vm.prank(PAUSER);
        forge.pause();
        vm.prank(PAUSER);
        forge.unpause();
        vm.prank(alice);
        forge.light(1);
        assertTrue(forge.isLit(1));
    }

    function test_light_twoMachinesNeedTwoN_oneApprovalDoesNotStack() public {
        nft.mint(alice, 1);
        nft.mint(alice, 2);
        qz.mint(alice, N + N / 2);
        vm.startPrank(alice);
        qz.approve(address(forge), type(uint256).max);
        forge.light(1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, N / 2, N));
        forge.light(2);
        vm.stopPrank();
        assertTrue(forge.isLit(1));
        assertFalse(forge.isLit(2));
        assertEq(forge.litCount(), 1);
    }

    // ───────────── deflationary / bonus tokens ─────────────

    function _forgeFor(address tkn) internal returns (QZForge f, MockVault v) {
        v = new MockVault(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        f = new QZForge(tkn, address(nft), address(v), TEAM, PAUSER, OPENS_AT);
    }

    function test_light_feeOnTransferTokenReverts() public {
        FeeToken fee = new FeeToken(100);
        (QZForge f,) = _forgeFor(address(fee));
        nft.mint(alice, 1);
        fee.mint(alice, 2 * N);
        vm.startPrank(alice);
        fee.approve(address(f), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.LockAmountMismatch.selector, N, N - N / 100));
        f.light(1);
        vm.stopPrank();
        assertEq(f.litCount(), 0);
        assertEq(fee.balanceOf(address(f)), 0);
    }

    function test_light_oneWeiFeeStillReverts() public {
        FeeToken fee = new FeeToken(1);
        (QZForge f,) = _forgeFor(address(fee));
        nft.mint(alice, 1);
        fee.mint(alice, 2 * N);
        vm.startPrank(alice);
        fee.approve(address(f), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.LockAmountMismatch.selector, N, N - N / 10_000));
        f.light(1);
        vm.stopPrank();
    }

    function test_light_bonusTokenReverts() public {
        BonusToken bonus = new BonusToken(1);
        (QZForge f,) = _forgeFor(address(bonus));
        nft.mint(alice, 1);
        bonus.mint(alice, N);
        vm.startPrank(alice);
        bonus.approve(address(f), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.LockAmountMismatch.selector, N, N + 1));
        f.light(1);
        vm.stopPrank();
        assertEq(f.litCount(), 0);
    }

    function test_light_zeroFeeTokenWorks() public {
        FeeToken fee = new FeeToken(0);
        (QZForge f,) = _forgeFor(address(fee));
        nft.mint(alice, 1);
        fee.mint(alice, N);
        vm.startPrank(alice);
        fee.approve(address(f), type(uint256).max);
        f.light(1);
        vm.stopPrank();
        assertEq(fee.balanceOf(address(f)), N);
    }

    // ───────────── ownership moves, the light stays ─────────────

    function test_lightStaysWithTheMachineAfterTransfer() public {
        _give(alice, 1);
        vm.prank(alice);
        forge.light(1);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertTrue(forge.isLit(1));
        assertEq(forge.litCount(), 1);
        assertEq(forge.lockedPrincipal(), N);
        assertEq(qz.balanceOf(address(forge)), N);

        qz.mint(bob, N);
        vm.startPrank(bob);
        qz.approve(address(forge), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.AlreadyLit.selector, 1));
        forge.light(1);
        vm.stopPrank();

        qz.mint(alice, N);
        vm.startPrank(alice);
        qz.approve(address(forge), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.NotMachineOwner.selector, 1, alice));
        forge.light(1);
        vm.stopPrank();
    }

    function test_transferBeforeLightingMovesTheRightToLight() public {
        _give(alice, 1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        qz.mint(bob, N);
        vm.prank(bob);
        qz.approve(address(forge), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.NotMachineOwner.selector, 1, alice));
        forge.light(1);

        vm.prank(bob);
        forge.light(1);
        assertTrue(forge.isLit(1));
        assertEq(qz.balanceOf(bob), 0);
        assertEq(qz.balanceOf(address(forge)), N);
    }

    // ───────────── donations ─────────────

    function test_donationNeverCountsAsPrincipal() public {
        qz.mint(address(this), 3 * N);
        qz.transfer(address(forge), 3 * N);
        assertEq(forge.lockedPrincipal(), 0);
        assertEq(forge.litCount(), 0);

        _give(alice, 1);
        vm.prank(alice);
        forge.light(1);
        assertEq(forge.lockedPrincipal(), N);
        assertEq(forge.litCount(), 1);
        assertEq(qz.balanceOf(address(forge)), 4 * N);
    }

    function test_donationRightBeforeLightDoesNotChangeTheLockedAmount() public {
        _give(alice, 1);
        qz.mint(address(this), N / 2);
        qz.transfer(address(forge), N / 2);
        vm.prank(alice);
        forge.light(1);
        assertEq(qz.balanceOf(alice), 0);
        assertEq(qz.balanceOf(address(forge)), N + N / 2);
        assertEq(forge.lockedPrincipal(), N);
    }

    // ───────────── pause ─────────────

    function test_pause_onlyPauser() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotPauser.selector, alice));
        forge.pause();
        vm.prank(TEAM);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotPauser.selector, TEAM));
        forge.pause();

        vm.expectEmit(false, false, false, true, address(forge));
        emit Paused(PAUSER);
        vm.prank(PAUSER);
        forge.pause();
        assertTrue(forge.paused());
    }

    function test_unpause_onlyPauser() public {
        vm.prank(PAUSER);
        forge.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotPauser.selector, alice));
        forge.unpause();

        vm.expectEmit(false, false, false, true, address(forge));
        emit Unpaused(PAUSER);
        vm.prank(PAUSER);
        forge.unpause();
        assertFalse(forge.paused());
    }

    function test_pause_stateGuards() public {
        vm.prank(PAUSER);
        vm.expectRevert(IQZErrors.ExpectedPause.selector);
        forge.unpause();
        vm.startPrank(PAUSER);
        forge.pause();
        vm.expectRevert(IQZErrors.EnforcedPause.selector);
        forge.pause();
        vm.stopPrank();
    }

    function test_pauseDoesNotFreezeLockedState() public {
        _give(alice, 1);
        vm.prank(alice);
        forge.light(1);
        vm.prank(PAUSER);
        forge.pause();
        assertTrue(forge.isLit(1));
        assertEq(forge.lockedPrincipal(), N);
        assertEq(forge.litCount(), 1);
    }

    // ───────────── reentrancy ─────────────

    function test_reentrancy_viaTokenHook_isBlocked() public {
        ReentrantToken rt = new ReentrantToken();
        (QZForge f, MockVault v) = _forgeFor(address(rt));
        nft.mint(alice, 1);
        nft.mint(address(rt), 2);
        rt.mint(alice, N);
        rt.arm(f, 2, false);
        vm.startPrank(alice);
        rt.approve(address(f), type(uint256).max);
        f.light(1);
        vm.stopPrank();

        assertEq(rt.lastRevert(), QZForge.Reentrancy.selector);
        assertFalse(rt.reentered());
        assertTrue(f.isLit(1));
        assertFalse(f.isLit(2));
        assertEq(f.litCount(), 1);
        assertEq(v.registered(), 1);
        assertEq(rt.balanceOf(address(f)), N);
    }

    function test_reentrancy_sameIdViaTokenHook_isBlocked() public {
        ReentrantToken rt = new ReentrantToken();
        (QZForge f,) = _forgeFor(address(rt));
        nft.mint(address(rt), 1);
        rt.arm(f, 1, true);
        rt.mint(address(rt), N);
        vm.expectRevert(QZForge.Reentrancy.selector);
        vm.prank(address(rt));
        f.light(1);
        assertEq(f.litCount(), 0);
    }

    function test_reentrancy_bubblingHookRevertsTheWholeCall() public {
        ReentrantToken rt = new ReentrantToken();
        (QZForge f,) = _forgeFor(address(rt));
        nft.mint(alice, 1);
        nft.mint(address(rt), 2);
        rt.mint(alice, N);
        rt.arm(f, 2, true);
        vm.startPrank(alice);
        rt.approve(address(f), type(uint256).max);
        vm.expectRevert(QZForge.Reentrancy.selector);
        f.light(1);
        vm.stopPrank();
        assertEq(f.litCount(), 0);
        assertFalse(f.isLit(1));
    }

    function test_reentrancy_viaVaultCallback_isBlocked() public {
        _give(alice, 1);
        _give(address(vault), 2);
        vault.setReenter(2);
        vm.prank(alice);
        forge.light(1);
        assertEq(vault.lastRevert(), QZForge.Reentrancy.selector);
        assertFalse(forge.isLit(2));
        assertEq(forge.litCount(), 1);
    }

    function test_lockIsReleasedAfterRevert() public {
        _give(alice, 1);
        _give(bob, 2);
        vault.setFailNext(true);
        vm.prank(alice);
        vm.expectRevert(MockVault.Boom.selector);
        forge.light(1);
        vault.setFailNext(false);
        vm.prank(bob);
        forge.light(2);
        assertEq(forge.litCount(), 1);
    }

    // ───────────── no way out ─────────────

    function test_noExitSelectorsAnswer() public {
        string[18] memory sigs = [
            "withdraw()",
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "withdrawAll()",
            "unlock(uint256)",
            "release(uint256)",
            "sweep(address)",
            "rescue(address,uint256)",
            "recoverERC20(address,uint256)",
            "recover(address)",
            "emergencyWithdraw()",
            "execute(address,bytes)",
            "multicall(bytes[])",
            "transfer(address,uint256)",
            "approve(address,uint256)",
            "upgradeTo(address)",
            "setOwner(address)",
            "transferOwnership(address)"
        ];
        qz.mint(address(forge), 10 * N);
        for (uint256 i = 0; i < sigs.length; ++i) {
            (bool ok, bytes memory ret) = address(forge).call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, sigs[i]);
            assertEq(ret.length, 0, sigs[i]);
        }
        (bool okFallback,) = address(forge).call("");
        assertFalse(okFallback);
        (bool okEth,) = address(forge).call{value: 0}(hex"deadbeef");
        assertFalse(okEth);
        assertEq(qz.balanceOf(address(forge)), 10 * N);
    }

    function test_abiIsExactlyTheInterface() public view {
        string memory json = vm.readFile("out/QZForge.sol/QZForge.json");
        string[14] memory allowed = [
            "light",
            "litCount",
            "isLit",
            "lockedPrincipal",
            "lightAmount",
            "lightingOpensAt",
            "token",
            "machine",
            "vault",
            "owner",
            "pauser",
            "paused",
            "pause",
            "unpause"
        ];
        uint256 functions;
        for (uint256 i = 0; vm.keyExists(json, string.concat(".abi[", vm.toString(i), "]")); ++i) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            bytes32 kind = keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".type"))));
            assertTrue(kind != keccak256("receive") && kind != keccak256("fallback"), "receive or fallback in the ABI");
            if (kind != keccak256("function")) continue;
            ++functions;
            bytes32 name = keccak256(bytes(vm.parseJsonString(json, string.concat(entry, ".name"))));
            bool found;
            for (uint256 j = 0; j < allowed.length; ++j) {
                if (name == keccak256(bytes(allowed[j]))) found = true;
            }
            assertTrue(found, "function outside the interface");
        }
        assertEq(functions, allowed.length, "function count");
    }

    /// @dev Walks the runtime code opcode by opcode (skipping push data) and refuses every instruction that could
    ///      move the lock around: DELEGATECALL, CALLCODE, SELFDESTRUCT, CREATE, CREATE2.
    function test_runtimeCodeHasNoDangerousOpcodes() public view {
        bytes memory code = address(forge).code;
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff && op != 0xf0 && op != 0xf5, "dangerous opcode");
            if (op >= 0x60 && op <= 0x7f) i += uint256(op) - 0x5f;
            ++i;
        }
    }

    function test_cannotReceiveEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(forge).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ───────────── fuzz: caller, id, amount, time ─────────────

    function testFuzz_onlyTheOwnerLights(address caller, uint256 id, address holder) public {
        vm.assume(holder != address(0) && caller != address(0) && holder.code.length == 0 && caller.code.length == 0);
        vm.assume(caller != holder);
        nft.mint(holder, id);
        qz.mint(caller, N);
        qz.mint(holder, N);
        vm.prank(caller);
        qz.approve(address(forge), type(uint256).max);
        vm.prank(holder);
        qz.approve(address(forge), type(uint256).max);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.NotMachineOwner.selector, id, caller));
        forge.light(id);
        assertFalse(forge.isLit(id));

        vm.prank(holder);
        forge.light(id);
        assertTrue(forge.isLit(id));
        assertEq(forge.lockedPrincipal(), N);
        assertEq(qz.balanceOf(address(forge)), N);
    }

    function testFuzz_unknownIdsRevert(uint256 id) public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        forge.light(id);
        assertFalse(forge.isLit(id));
    }

    function testFuzz_lightingTimeGate(uint64 t) public {
        _give(alice, 1);
        vm.warp(t);
        vm.prank(alice);
        if (t < OPENS_AT) {
            vm.expectRevert(abi.encodeWithSelector(IQZForge.LightingNotOpen.selector, OPENS_AT));
            forge.light(1);
            assertFalse(forge.isLit(1));
        } else {
            forge.light(1);
            assertTrue(forge.isLit(1));
        }
    }

    function testFuzz_balanceBelowNNeverLights(uint256 balance) public {
        balance = bound(balance, 0, N - 1);
        nft.mint(alice, 1);
        qz.mint(alice, balance);
        vm.startPrank(alice);
        qz.approve(address(forge), type(uint256).max);
        vm.expectRevert();
        forge.light(1);
        vm.stopPrank();
        assertEq(forge.litCount(), 0);
        assertEq(qz.balanceOf(alice), balance);
    }

    function testFuzz_allowanceBelowNNeverLights(uint256 allowance) public {
        allowance = bound(allowance, 0, N - 1);
        nft.mint(alice, 1);
        qz.mint(alice, 2 * N);
        vm.startPrank(alice);
        qz.approve(address(forge), allowance);
        vm.expectRevert();
        forge.light(1);
        vm.stopPrank();
        assertEq(forge.litCount(), 0);
    }

    function testFuzz_anyTransferFeeReverts(uint256 feeBps) public {
        feeBps = bound(feeBps, 1, 10_000);
        FeeToken fee = new FeeToken(feeBps);
        (QZForge f,) = _forgeFor(address(fee));
        nft.mint(alice, 1);
        fee.mint(alice, 2 * N);
        vm.startPrank(alice);
        fee.approve(address(f), type(uint256).max);
        uint256 received = N - N * feeBps / 10_000;
        vm.expectRevert(abi.encodeWithSelector(IQZForge.LockAmountMismatch.selector, N, received));
        f.light(1);
        vm.stopPrank();
        assertEq(f.litCount(), 0);
        assertEq(fee.balanceOf(address(f)), 0);
    }

    function testFuzz_anyBonusReverts(uint256 bonus) public {
        bonus = bound(bonus, 1, 1_000_000e18);
        BonusToken tkn = new BonusToken(bonus);
        (QZForge f,) = _forgeFor(address(tkn));
        nft.mint(alice, 1);
        tkn.mint(alice, N);
        vm.startPrank(alice);
        tkn.approve(address(f), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IQZForge.LockAmountMismatch.selector, N, N + bonus));
        f.light(1);
        vm.stopPrank();
    }

    function testFuzz_donationsNeverMoveThePrincipal(uint256 donation, uint8 lights) public {
        donation = bound(donation, 0, 1_000_000_000e18);
        lights = uint8(bound(lights, 0, 12));
        qz.mint(address(this), donation);
        qz.transfer(address(forge), donation);
        for (uint256 i = 1; i <= lights; ++i) {
            address who = address(uint160(0x2000 + i));
            _give(who, i);
            vm.prank(who);
            forge.light(i);
        }
        assertEq(forge.litCount(), lights);
        assertEq(forge.lockedPrincipal(), uint256(lights) * N);
        assertEq(qz.balanceOf(address(forge)), donation + uint256(lights) * N);
    }

    function testFuzz_transferAfterLightKeepsState(address to, uint256 id) public {
        vm.assume(to != address(0) && to != alice && to.code.length == 0);
        _give(alice, id);
        vm.prank(alice);
        forge.light(id);
        vm.prank(alice);
        nft.transferFrom(alice, to, id);
        assertTrue(forge.isLit(id));
        assertEq(forge.litCount(), 1);
        assertEq(forge.lockedPrincipal(), N);
        assertEq(qz.balanceOf(address(forge)), N);
    }
}
