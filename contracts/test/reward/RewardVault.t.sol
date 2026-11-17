// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {QZRewardVault} from "../../src/reward/QZRewardVault.sol";
import {IQZRewardVault} from "../../src/interfaces/IQZRewardVault.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MockMachine, MockConverter, MockStock} from "./mocks/RewardMocks.sol";

/// @notice SPEC §2.5 / I6 / T9 / T10 for `QZRewardVault`. The machine contract (unit C3) and the converter are mocks;
///         this test contract plays `QZCore` (the only caller of `onHardwire`).
contract RewardVaultTest is Test {
    QZRewardVault internal vault;
    MockMachine internal machine;
    MockConverter internal conv;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant P = QZConstants.ACC_PRECISION;

    function setUp() public virtual {
        machine = new MockMachine();
        conv = new MockConverter();
        vault = new QZRewardVault(address(this), address(machine), address(conv));
    }

    // ───────────── helpers ─────────────

    function _lit(uint256 id, address owner, uint8 tier, uint8 track) internal {
        machine.set(id, owner, tier, track, false);
        vault.onHardwire(id);
    }

    function _relic(uint256 id, address owner) internal {
        machine.set(id, owner, 0, 0, true);
        vault.onHardwire(id);
    }

    function _notify(uint8 track, uint256 amount) internal {
        conv.deliver(vault, track, amount);
    }

    function _claim(address who, uint256 id, uint8 track) internal {
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tracks = new uint8[](1);
        ids[0] = id;
        tracks[0] = track;
        vm.prank(who);
        vault.claim(ids, tracks);
    }

    function _stock(uint8 track) internal view returns (MockStock) {
        return conv.stocks(track);
    }

    // ───────────── §2.5 mandatory sequences ─────────────

    /// 3 machines tier I (W = 30), no relic, 4 x notify(1): sum of claimable <= notified and <= vault balance at every step.
    function test_adversarialW30_neverOverpays() public {
        _lit(1, alice, 1, 0);
        _lit(2, bob, 1, 0);
        _lit(3, carol, 1, 0);
        assertEq(vault.weightOf(0), 30);

        for (uint256 n = 1; n <= 4; ++n) {
            _notify(0, 1);
            uint256 sum = vault.claimable(1, 0) + vault.claimable(2, 0) + vault.claimable(3, 0);
            assertLe(sum, n, "claimable above notified");
            assertLe(sum, _stock(0).balanceOf(address(vault)), "claimable above balance");
        }
        _claim(alice, 1, 0);
        _claim(bob, 2, 0);
        _claim(carol, 3, 0);
        assertLe(vault.totalClaimed(0), 4);
        assertLe(vault.totalClaimed(0) + 0, vault.totalNotified(0));
    }

    /// checker #4: 1 machine tier I (W = 10), notify(1), then hardwire a tier II machine (weight 15):
    /// its claimable is 0 and `claim` does not revert.
    function test_checker4_lateTierIIGetsNothingAndClaimDoesNotRevert() public {
        _lit(1, alice, 1, 0);
        _notify(0, 1);
        assertEq(vault.claimable(1, 0), 1);

        _lit(2, bob, 2, 0);
        assertEq(vault.weightOf(0), 25);
        assertEq(vault.claimable(2, 0), 0, "new machine must start at 0");
        _claim(bob, 2, 0);
        assertEq(_stock(0).balanceOf(bob), 0);

        _claim(alice, 1, 0);
        assertEq(_stock(0).balanceOf(alice), 1);
        assertEq(_stock(0).balanceOf(address(vault)), 0);
    }

    /// A machine hardwired after earlier notifies gets none of their fractions either.
    function test_lateHardwireGetsNoOldFraction() public {
        _lit(1, alice, 1, 0);
        _lit(2, bob, 1, 0);
        _lit(3, carol, 1, 0);
        for (uint256 i; i < 3; ++i) {
            _notify(0, 1);
        }
        _lit(4, alice, 4, 0);
        assertEq(vault.claimable(4, 0), 0);

        _notify(0, 1000);
        // W = 30 + 40 = 70: machine 4 gets 40/70 of 1000 = 571 (floor), machine 1 gets 10/70 of 1000 + its old part
        assertEq(vault.claimable(4, 0), 571);
        assertLe(vault.claimable(1, 0) + vault.claimable(2, 0) + vault.claimable(3, 0) + vault.claimable(4, 0), 1003);
    }

    /// A relic lit after a `notify` does not receive the relic share of that earlier `notify`.
    function test_lateRelicGetsNoOldRelicShare() public {
        _lit(1, alice, 1, 0);
        _relic(2221, bob);
        _notify(0, 4000); // rel = 4000 * 1000 * 1 / (10000 * 2) = 200 for the single lit relic
        assertEq(vault.claimable(2221, 0), 200);
        assertEq(vault.claimable(1, 0), 3800);

        _relic(2222, carol);
        assertEq(vault.claimable(2222, 0), 0, "late relic starts at 0");
        _notify(0, 4000); // R = 2: rel = 400 total, 200 each
        assertEq(vault.claimable(2222, 0), 200);
        assertEq(vault.claimable(2221, 0), 400);
    }

    /// A relic draws from every track, a standard machine only from its own.
    function test_relicClaimsAnyTrackStandardOnlyOwn() public {
        _lit(1, alice, 1, 0);
        _lit(2, alice, 1, 3);
        _relic(2221, bob);
        _notify(0, 4000);
        _notify(3, 8000);
        assertEq(vault.claimable(2221, 0), 200);
        assertEq(vault.claimable(2221, 3), 400);
        assertEq(vault.claimable(1, 3), 0, "standard machine of track 0 owns nothing on track 3");

        uint256[] memory ids = new uint256[](2);
        uint8[] memory tracks = new uint8[](2);
        ids[0] = 2221;
        ids[1] = 2221;
        tracks[0] = 0;
        tracks[1] = 3;
        vm.prank(bob);
        vault.claim(ids, tracks);
        assertEq(_stock(0).balanceOf(bob), 200);
        assertEq(_stock(3).balanceOf(bob), 400);
    }

    /// With no relic lit the whole amount goes to the standard machines (unlit relic slots fall back).
    function test_noRelicLit_standardGetsAll() public {
        _lit(1, alice, 1, 0);
        _notify(0, 1000);
        assertEq(vault.claimable(1, 0), 1000);
    }

    /// `notify` only for tracks with W > 0: a lit relic never makes an empty track payable.
    function test_notifyEmptyTrackReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.TrackNotActive.selector, uint8(5)));
        this._deliver(5, 1);

        _relic(2221, alice);
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.TrackNotActive.selector, uint8(5)));
        this._deliver(5, 1);
    }

    function _deliver(uint8 track, uint256 amount) external {
        conv.deliver(vault, track, amount);
    }

    // ───────────── access ─────────────

    function test_onlyCoreEnrols() public {
        machine.set(1, alice, 1, 0, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotCore.selector, alice));
        vault.onHardwire(1);

        vault.onHardwire(1);
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.AlreadyEnrolled.selector, uint256(1)));
        vault.onHardwire(1);
    }

    function test_onlyConverterNotifies() public {
        _lit(1, alice, 1, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.NotConverter.selector, alice));
        vault.notify(0, 1);
    }

    function test_notifyZeroAndBadTrackRevert() public {
        _lit(1, alice, 1, 0);
        vm.expectRevert(IQZErrors.ZeroAmount.selector);
        this._deliver(0, 0);
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.BadTrack.selector, uint8(10)));
        vm.prank(address(conv));
        vault.notify(10, 1);
    }

    function test_onlyOwnerOfMachineClaims() public {
        _lit(1, alice, 1, 0);
        _notify(0, 100);
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tracks = new uint8[](1);
        ids[0] = 1;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.NotOwnerOfMachine.selector, uint256(1), bob));
        vault.claim(ids, tracks);
    }

    /// A machine that is not at home is owned by the adapter: the adapter has no claim path (design B).
    function test_machineHeldByAdapterCannotClaim() public {
        address adapter = makeAddr("adapter");
        _lit(1, alice, 1, 0);
        _notify(0, 100);
        vm.prank(alice);
        machine.transferFrom(alice, adapter, 1);
        // the previous owner can no longer claim
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tracks = new uint8[](1);
        ids[0] = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.NotOwnerOfMachine.selector, uint256(1), alice));
        vault.claim(ids, tracks);
        // reward keeps accruing, and the owner after coming home gets it all
        _notify(0, 100);
        vm.prank(adapter);
        machine.transferFrom(adapter, bob, 1);
        _claim(bob, 1, 0);
        assertEq(_stock(0).balanceOf(bob), 200);
    }

    function test_lengthMismatchAndBadTrackRevert() public {
        _lit(1, alice, 1, 0);
        uint256[] memory ids = new uint256[](2);
        uint8[] memory tracks = new uint8[](1);
        vm.expectRevert(IQZRewardVault.LengthMismatch.selector);
        vault.claim(ids, tracks);

        ids = new uint256[](1);
        ids[0] = 1;
        tracks[0] = 10;
        vm.expectRevert(abi.encodeWithSelector(IQZRewardVault.BadTrack.selector, uint8(10)));
        vault.claim(ids, tracks);
    }

    function test_doubleClaimPaysOnce() public {
        _lit(1, alice, 1, 0);
        _notify(0, 100);
        _claim(alice, 1, 0);
        _claim(alice, 1, 0);
        assertEq(_stock(0).balanceOf(alice), 100);
        assertEq(vault.totalClaimed(0), 100);
    }

    function test_transferMovesUnclaimedToNewOwner() public {
        _lit(1, alice, 1, 0);
        _notify(0, 100);
        vm.prank(alice);
        machine.transferFrom(alice, bob, 1);
        _claim(bob, 1, 0);
        assertEq(_stock(0).balanceOf(bob), 100);
        assertEq(_stock(0).balanceOf(alice), 0);
    }

    // ───────────── T10: a frozen stock freezes only its track ─────────────

    function _twoTrackBatch() internal returns (uint256[] memory ids, uint8[] memory tracks) {
        _lit(1, alice, 1, 0);
        _lit(2, alice, 1, 1);
        _notify(0, 100);
        _notify(1, 100);
        ids = new uint256[](2);
        tracks = new uint8[](2);
        ids[0] = 1;
        ids[1] = 2;
        tracks[0] = 0;
        tracks[1] = 1;
    }

    function test_T10_pausedStockFreezesOnlyItsTrack() public {
        (uint256[] memory ids, uint8[] memory tracks) = _twoTrackBatch();
        _stock(0).setPaused(true);

        vm.expectEmit(true, false, false, false, address(vault));
        emit IQZRewardVault.TrackFrozen(0, "");
        vm.prank(alice);
        vault.claim(ids, tracks);

        assertEq(_stock(1).balanceOf(alice), 100, "other track pays");
        assertEq(_stock(0).balanceOf(alice), 0);
        assertTrue(vault.trackFrozen(0));
        assertFalse(vault.trackFrozen(1));
        assertEq(vault.claimable(1, 0), 100, "frozen reward is kept, not lost");
        assertEq(vault.totalClaimed(0), 0);
        assertEq(vault.totalClaimed(1), 100);

        // notify keeps working on the frozen track (the converter pulls stock via transferFrom; here paused means it
        // reverts, so the WETH of that track waits in the converter)
        vm.expectRevert();
        this._deliver(0, 10);

        // thaw: unpause, claim again
        _stock(0).setPaused(false);
        vm.expectEmit(true, false, false, false, address(vault));
        emit IQZRewardVault.TrackThawed(0);
        _claim(alice, 1, 0);
        assertFalse(vault.trackFrozen(0));
        assertEq(_stock(0).balanceOf(alice), 100);
    }

    /// Reviewer A I-3 / T10: a claimant whose own transfer fails (here: a blocklisted recipient) must not mark the whole
    /// track frozen: the vault and the token still work for every other holder.
    function test_T10_blocklistedClaimerDoesNotFreezeTheTrack() public {
        _lit(1, alice, 1, 1);
        _lit(2, bob, 1, 1);
        _notify(1, 100);
        _stock(1).setBlocked(alice, true);

        vm.recordLogs();
        _claim(alice, 1, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IQZRewardVault.TrackFrozen.selector, "no track-wide event");
        }
        assertEq(_stock(1).balanceOf(alice), 0);
        assertFalse(vault.trackFrozen(1), "one failing recipient is not a frozen track");
        assertEq(vault.claimable(1, 1), 50, "alice keeps her claim right");

        _claim(bob, 2, 1);
        assertEq(_stock(1).balanceOf(bob), 50);
        assertFalse(vault.trackFrozen(1));

        _stock(1).setBlocked(alice, false);
        _claim(alice, 1, 1);
        assertEq(_stock(1).balanceOf(alice), 50);
    }

    function test_T10_blocklistedVaultFreezesOnlyItsTrack() public {
        (uint256[] memory ids, uint8[] memory tracks) = _twoTrackBatch();
        _stock(0).setBlocked(address(vault), true);
        vm.prank(alice);
        vault.claim(ids, tracks);
        assertEq(_stock(1).balanceOf(alice), 100);
        assertTrue(vault.trackFrozen(0));
        assertFalse(vault.trackFrozen(1));
    }

    function test_T10_adminBurnFreezesOnlyItsTrack() public {
        (uint256[] memory ids, uint8[] memory tracks) = _twoTrackBatch();
        _stock(0).adminBurn(address(vault), 100);
        vm.prank(alice);
        vault.claim(ids, tracks);
        assertEq(_stock(1).balanceOf(alice), 100);
        assertEq(_stock(0).balanceOf(alice), 0);
        assertTrue(vault.trackFrozen(0));
        assertFalse(vault.trackFrozen(1));
        assertEq(vault.claimable(1, 0), 100, "the claim right is not erased, the issuer burned the asset");

        // an earlier burn does not wedge new rewards: the next notify pulls and proves its own tokens
        _notify(0, 50);
        assertEq(vault.claimable(1, 0), 150);
        assertEq(_stock(0).balanceOf(address(vault)), 50);
    }

    /// Frozen claims leave no half-applied state: debt and totals are exactly as before the failed attempt.
    function test_T10_failedClaimRestoresState() public {
        _lit(1, alice, 1, 0);
        _relic(2221, bob);
        _notify(0, 4000);
        _stock(0).setPaused(true);
        uint256 cStd = vault.claimable(1, 0);
        uint256 cRel = vault.claimable(2221, 0);
        _claim(alice, 1, 0);
        _claim(bob, 2221, 0);
        assertEq(vault.claimable(1, 0), cStd);
        assertEq(vault.claimable(2221, 0), cRel);
        assertEq(vault.totalClaimed(0), 0);
    }

    // ───────────── T9: reentrancy ─────────────

    /// A stock token that calls back into `claim` during the payout reaches the reentrancy guard.
    /// Reverting callback: the payout fails and is retried cleanly afterwards. Swallowed callback: the payout
    /// goes through once. Either way exactly 100 units leave the vault.
    function test_T9_reentrantStockCannotDoubleClaim() public {
        _lit(1, alice, 1, 0);
        _notify(0, 100);
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tracks = new uint8[](1);
        ids[0] = 1;
        bytes memory reenter = abi.encodeCall(IQZRewardVault.claim, (ids, tracks));

        _stock(0).setReentry(address(vault), reenter, false);
        _claim(alice, 1, 0);
        assertEq(_stock(0).balanceOf(alice), 0, "reverting callback fails the payout");
        assertEq(vault.claimable(1, 0), 100);
        assertEq(vault.totalClaimed(0), 0);
        assertTrue(vault.trackFrozen(0));

        _stock(0).setReentry(address(vault), reenter, true);
        _claim(alice, 1, 0);
        assertEq(_stock(0).balanceOf(alice), 100, "swallowed callback: paid once");
        assertEq(vault.totalClaimed(0), 100);
        assertEq(vault.claimable(1, 0), 0);
        assertEq(_stock(0).balanceOf(address(vault)), 0);
    }

    // ───────────── bounds ─────────────

    function test_largeAmountsDoNotOverflow() public {
        _lit(1, alice, 4, 0);
        _relic(2221, bob);
        _notify(0, 1e27);
        uint256 c = vault.claimable(1, 0);
        assertEq(c, 1e27 - 1e27 / 20);
        _claim(alice, 1, 0);
        _claim(bob, 2221, 0);
        assertLe(vault.totalClaimed(0), 1e27);
    }

    // ───────────── I6 fuzz: random notify / hardwire / claim / transfer ─────────────

    uint256[] internal _stdIds;
    uint256[] internal _relicIds;
    uint256 internal _nextStd = 1;
    uint256 internal _nextRelic = 2221;

    function _user(uint256 x) internal view returns (address) {
        uint256 k = x % 3;
        return k == 0 ? alice : (k == 1 ? bob : carol);
    }

    /// @dev One random program over machines on tracks 0 and 1 and up to 2 relics.
    function testFuzz_I6_conservation(uint256 seed) public {
        for (uint256 s; s < 40; ++s) {
            seed = uint256(keccak256(abi.encode(seed, s)));
            _step(seed);
            _assertConserved();
        }
    }

    function _step(uint256 seed) internal {
        uint256 op = seed % 6;
        uint256 r = seed >> 8;
        if (op == 0 && _stdIds.length < 64) {
            _lit(_nextStd, _user(r >> 8), uint8((r >> 4) % 4) + 1, uint8(r % 2));
            _stdIds.push(_nextStd++);
        } else if (op == 1 && _relicIds.length < 2) {
            _relic(_nextRelic, _user(r >> 8));
            _relicIds.push(_nextRelic++);
        } else if (op == 2) {
            uint8 track = uint8(r % 2);
            if (vault.weightOf(track) != 0) _notify(track, 1 + (r >> 4) % 1e24);
        } else if (op == 3 && _stdIds.length != 0) {
            uint256 id = _stdIds[(r >> 4) % _stdIds.length];
            (,, uint8 tr,) = machine.machines(id);
            _claim(machine.ownerOf(id), id, tr);
        } else if (op == 4 && _relicIds.length != 0) {
            uint256 id = _relicIds[(r >> 4) % _relicIds.length];
            _claim(machine.ownerOf(id), id, uint8((r >> 12) % 2));
        } else if (op == 5 && _stdIds.length != 0) {
            uint256 id = _stdIds[(r >> 4) % _stdIds.length];
            address from = machine.ownerOf(id);
            vm.prank(from);
            machine.transferFrom(from, _user(r >> 20), id);
        }
    }

    function _assertConserved() internal view {
        for (uint8 t; t < 2; ++t) {
            uint256 sum;
            uint256 holders;
            for (uint256 i; i < _stdIds.length; ++i) {
                (,, uint8 tr,) = machine.machines(_stdIds[i]);
                if (tr == t) {
                    sum += vault.claimable(_stdIds[i], t);
                    ++holders;
                }
            }
            for (uint256 i; i < _relicIds.length; ++i) {
                sum += vault.claimable(_relicIds[i], t);
                ++holders;
            }
            uint256 notified = vault.totalNotified(t);
            uint256 claimed = vault.totalClaimed(t);
            assertLe(claimed + sum, notified, "I6: claimed + claimable <= notified");
            assertGe(_stock(t).balanceOf(address(vault)), sum, "I6: balance >= claimable");
            assertEq(_stock(t).balanceOf(address(vault)) + claimed, notified, "vault holds exactly the unclaimed stock");
            // dust is bounded by one unit per lit machine and relic plus the carried fraction (< 1 unit)
            assertLe(notified - claimed - sum, holders + 1, "dust bound");
        }
    }
}
