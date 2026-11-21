// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MintPhase} from "../../src/lib/QZTypes.sol";
import {MockERC20, MockStock} from "../reward/mocks/RewardMocks.sol";
import {QZSystemWorld, QZSystemTreasury} from "./QZSystemWorld.sol";
import {QZSystemHandler} from "./QZSystemHandler.sol";

/// @title QZSystemInvariantTest
/// @notice B6, the cross-contract system invariants of Model B. One world with the real machine, entropy, forge,
///         reward vault, converter and fee splitter (plus the Pons mock and the pool mocks), one handler
///         (`QZSystemHandler`) and eight invariant functions that cover I-a to I-h of docs/PLAN.md B6.
///
///         Runs
///           - default profile (CI): the forge default of 256 runs, depth 64.
///           - `FOUNDRY_PROFILE=invariant`: the profile's 10,000 runs; the conservation invariants (I-a, I-b, I-d, I-g)
///             carry an inline 100,000.
///
///         The invariant state resets to the `setUp` snapshot between runs, so the handler's ghost counters are per run.
///         `afterInvariant` asserts no violation per run and, once `COVERAGE_AFTER_RUNS` runs (summed over the invariant
///         functions) are behind it, that every action class succeeded at least once (`vm.setEnv` counters).
///         `test_everyActionClassSucceeds` proves the same deterministically from the first run.
contract QZSystemInvariantTest is StdInvariant, Test {
    QZSystemWorld internal world;
    QZSystemHandler internal handler;

    uint256 internal constant N = QZConstants.LIGHT_AMOUNT;

    string internal constant KEY_RUNS = "QZ_SYSTEM_INV_RUNS";
    string internal constant KEY_OK = "QZ_SYSTEM_INV_OK_";
    /// @dev Cross-run coverage is judged after this many runs (summed over the invariant functions): enough for the
    ///      rarest prepared action to have succeeded many times over, so a miss means a handler bug, not luck.
    uint256 internal constant COVERAGE_AFTER_RUNS = 1000;

    function setUp() public {
        world = new QZSystemWorld();
        handler = new QZSystemHandler(world);

        bytes4[] memory sel = new bytes4[](25);
        sel[0] = handler.warp.selector;
        sel[1] = handler.mint.selector;
        sel[2] = handler.finalize.selector;
        sel[3] = handler.entropyReveal.selector;
        sel[4] = handler.machineReveal.selector;
        sel[5] = handler.curveBuy.selector;
        sel[6] = handler.curveSell.selector;
        sel[7] = handler.graduate.selector;
        sel[8] = handler.hookAccrue.selector;
        sel[9] = handler.harvest.selector;
        sel[10] = handler.donate.selector;
        sel[11] = handler.transferMachine.selector;
        sel[12] = handler.light.selector;
        sel[13] = handler.openEpoch.selector;
        sel[14] = handler.poke.selector;
        sel[15] = handler.convert.selector;
        sel[16] = handler.convertUsdg.selector;
        sel[17] = handler.claim.selector;
        sel[18] = handler.pauseToggle.selector;
        sel[19] = handler.stockPause.selector;
        sel[20] = handler.treasuryReject.selector;
        sel[21] = handler.attack.selector;
        sel[22] = handler.lockHash.selector;
        sel[23] = handler.rearmReveal.selector;
        sel[24] = handler.claimParked.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    // ───────────── I-a: every minted USDG is split exactly 25 / 75 ─────────────

    /// forge-config: invariant.invariant.runs = 100000
    function invariant_I_a_mintSplit() public view {
        uint256 total = handler.gMintUsdg();
        assertEq(handler.gMintConv() * 4, total, "converter got exactly 25% of every mint");
        assertEq(handler.gMintTre() * 4, total * 3, "treasury got exactly 75% of every mint");
        assertEq(handler.gMintConv() + handler.gMintTre(), total, "no mint USDG left over");
        assertEq(
            handler.gMintByPhase(1) * QZConstants.PRICE_GTD + handler.gMintByPhase(2) * QZConstants.PRICE_FCFS
                + handler.gMintByPhase(3) * QZConstants.PRICE_PUBLIC,
            total,
            "paid == sum of the phase prices"
        );
        assertEq(handler.gMintCount(), world.machine().mintedCount(), "one payment per machine");
        assertEq(
            world.usdg().balanceOf(address(world.machine())), handler.gDonatedUsdgMachine(), "machine holds only donations"
        );
        assertEq(world.usdg().balanceOf(address(world.treasury())), handler.gMintTre(), "treasury USDG == its mint shares");
    }

    // ───────────── I-b: every harvest is split 20 : 7, nothing is stuck ─────────────

    /// forge-config: invariant.invariant.runs = 100000
    function invariant_I_b_harvestSplit() public view {
        uint256 c = world.splitter().totalToConverter();
        uint256 t = world.splitter().totalToTreasury();
        uint256 parked = world.splitter().pendingTreasury();
        // conservation of the splitter: what left plus what is still inside (a parked treasury share included) ==
        // what Pons credited plus donations
        assertEq(
            c + t + address(world.splitter()).balance + world.escrow().balanceOf(address(world.splitter())),
            world.escrow().totalCredited(address(world.splitter())) + handler.gDonatedEthSplitter(),
            "splitter conserves ETH"
        );
        assertEq(c + t + parked, handler.gHarvested(), "swept == toConverter + toTreasury + parked over every harvest");
        assertGe(address(world.splitter()).balance, parked, "the parked share is held in ETH");
        // per harvest (t + parked) * 20 - c * 7 is in [0, 26]
        assertGe((t + parked) * 20, c * 7, "treasury never short of 7/20 of the converter side");
        assertLe((t + parked) * 20, c * 7 + 26 * handler.gHarvests(), "20:7 up to one wei of rounding per harvest");
        assertEq(address(world.treasury()).balance, t, "treasury ETH == its ledger");
        assertEq(address(world.conv()).balance + handler.gWrapped(), c + handler.gDonatedEthConv(), "converter ETH ledger");
    }

    // ───────────── I-c: locked QZ ─────────────

    function invariant_I_c_forgeLocks() public view {
        uint256 lit = world.forge().litCount();
        assertEq(world.forge().lockedPrincipal(), lit * N, "locked == litCount * N");
        assertGe(world.qz().balanceOf(address(world.forge())), lit * N, "forge holds at least what it locked");
        assertEq(
            world.qz().balanceOf(address(world.forge())), lit * N + handler.gQzDonated(), "forge QZ == locks + donations"
        );
        assertGe(world.forge().lockedPrincipal(), handler.lastLocked(), "locked QZ never decreases");
        assertLe(lit, world.machine().mintedCount(), "litCount <= minted");
        assertEq(lit, handler.litLength(), "litCount == lights the handler saw");
        for (uint256 i; i < handler.litLength(); ++i) {
            uint256 id = handler.litIds(i);
            assertTrue(world.forge().isLit(id), "listed machine is lit");
            for (uint256 j; j < i; ++j) {
                assertTrue(handler.litIds(j) != id, "a machine is lit once");
            }
        }
    }

    // ───────────── I-d: reward accounting per track ─────────────

    /// forge-config: invariant.invariant.runs = 100000
    function invariant_I_d_rewards() public view {
        for (uint8 t; t < 10; ++t) {
            MockStock st = world.stocks(t);
            uint256 claimed = world.vault().totalClaimed(t);
            uint256 notified = world.vault().totalNotified(t);
            assertEq(claimed, handler.gClaimed(t), "claimed ledger");
            assertEq(notified, handler.gStockOut(t), "notified == stock the converter funded");
            uint256 sum;
            for (uint256 i; i < handler.litLength(); ++i) {
                sum += world.vault().claimable(handler.litIds(i), t);
            }
            assertLe(claimed + sum, notified, "claimed + claimable <= notified");
            assertGe(st.balanceOf(address(world.vault())), sum, "vault stock >= what is claimable");
            assertEq(
                st.balanceOf(address(world.vault())), notified - claimed + handler.gDonatedStockVault(t), "vault stock ledger"
            );
            assertLe(claimed, handler.gStockOut(t), "claimed <= converter funded");
            assertEq(st.balanceOf(address(world.conv())), handler.gDonatedStockConv(t), "converter keeps no stock");
        }
    }

    // ───────────── I-e: ids and lit set ─────────────

    function invariant_I_e_ids() public view {
        uint256 minted = world.machine().mintedCount();
        assertEq(world.machine().totalSupply(), minted, "supply == minted");
        assertLe(minted, QZConstants.TOTAL_MACHINES, "minted <= 2222");
        (bool exists,) = address(world.machine()).staticcall(abi.encodeWithSignature("ownerOf(uint256)", minted + 1));
        assertFalse(exists, "no machine beyond the counter");
        uint256 held;
        for (uint256 i; i < world.actorCount(); ++i) {
            held += world.machine().balanceOf(world.actorAt(i));
        }
        assertEq(held, minted, "every id has exactly one actor owner");
        for (uint256 id = 1; id <= minted; ++id) {
            assertEq(
                world.vault().isEnrolled(id), world.forge().isLit(id), "vault enrolment follows the forge, nothing else"
            );
            if (world.forge().isLit(id)) assertTrue(world.machine().revealed(), "lit implies revealed");
        }
        for (uint256 i; i < handler.litLength(); ++i) {
            assertLe(handler.litIds(i), minted, "lit machine was minted");
        }
        assertEq(world.machine().balanceOf(world.attacker()), 0, "the attacker never owns a machine");
    }

    // ───────────── I-f: reward rights follow the NFT ─────────────

    function invariant_I_f_rightsFollowNft() public view {
        for (uint8 t; t < 10; ++t) {
            uint256 total;
            for (uint256 i; i < handler.litLength(); ++i) {
                total += world.vault().claimable(handler.litIds(i), t);
            }
            uint256 byOwner;
            for (uint256 a; a < world.actorCount(); ++a) {
                address who = world.actorAt(a);
                for (uint256 i; i < handler.litLength(); ++i) {
                    uint256 id = handler.litIds(i);
                    if (world.machine().ownerOf(id) == who) byOwner += world.vault().claimable(id, t);
                }
            }
            assertEq(byOwner, total, "every claimable unit has exactly one current owner");
        }
    }

    // ───────────── I-g: converter pots ─────────────

    /// forge-config: invariant.invariant.runs = 100000
    function invariant_I_g_converterAccounting() public view {
        uint256 sumW;
        uint256 sumU;
        for (uint8 t; t < 10; ++t) {
            (uint256 pw, uint256 pu) = world.conv().trackPot(t);
            sumW += pw;
            sumU += pu;
            if (world.vault().weightOf(t) == 0) {
                assertEq(handler.gStockOut(t), 0, "a track without a standard machine never converted");
            }
        }
        assertEq(sumW, world.conv().totalTrackWeth(), "sum of WETH pots == assigned WETH");
        assertEq(sumU, world.conv().totalTrackUsdg(), "sum of USDG pots == assigned USDG");
        uint256 wethBal = MockERC20(address(world.weth())).balanceOf(address(world.conv()));
        uint256 usdgBal = world.usdg().balanceOf(address(world.conv()));
        assertGe(wethBal, sumW, "WETH balance covers the pots");
        assertGe(usdgBal, sumU, "USDG balance covers the pots");
        assertEq(
            wethBal + handler.gWethSpent(), handler.gWrapped() + handler.gDonatedWethConv(), "WETH ledger: wrapped + donated"
        );
        assertEq(
            usdgBal + handler.gUsdgSpent(), handler.gMintConv() + handler.gDonatedUsdgConv(), "USDG ledger: mint share + donated"
        );
    }

    // ───────────── I-h: permissions, double light, oracle ─────────────

    function invariant_I_h_permissionsAndOracle() public view {
        assertEq(handler.violationCount(), 0, handler.firstViolation());
    }

    // ───────────── per run and cross run coverage ─────────────

    function afterInvariant() public {
        assertEq(handler.violationCount(), 0, handler.firstViolation());

        uint256 runs = vm.envOr(KEY_RUNS, uint256(0)) + 1;
        vm.setEnv(KEY_RUNS, vm.toString(runs));
        string memory missing;
        for (uint256 a; a < handler.ACTIONS(); ++a) {
            string memory key = string.concat(KEY_OK, vm.toString(a));
            uint256 c = vm.envOr(key, uint256(0)) + handler.oks(a);
            vm.setEnv(key, vm.toString(c));
            if (c == 0) missing = string.concat(missing, vm.toString(a), " ");
        }
        if (runs >= COVERAGE_AFTER_RUNS) {
            assertEq(bytes(missing).length, 0, string.concat("action classes that never succeeded: ", missing));
        }
    }

    // ───────────── deterministic coverage ─────────────

    uint256 internal constant A_WARP = 0;
    uint256 internal constant A_MINT = 1;
    uint256 internal constant A_FINALIZE = 2;
    uint256 internal constant A_ENTROPY = 3;
    uint256 internal constant A_MREVEAL = 4;
    uint256 internal constant A_BUY = 5;
    uint256 internal constant A_SELL = 6;
    uint256 internal constant A_GRADUATE = 7;
    uint256 internal constant A_ACCRUE = 8;
    uint256 internal constant A_HARVEST = 9;
    uint256 internal constant A_DONATE = 10;
    uint256 internal constant A_TRANSFER = 11;
    uint256 internal constant A_LIGHT = 12;
    uint256 internal constant A_OPEN = 13;
    uint256 internal constant A_POKE = 14;
    uint256 internal constant A_CONVERT = 15;
    uint256 internal constant A_CONVERT_USDG = 16;
    uint256 internal constant A_CLAIM = 17;
    uint256 internal constant A_PAUSE = 18;
    uint256 internal constant A_STOCK_PAUSE = 19;
    uint256 internal constant A_TREASURY = 20;
    uint256 internal constant A_ATTACK = 21;
    uint256 internal constant A_LOCK = 22;
    uint256 internal constant A_REARM = 23;
    uint256 internal constant A_CLAIM_PARKED = 24;

    /// @dev Every action of the handler, driven with its prerequisites, succeeds on a fresh world and the oracle stays
    ///      quiet. This is the guard against a handler whose calls all revert silently.
    function test_everyActionClassSucceeds() public {
        // mint in the GTD window, then warp through the other phases and mint again
        handler.drive(A_MINT, 0, 6, 1);
        handler.drive(A_WARP, 3, 1, 1);
        handler.drive(A_MINT, 3, 6, 1);
        handler.drive(A_BUY, 1, 1 ether, 0);
        handler.drive(A_SELL, 1, 1000, 0);
        // attack on register needs an unlit but revealed machine: do it first
        // the unlocked window passes: re-arm, then lock the hash of the block after the new finalize block
        handler.drive(A_FINALIZE, 5, 0, 3);
        handler.drive(A_REARM, 0, 0, 1);
        handler.drive(A_LOCK, 0, 0, 3);
        handler.drive(A_ENTROPY, 0, 0, 1);
        handler.drive(A_MREVEAL, 0, 0, 0);
        handler.drive(A_ATTACK, 0, 0, 0);
        for (uint256 i; i < 6; ++i) {
            // the first light also builds the late-joiner case and may light several machines
            if (world.forge().litCount() < world.machine().mintedCount()) handler.drive(A_LIGHT, i * 4 + 1, i, 1);
        }
        handler.drive(A_OPEN, 0, 0, 1);
        handler.drive(A_POKE, 1, 0, 1);
        handler.drive(A_CONVERT, 2, 5e17, 1);
        handler.drive(A_CONVERT_USDG, 2, 1e8, 1);
        handler.drive(A_CONVERT, 3, 5e17, 1);
        handler.drive(A_CONVERT_USDG, 4, 1e8, 1);
        handler.drive(A_CLAIM, 0, 3, 1);
        handler.drive(A_CLAIM, 2, 3, 1);
        for (uint256 k; k < 8; ++k) {
            handler.drive(A_DONATE, k, 1, 1e15);
        }
        handler.drive(A_TRANSFER, 1, 7, 0);
        handler.drive(A_TRANSFER, 2, 8, 0);
        handler.drive(A_PAUSE, 0, 1, 0);
        handler.drive(A_PAUSE, 1, 1, 0);
        handler.drive(A_PAUSE, 2, 1, 0);
        handler.drive(A_STOCK_PAUSE, 2, 1, 0);
        handler.drive(A_TREASURY, 1, 0, 0);
        handler.drive(A_HARVEST, 9, 0, 1);
        // the refusing treasury parked its share: an outsider cannot claim it, the treasury can once it accepts ETH
        handler.drive(A_TREASURY, 1, 0, 0);
        handler.drive(A_CLAIM_PARKED, 0, 0, 0);
        handler.drive(A_CLAIM_PARKED, 1, 0, 1);
        handler.drive(A_GRADUATE, 1, 0, 0);
        handler.drive(A_ACCRUE, 1 ether, 1000, 0);
        handler.drive(A_HARVEST, 9, 0, 1);
        // variant 0 (register by a non-forge) needs an unlit machine: it ran above, before the lights
        for (uint256 k = 1; k < 11; ++k) {
            handler.drive(A_ATTACK, k, k + 1, 0);
        }
        handler.drive(A_CLAIM, 1, 3, 1);

        assertEq(handler.violationCount(), 0, handler.firstViolation());
        for (uint256 a; a < handler.ACTIONS(); ++a) {
            assertGt(handler.oks(a), 0, string.concat("action class never succeeded: ", vm.toString(a)));
        }
        assertGt(handler.gHarvests(), 1, "curve and hook harvests");
        assertGt(handler.gRelicLit(), 0, "a relic was lit");
        assertGt(handler.gStandardLit(), 0, "a standard machine was lit");
        assertGt(handler.gTransfers(), 0, "machines moved");
        uint256 stockOut;
        for (uint8 t; t < 10; ++t) {
            stockOut += handler.gStockOut(t);
        }
        assertGt(stockOut, 0, "rewards were converted");
        for (uint8 t; t < 10; ++t) {
            assertEq(world.vault().totalClaimed(t), handler.gClaimed(t));
        }
        invariant_I_a_mintSplit();
        invariant_I_b_harvestSplit();
        invariant_I_c_forgeLocks();
        invariant_I_d_rewards();
        invariant_I_e_ids();
        invariant_I_f_rightsFollowNft();
        invariant_I_g_converterAccounting();
        invariant_I_h_permissionsAndOracle();
    }

    /// @dev A randomly ordered, fully prepared drive never fails for a reason other than a plain refusal: the handler
    ///      has no bug that would hide behind `fail_on_revert = false`.
    function testFuzz_preparedHandlerNeverBreaks(uint256 seed) public {
        bytes32 refused = keccak256(abi.encodeWithSignature("Error(string)", "rejected"));
        for (uint256 i; i < 30; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            try handler.drive(r % handler.ACTIONS(), r >> 8, r >> 40, (r >> 72) | 1) {}
            catch (bytes memory reason) {
                assertEq(keccak256(reason), refused, "handler action reverted for a reason other than refusal");
            }
        }
        assertEq(handler.violationCount(), 0, handler.firstViolation());
    }

    /// @dev Regression for a handler bug found at run 21,297 of the 10k campaign. A non-keeper poke after a long warp
    ///      put the converter in fallback mode, so the prepared keeper pokes of the next convert started too early.
    function test_prepConvertAfterAFallbackPoke() public {
        handler.drive(A_MINT, 0, 6, 1);
        handler.drive(A_OPEN, 1, 0, 1);
        handler.drive(A_WARP, 17935, 5269, 1);
        handler.drive(A_POKE, 1e27, 0, 0);
        handler.drive(A_CONVERT, 48879, 1 ether, 129);
        assertEq(handler.violationCount(), 0, handler.firstViolation());
    }

    /// @dev Sold out: 2222 distinct public wallets mint, the 2223rd is refused, every id has one owner, 25/75 holds
    ///      for all 2222 payments and the two relic machines light.
    function test_soldOutSplitAndIds() public {
        QZSystemWorld w = world;
        vm.warp(w.START() + 49 hours);
        uint256 price = QZConstants.PRICE_PUBLIC;
        uint256 convBefore = w.usdg().balanceOf(address(w.conv()));
        for (uint256 i; i < QZConstants.TOTAL_MACHINES; ++i) {
            address who = address(uint160(0x100000 + i));
            w.usdg().mint(who, price);
            vm.startPrank(who);
            w.usdg().approve(address(w.machine()), price);
            uint256 id = w.machine().mint(new bytes32[](0));
            vm.stopPrank();
            assertEq(id, i + 1);
        }
        assertEq(w.machine().mintedCount(), QZConstants.TOTAL_MACHINES);
        assertEq(uint256(w.machine().phase()), uint256(MintPhase.Closed));
        address late = address(uint160(0x900000));
        w.usdg().mint(late, price);
        vm.startPrank(late);
        w.usdg().approve(address(w.machine()), price);
        address soldOut = address(w.machine());
        (bool minted,) = soldOut.call(abi.encodeWithSignature("mint(bytes32[])", new bytes32[](0)));
        assertFalse(minted, "the 2223rd mint is refused");
        vm.stopPrank();
        assertEq(w.usdg().balanceOf(address(w.conv())) - convBefore, QZConstants.TOTAL_MACHINES * price / 4);
        assertEq(w.usdg().balanceOf(address(w.treasury())), QZConstants.TOTAL_MACHINES * price * 3 / 4);
        assertEq(w.usdg().balanceOf(address(w.machine())), 0);

        // sold out finalizes before the public window ends
        vm.roll(block.number + 1);
        w.machine().finalizeMint();
        {
            uint256 f = w.machine().finalizeBlock();
            vm.roll(f + 2);
            vm.setBlockhash(f + 1, keccak256("sold out"));
            w.machine().lockHash();
        }
        address entropy = address(w.entropy());
        bytes32 link = w.chain(1);
        address revealer = w.revealer();
        vm.prank(revealer);
        (bool revealed,) = entropy.call(abi.encodeWithSignature("reveal(uint64,bytes32)", uint64(1), link));
        assertTrue(revealed, "entropy reveal");
        w.machine().reveal();
        vm.warp(w.LIGHTING_OPENS_AT());
        uint256 relics;
        for (uint256 id = 1; id <= QZConstants.TOTAL_MACHINES && relics < 2; ++id) {
            (,, bool relic) = w.machine().traitsOf(id);
            if (!relic) continue;
            address owner_ = w.machine().ownerOf(id);
            vm.deal(owner_, 0.05 ether);
            vm.startPrank(owner_);
            w.curve().buy{value: 0.05 ether}(0.05 ether, 0, owner_);
            w.qz().approve(address(w.forge()), N);
            w.forge().light(id);
            vm.stopPrank();
            ++relics;
        }
        assertEq(relics, 2);
        assertEq(w.vault().relicCount(), 2);
        assertEq(w.forge().litCount(), 2);
        assertEq(w.forge().lockedPrincipal(), 2 * N);
    }
}
