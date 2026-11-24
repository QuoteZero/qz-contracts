// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QZTestFaucet} from "../../src/testnet/QZTestFaucet.sol";
import {TestQz} from "./TestMocks.sol";

contract QZTestFaucetTest is Test {
    QZTestFaucet internal faucet;
    TestQz internal qz;
    address internal relayer = makeAddr("relayer");
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000 / 1 days * 1 days + 3 hours);
        qz = new TestQz();
        faucet = new QZTestFaucet(qz, relayer, owner);
        qz.mint(address(faucet), 1_000_000_000e18);
    }

    function test_claimPaysTheAmountAndSetsTheCooldown() public {
        vm.prank(relayer);
        faucet.claim(alice);
        assertEq(qz.balanceOf(alice), 200_000e18);
        assertEq(faucet.nextClaimAt(alice), block.timestamp + 1 days);
        assertEq(faucet.nextClaimAt(bob), 0);
        assertEq(faucet.claimedToday(), 1);
    }

    function test_secondClaimInADayRevertsWithTheEndOfTheCooldown() public {
        vm.prank(relayer);
        faucet.claim(alice);
        uint256 end = block.timestamp + 1 days;
        vm.warp(block.timestamp + 1 days - 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(QZTestFaucet.Cooldown.selector, end));
        faucet.claim(alice);
        vm.warp(end);
        vm.prank(relayer);
        faucet.claim(alice);
        assertEq(qz.balanceOf(alice), 400_000e18);
    }

    function test_onlyTheRelayerClaims() public {
        vm.expectRevert(QZTestFaucet.NotRelayer.selector);
        faucet.claim(alice);
        vm.prank(owner);
        vm.expectRevert(QZTestFaucet.NotRelayer.selector);
        faucet.claim(alice);
        vm.prank(alice);
        vm.expectRevert(QZTestFaucet.NotRelayer.selector);
        faucet.claim(alice);
    }

    function test_dailyCapStopsTheCountAndRestartsAtUtcMidnight() public {
        uint256 cap = faucet.DAILY_CAP();
        for (uint256 i; i < cap; ++i) {
            vm.prank(relayer);
            faucet.claim(address(uint160(0x1000 + i)));
        }
        assertEq(faucet.claimedToday(), cap);
        assertEq(faucet.dailyCapRemaining(), 0);
        vm.prank(relayer);
        vm.expectRevert(QZTestFaucet.DailyCapReached.selector);
        faucet.claim(alice);
        uint256 reset = faucet.nextResetAt();
        assertEq(reset % 1 days, 0);
        vm.warp(reset);
        assertEq(faucet.claimedToday(), 0);
        vm.prank(relayer);
        faucet.claim(alice);
        assertEq(faucet.claimedToday(), 1);
    }

    function test_pauseBlocksClaimsAndOnlyTheOwnerPauses() public {
        vm.expectRevert(QZTestFaucet.NotOwner.selector);
        faucet.setPaused(true);
        vm.prank(owner);
        faucet.setPaused(true);
        vm.prank(relayer);
        vm.expectRevert(QZTestFaucet.ClaimsPaused.selector);
        faucet.claim(alice);
        vm.prank(owner);
        faucet.setPaused(false);
        vm.prank(relayer);
        faucet.claim(alice);
    }

    function test_ownerWithdrawsLeftoverOnlyToItself() public {
        vm.expectRevert(QZTestFaucet.NotOwner.selector);
        faucet.withdraw(1);
        vm.prank(owner);
        faucet.withdraw(5e18);
        assertEq(qz.balanceOf(owner), 5e18);
    }

    function test_emptyFaucetRevertsAndKeepsNoState() public {
        vm.prank(owner);
        faucet.withdraw(1_000_000_000e18);
        vm.prank(relayer);
        vm.expectRevert();
        faucet.claim(alice);
        assertEq(faucet.nextClaimAt(alice), 0);
        assertEq(faucet.claimedToday(), 0);
    }

    function test_zeroRecipientAndMainnetAreRefused() public {
        vm.prank(relayer);
        vm.expectRevert(QZTestFaucet.ZeroAddress.selector);
        faucet.claim(address(0));
        vm.chainId(4663);
        vm.expectRevert(QZTestFaucet.WrongChain.selector);
        new QZTestFaucet(qz, relayer, owner);
    }

    function testFuzz_neverMoreThanTheCapPerDay(uint8 extra) public {
        uint256 cap = faucet.DAILY_CAP();
        uint256 tries = cap + (extra % 20);
        uint256 ok;
        for (uint256 i; i < tries; ++i) {
            vm.prank(relayer);
            try faucet.claim(address(uint160(0x2000 + i))) {
                ++ok;
            } catch {}
        }
        assertEq(ok, cap);
        assertEq(qz.balanceOf(address(faucet)), 1_000_000_000e18 - cap * 200_000e18);
    }
}
