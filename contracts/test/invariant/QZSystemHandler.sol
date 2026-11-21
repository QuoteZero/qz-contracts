// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MintPhase} from "../../src/lib/QZTypes.sol";
import {QZEntropy} from "../../src/random/QZEntropy.sol";
import {QZMachine} from "../../src/machine/QZMachine.sol";
import {QZForge} from "../../src/light/QZForge.sol";
import {QZFeeSplitter} from "../../src/fee/QZFeeSplitter.sol";
import {QZConverter} from "../../src/reward/QZConverter.sol";
import {QZRewardVault} from "../../src/reward/QZRewardVault.sol";
import {MOCK_PonsFactory, MOCK_PonsFeeEscrow, MOCK_PonsCurve, MOCK_PonsHook} from "../../script/testnet/MockPons.sol";
import {MockERC20, MockStock} from "../reward/mocks/RewardMocks.sol";
import {QZOnion} from "../random/QZOnion.sol";

import {QZSystemWorld, QZSystemTreasury} from "./QZSystemWorld.sol";

/// @title QZSystemHandler
/// @notice Drives the whole Model B system (`QZSystemWorld`) with random action sequences and keeps the ghost ledgers
///         the system invariants (`QZSystemInvariant.t.sol`) read.
///
///         Model based. Every action computes its expected outcome from the views of the real contracts, BEFORE any
///         `vm.prank` (a prank is consumed by the next call, a getter included), then makes the call in a try/catch.
///         An expected-success that reverts, or an expected-revert that succeeds, is a violation (`_viol`), never a
///         silent skip. Nothing here re-implements a contract: it only states what must hold (split ratios, who may
///         call, who owns a machine).
///
///         `prep = true` makes the handler do the prerequisite real calls first (open the mint phase, mint, finalize,
///         lock the block hash and reveal the entropy link and the machine, buy QZ and approve, warp past the lighting date, keeper pokes, fund
///         and open an epoch), so deep paths are reached inside a short sequence. The oracle still decides the verdict.
///
///         Return policy. An action that did nothing (an expected rejection, or no precondition) REVERTS with
///         `"rejected"`; a violation never reverts, so it survives to the invariant check. The `show_metrics` table is
///         therefore truthful: calls minus reverts are the successful state-changing calls per action.
contract QZSystemHandler is Test {
    // ───────────── action ids ─────────────

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
    uint256 public constant ACTIONS = 25;

    uint256 internal constant N = QZConstants.LIGHT_AMOUNT;
    uint256 internal constant SUPPLY = QZConstants.TOTAL_MACHINES;
    uint256 internal constant MAX_ACTORS_PER_CLAIM = 3;

    // ───────────── world ─────────────

    QZSystemWorld public immutable W;
    MockERC20 internal immutable usdg;
    QZMachine internal immutable machine;
    QZForge internal immutable forge;
    QZRewardVault internal immutable vault;
    QZConverter internal immutable conv;
    QZFeeSplitter internal immutable splitter;
    QZEntropy internal immutable entropy;
    MOCK_PonsFactory internal immutable pons;
    MOCK_PonsFeeEscrow internal immutable escrow;
    MOCK_PonsCurve internal immutable curve;
    MOCK_PonsHook internal immutable hook;
    MockERC20 internal immutable qz;
    QZSystemTreasury internal immutable treasury;
    address internal immutable pauser;
    address internal immutable keeper;
    address internal immutable executor;
    address internal immutable revealer;
    address internal immutable attacker;
    address internal immutable ownerAddr;

    address[] internal actors;

    // ───────────── bookkeeping ─────────────

    /// @notice Successful state-changing calls of this run, per action.
    uint256[25] public oks;

    uint256 public violationCount;
    string public firstViolation;
    uint256 internal _v0;

    // mint
    uint256 public gMintCount;
    uint256 public gMintUsdg;
    uint256 public gMintConv;
    uint256 public gMintTre;
    uint256[4] public gMintByPhase;
    uint256[4] public gMintUsdgByPhase;
    uint256 public finalizedIdx;
    bool public handlerFinalized;
    /// @dev When the pauser last paused the machine; the mint clock model of `_mintClock` needs it.
    uint256 public machinePausedAt;
    /// @dev Spacing the keeper must keep between two observations of a track in normal mode.
    uint256 internal constant KEEPER_SPACING = 60;
    mapping(uint8 => uint256) internal lastObservation;

    // lit machines
    uint256[] public litIds;
    mapping(uint256 => uint8) public litTrack;
    mapping(uint256 => bool) public litRelic;
    uint256 public gRelicLit;
    uint256 public gStandardLit;

    // fee path
    uint256 public gHarvests;
    uint256 public gHarvested;
    uint256 public gDonatedEthSplitter;
    uint256 public gDonatedEthConv;
    uint256 public gDonatedWethConv;
    uint256 public gDonatedUsdgConv;
    uint256 public gDonatedUsdgMachine;
    uint256 public gWrapped;
    uint256 public gWethSpent;
    uint256 public gUsdgSpent;
    uint256 public gFeeSpecialBurn;
    uint256[10] public gDonatedStockVault;
    uint256[10] public gDonatedStockConv;
    uint256[10] public gStockOut;
    uint256[10] public gClaimed;
    uint256 public gTransfers;
    uint256 public gQzDonated;

    uint256 public lastLocked;
    uint256 public lastForgeQz;

    constructor(QZSystemWorld w) {
        W = w;
        usdg = w.usdg();
        machine = w.machine();
        forge = w.forge();
        vault = w.vault();
        conv = w.conv();
        splitter = w.splitter();
        entropy = w.entropy();
        pons = w.pons();
        escrow = w.escrow();
        curve = w.curve();
        hook = w.hook();
        qz = MockERC20(address(w.qz()));
        treasury = w.treasury();
        pauser = w.pauser();
        keeper = w.keeper();
        executor = w.executor();
        revealer = w.revealer();
        attacker = w.attacker();
        ownerAddr = w.owner();
        for (uint256 i; i < w.actorCount(); ++i) {
            actors.push(w.actorAt(i));
        }
    }

    // ───────────── plumbing ─────────────

    function _begin(uint256 a) internal {
        a; // action id (kept for readability at the call sites)
        _v0 = violationCount;
        _checkMonotonic();
    }

    function _ok(uint256 a) internal {
        ++oks[a];
    }

    /// @dev Nothing happened: roll the call back so the metrics table counts it as a revert. A violation flagged in
    ///      this call is kept.
    function _reject() internal view {
        if (violationCount == _v0) revert("rejected");
    }

    function _viol(string memory what) internal {
        if (violationCount++ == 0) firstViolation = what;
    }

    function _checkMonotonic() internal {
        uint256 locked = forge.lockedPrincipal();
        uint256 bal = qz.balanceOf(address(forge));
        if (locked < lastLocked) _viol("locked QZ decreased");
        if (bal < lastForgeQz) _viol("forge QZ balance decreased");
        lastLocked = locked;
        lastForgeQz = bal;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _exec(address who, address target, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = target.call(data);
    }

    function _must(address who, address target, bytes memory data, string memory what) internal returns (bool ok) {
        ok = _exec(who, target, data);
        if (!ok) _viol(what);
    }

    function litLength() external view returns (uint256) {
        return litIds.length;
    }

    function oksOf(uint256 a) external view returns (uint256) {
        return oks[a];
    }

    // ───────────── time ─────────────

    function warp(uint256 kind, uint256 dt) external {
        _begin(A_WARP);
        kind %= 9;
        if (kind == 8) {
            // blocks only: reaches the end of the `lockHash` window
            vm.roll(block.number + bound(dt, 1, 300));
            _ok(A_WARP);
            return;
        }
        uint256 t = block.timestamp;
        if (kind == 0) {
            t += bound(dt, 1, 5 minutes);
        } else if (kind == 1) {
            t += bound(dt, 1, 2 hours);
        } else if (kind == 2) {
            t += bound(dt, 1, 2 days);
        } else {
            uint256 target = kind == 3
                ? machine.mintStart()
                : kind == 4 ? machine.gtdEnd() : kind == 5 ? machine.fcfsEnd() : kind == 6 ? machine.publicEnd() : forge.lightingOpensAt();
            if (target > t) t = target + (dt % 2) - (kind == 7 ? 1 : 0);
            else t += 1;
        }
        vm.warp(t);
        vm.roll(block.number + 1 + (dt % 3));
        _ok(A_WARP);
    }

    // ───────────── mint ─────────────

    function mint(uint256 seed, uint256 count, bool prep) external {
        _begin(A_MINT);
        count = bound(count, 1, 6);
        if (prep && !_prepOpenMint()) {
            _reject();
            return;
        }
        uint256 done;
        for (uint256 i; i < count; ++i) {
            if (_mintOne(seed + i * 7, prep)) ++done;
        }
        if (done == 0) {
            _reject();
            return;
        }
        _ok(A_MINT);
    }

    /// @dev Unpause the machine and move into a phase that can mint.
    function _prepOpenMint() internal returns (bool) {
        _unpause(0);
        if (machine.phase() == MintPhase.Pending && machine.mintStart() > block.timestamp) vm.warp(machine.mintStart());
        MintPhase p = machine.phase();
        return p != MintPhase.Pending && p != MintPhase.Closed;
    }

    function _priceFor(MintPhase p) internal pure returns (uint256) {
        if (p == MintPhase.Gtd) return QZConstants.PRICE_GTD;
        if (p == MintPhase.Fcfs) return QZConstants.PRICE_FCFS;
        return QZConstants.PRICE_PUBLIC;
    }

    function _eligible(MintPhase p, address who) internal view returns (bool) {
        return p == MintPhase.Public || (p == MintPhase.Gtd && W.isGtd(who)) || (p == MintPhase.Fcfs && W.isFcfs(who));
    }

    function _pickMinter(uint256 seed, bool prep, MintPhase p) internal view returns (address) {
        if (!prep) return _actor(seed);
        for (uint256 k; k < actors.length; ++k) {
            address a = _actor(seed + k);
            if (!machine.hasMinted(a) && _eligible(p, a)) return a;
        }
        return address(0);
    }

    function _proofFor(address who, MintPhase p) internal view returns (bytes32[] memory) {
        if (p == MintPhase.Gtd) return W.gtdProofOf(W.isGtd(who) ? who : actors[0]);
        if (p == MintPhase.Fcfs) return W.fcfsProofOf(W.isFcfs(who) ? who : actors[W.GTD_ACTORS()]);
        return new bytes32[](0);
    }

    struct MintSnap {
        uint256 conv;
        uint256 tre;
        uint256 mac;
        uint256 who;
        uint256 minted;
        uint256 price;
        MintPhase p;
        bool expect;
    }

    function _mintOne(uint256 seed, bool prep) internal returns (bool done) {
        MintSnap memory s;
        s.p = machine.phase();
        address who = _pickMinter(seed, prep, s.p);
        if (who == address(0)) return false;
        bytes32[] memory proof = _proofFor(who, s.p);
        s.price = _priceFor(s.p);
        s.minted = machine.mintedCount();
        s.expect = (s.p == MintPhase.Gtd || s.p == MintPhase.Fcfs || s.p == MintPhase.Public) && !machine.paused()
            && !machine.hasMinted(who) && _eligible(s.p, who) && s.minted < SUPPLY;

        uint256 bal = usdg.balanceOf(who);
        if (bal < s.price) usdg.mint(who, s.price - bal);
        vm.prank(who);
        usdg.approve(address(machine), s.price);
        s.conv = usdg.balanceOf(address(conv));
        s.tre = usdg.balanceOf(address(treasury));
        s.mac = usdg.balanceOf(address(machine));
        s.who = usdg.balanceOf(who);

        vm.prank(who);
        try machine.mint(proof) returns (uint256 id) {
            _onMint(who, id, s);
            done = true;
        } catch {
            if (s.expect) _viol("mint reverted though open, eligible, unpaused and not sold out");
        }
    }

    function _onMint(address who, uint256 id, MintSnap memory s) internal {
        if (!s.expect) _viol("mint succeeded though it must not");
        uint256 dConv = usdg.balanceOf(address(conv)) - s.conv;
        uint256 dTre = usdg.balanceOf(address(treasury)) - s.tre;
        if (id != s.minted + 1) _viol("machine id is not the next id");
        if (machine.ownerOf(id) != who) _viol("minter does not own the new machine");
        if (dConv != s.price * QZConstants.MINT_REWARD_BPS / QZConstants.BPS) _viol("mint: converter share is not 25%");
        if (dConv + dTre != s.price) _viol("mint: split does not add up to the price");
        if (usdg.balanceOf(address(machine)) != s.mac) _viol("mint: machine holds USDG after mint");
        if (s.who - usdg.balanceOf(who) != s.price) _viol("mint: payer did not pay exactly the price");
        if (machine.mintedCount() != s.minted + 1) _viol("mint: count off");
        gMintCount++;
        gMintUsdg += s.price;
        gMintConv += dConv;
        gMintTre += dTre;
        gMintByPhase[uint256(s.p)]++;
        gMintUsdgByPhase[uint256(s.p)] += s.price;
    }

    // ───────────── finalize, entropy, reveal ─────────────

    function finalize(bool prep) external {
        _begin(A_FINALIZE);
        if (prep) _prepFinalize();
        if (!_finalizeNow()) {
            _reject();
            return;
        }
        _ok(A_FINALIZE);
    }

    /// @dev Unpause (a pause freezes the mint clock) and wait for the end of the public window.
    function _prepFinalize() internal {
        if (machine.mintFinalized()) return;
        _unpause(0);
        if (machine.mintedCount() < SUPPLY && block.timestamp < machine.publicEnd()) vm.warp(machine.publicEnd());
    }

    /// @dev The time the mint schedule is measured in: now, or the freeze point while the machine is paused.
    function _mintClock() internal view returns (uint256) {
        if (!machine.paused()) return block.timestamp;
        uint256 s = machinePausedAt > machine.mintStart() ? machinePausedAt : machine.mintStart();
        return s < block.timestamp ? s : block.timestamp;
    }

    function _finalizeNow() internal returns (bool done) {
        bool expect = !machine.mintFinalized()
            && (machine.mintedCount() >= SUPPLY || _mintClock() >= machine.publicEnd());
        uint256 idx = entropy.revealedIndex();
        vm.roll(block.number + 1);
        try machine.finalizeMint() {
            if (!expect) _viol("finalizeMint succeeded though it must not");
            finalizedIdx = idx;
            handlerFinalized = true;
            if (!machine.mintFinalized() || machine.phase() != MintPhase.Closed) _viol("finalize did not close the mint");
            if (machine.finalizeBlock() != block.number) _viol("finalizeBlock is not the finalize block");
            done = true;
        } catch {
            if (expect) _viol("finalizeMint reverted though it may finalize");
        }
    }

    /// @dev Searches a block hash that makes some minted machine land on a relic trait id, so lit relics occur.
    ///      offset = keccak(seedOf(need), blockHash) % 2222 and traitId(id) = (id - 1 + offset) % 2222 + 1, a relic when
    ///      the trait id is 2221 or 2222. Without a hit the hash is the plain pseudo-random one.
    function _steerHash(uint256 seed, uint256 need) internal view returns (bytes32 best) {
        best = keccak256(abi.encode("bh", seed));
        uint256 minted = machine.mintedCount();
        if (minted == 0 || need > W.ONION_LENGTH()) return best;
        bytes32 s = QZOnion.seedOf(W.chain(need), uint64(need));
        bool weak;
        // Half of the seeds want both relics among the minted machines (a second relic can join late), the other
        // half leave the standard ids on varied trait windows (two standard machines can share a track).
        bool both = uint256(keccak256(abi.encode("both", seed))) % 2 == 0;
        for (uint256 k; k < 4000; ++k) {
            bytes32 h = keccak256(abi.encode("bh", seed, k));
            uint256 offset = uint256(keccak256(abi.encode(s, h))) % SUPPLY;
            // ids with trait 2221 / 2222: id - 1 = (2220 - offset) mod 2222 and (2221 - offset) mod 2222
            uint256 id1 = (SUPPLY + 2220 - offset) % SUPPLY + 1;
            uint256 id2 = (SUPPLY + 2221 - offset) % SUPPLY + 1;
            if (both && id1 <= minted && id2 <= minted) return h;
            if (!both && (id1 <= minted || id2 <= minted)) return h;
            if (!weak && (id1 <= minted || id2 <= minted)) {
                weak = true;
                best = h;
            }
        }
    }

    function entropyReveal(uint256 step, bool bad) external {
        _begin(A_ENTROPY);
        uint256 cur = entropy.revealedIndex();
        uint256 index = cur + 1 + (step % 3);
        if (index > W.ONION_LENGTH()) {
            _reject();
            return;
        }
        bytes32 r = bad ? keccak256(abi.encode("bad", step)) : W.chain(index);
        vm.prank(revealer);
        try entropy.reveal(uint64(index), r) {
            if (bad) _viol("entropy accepted a forged link");
            if (entropy.revealedIndex() != index) _viol("entropy index not advanced");
            if (entropy.seedOf(uint64(index)) != QZOnion.seedOf(W.chain(index), uint64(index))) {
                _viol("entropy seed differs from the onion link");
            }
            _ok(A_ENTROPY);
        } catch {
            if (!bad) _viol("entropy rejected the true next link");
            _reject();
        }
    }

    /// @dev Reveals links until the machine's entropy index is covered.
    function _prepEntropy() internal {
        uint256 need = finalizedIdx + 1;
        uint256 guard;
        while (entropy.revealedIndex() < need && guard++ < 4) {
            uint256 cur = entropy.revealedIndex();
            uint256 index = cur + 1;
            if (index > W.ONION_LENGTH()) return;
            _must(revealer, address(entropy), abi.encodeCall(entropy.reveal, (uint64(index), W.chain(index))), "prep: link reveal failed");
        }
    }

    function machineReveal(bool prep) external {
        _begin(A_MREVEAL);
        if (prep) _prepToReveal();
        if (!_machineRevealNow()) {
            _reject();
            return;
        }
        _ok(A_MREVEAL);
    }

    function _machineRevealNow() internal returns (bool done) {
        bool timedOut = block.timestamp >= uint256(machine.lockedAt()) + machine.REVEAL_TIMEOUT();
        bool expect = machine.mintFinalized() && !machine.revealed() && handlerFinalized && machine.hashLocked()
            && (entropy.revealedIndex() >= finalizedIdx + 1 || timedOut);
        try machine.reveal() {
            if (!expect) _viol("machine.reveal succeeded though it must not");
            _checkOffset();
            done = true;
        } catch {
            if (expect) _viol("machine.reveal reverted though finalized, locked and entropy ready (or timed out)");
        }
    }

    /// @dev The rotation is `keccak256(seed, lockedHash) mod 2222`; the seed is the entropy link `i + 1`, or 0 when the
    ///      reveal came by timeout.
    function _checkOffset() internal {
        if (!machine.revealed()) {
            _viol("reveal did not set revealed");
            return;
        }
        uint256 need = finalizedIdx + 1;
        bytes32 seed = entropy.revealedIndex() >= need ? entropy.seedOf(uint64(need)) : bytes32(0);
        if (machine.revealOffset() != uint256(keccak256(abi.encode(seed, machine.lockedHash()))) % SUPPLY) {
            _viol("reveal offset is not keccak(seed, lockedHash) % 2222");
        }
    }

    // ───────────── lock the block hash, re-arm ─────────────

    function lockHash(uint256 seed, bool steer, bool prep) external {
        _begin(A_LOCK);
        if (prep) _prepToLock();
        if (!_lockNow(seed, steer)) {
            _reject();
            return;
        }
        _ok(A_LOCK);
    }

    /// @dev `lockHash` works in blocks `F + 2 ..= F + 257` (F = `finalizeBlock`) and only once. The handler fixes
    ///      `blockhash(F + 1)` (the test chain has no real blocks) before the call and checks that exactly that hash is
    ///      stored with the lock time.
    function _lockNow(uint256 seed, bool steer) internal returns (bool done) {
        uint256 f = machine.finalizeBlock();
        bool expect = machine.mintFinalized() && !machine.hashLocked() && block.number >= f + 2 && block.number <= f + 257;
        bytes32 h = steer ? _steerHash(seed, finalizedIdx + 1) : keccak256(abi.encode("bh", seed));
        if (expect) vm.setBlockhash(f + 1, h);
        try machine.lockHash() {
            if (!expect) _viol("lockHash succeeded though it must not");
            if (!machine.hashLocked() || machine.lockedHash() != h || machine.lockedAt() != block.timestamp) {
                _viol("lockHash did not store blockhash(finalizeBlock + 1) and the lock time");
            }
            done = true;
        } catch {
            if (expect) _viol("lockHash reverted inside its window");
        }
    }

    function rearmReveal(bool prep) external {
        _begin(A_REARM);
        if (prep) {
            if (!machine.mintFinalized()) {
                _prepFinalize();
                _finalizeNow();
            }
            if (machine.mintFinalized() && !machine.hashLocked() && block.number <= machine.finalizeBlock() + 257) {
                vm.roll(machine.finalizeBlock() + 258);
            }
        }
        if (!_rearmNow()) {
            _reject();
            return;
        }
        _ok(A_REARM);
    }

    /// @dev Only when nobody locked a hash in the window, and never after a lock.
    function _rearmNow() internal returns (bool done) {
        bool expect = machine.mintFinalized() && !machine.hashLocked() && block.number > machine.finalizeBlock() + 257;
        try machine.rearmReveal() {
            if (!expect) _viol("rearmReveal succeeded though it must not");
            if (machine.finalizeBlock() != block.number) _viol("rearmReveal did not move finalizeBlock to now");
            done = true;
        } catch {
            if (expect) _viol("rearmReveal reverted though the window passed unlocked");
        }
    }

    /// @dev Finalize (when due) and move to the first block where `lockHash` works; the lock itself is left to the caller.
    function _prepToLock() internal {
        if (!machine.mintFinalized()) {
            _prepFinalize();
            if (!_finalizeNow()) return;
        }
        if (machine.hashLocked()) return;
        uint256 f = machine.finalizeBlock();
        if (block.number > f + 257) {
            if (!_rearmNow()) return;
            f = machine.finalizeBlock();
        }
        if (block.number < f + 2) vm.roll(f + 2);
    }

    /// @dev finalize (when due), entropy link, hash lock; the machine reveal itself is left to the caller.
    function _prepToReveal() internal {
        _prepToLock();
        if (!machine.mintFinalized() || !handlerFinalized) return;
        if (!machine.hashLocked()) _lockNow(uint256(keccak256(abi.encode(block.timestamp, oks[A_MINT], _prepSalt))), true);
        if (!machine.revealed()) _prepEntropy();
    }

    /// @dev finalize (when due), entropy link, hash lock, machine reveal. `warpOpen`: also wait for the lighting date.
    function _prepRevealedState(bool warpOpen) internal {
        _prepToReveal();
        if (!machine.revealed() && handlerFinalized) _machineRevealNow();
        if (warpOpen && block.timestamp < forge.lightingOpensAt()) vm.warp(forge.lightingOpensAt());
    }

    // ───────────── Pons curve and fees ─────────────

    function curveBuy(uint256 seed, uint256 eth) external {
        _begin(A_BUY);
        eth = bound(eth, 1e14, 3 ether);
        address who = _actor(seed);
        bool expect = !curve.graduated();
        uint256 before = qz.balanceOf(who);
        vm.deal(who, eth);
        vm.prank(who);
        try curve.buy{value: eth}(eth, 0, who) returns (uint256 out) {
            if (!expect) _viol("curve sold after graduation");
            if (qz.balanceOf(who) - before != out) _viol("curve buy: QZ received != reported");
            _ok(A_BUY);
        } catch {
            if (expect) _viol("curve buy reverted before graduation");
            _reject();
        }
    }

    function curveSell(uint256 seed, uint256 bps) external {
        _begin(A_SELL);
        bps = bound(bps, 1, 10_000);
        address who;
        uint256 bal;
        for (uint256 k; k < actors.length && bal == 0; ++k) {
            who = _actor(seed + k);
            bal = qz.balanceOf(who);
        }
        uint256 amount = bal * bps / 10_000;
        if (amount == 0) {
            _reject();
            return;
        }
        bool expect = !curve.graduated();
        uint256 ethBefore = who.balance;
        vm.prank(who);
        qz.approve(address(curve), amount);
        vm.prank(who);
        try curve.sell(amount, 0, who) {
            if (!expect) _viol("curve bought back after graduation");
            if (qz.balanceOf(who) != bal - amount) _viol("curve sell: QZ not taken exactly");
            if (who.balance <= ethBefore) _viol("curve sell: no ETH paid");
            _ok(A_SELL);
        } catch {
            if (expect) _viol("curve sell reverted before graduation");
            _reject();
        }
    }

    function graduate(uint256 seed) external {
        _begin(A_GRADUATE);
        if (seed % 16 != 0 || pons.phase() != 0) {
            _reject();
            return;
        }
        pons.graduate();
        if (!curve.graduated() || pons.phase() != 2) _viol("graduate did not graduate");
        _ok(A_GRADUATE);
    }

    function hookAccrue(uint256 amount, uint256 taxBps) external {
        _begin(A_ACCRUE);
        amount = bound(amount, 10, 2 ether);
        uint256 tax = amount * bound(taxBps, 0, 5000) / 10_000;
        bytes32 pid = pons.poolId();
        bool expect = pons.phase() != 0;
        vm.deal(address(this), amount);
        try hook.accrue{value: amount}(pid, tax) {
            if (!expect) _viol("hook accrued before graduation");
            _ok(A_ACCRUE);
        } catch {
            if (expect) _viol("hook.accrue reverted on a registered pool");
            _reject();
        }
    }

    /// @dev What the next `harvest` must find: escrow balance, ETH already at the splitter (less the share parked for
    ///      the treasury) and the creator side of the accrued Pons fee (base fee minus 30% protocol share, plus the tax).
    function pendingHarvest() public view returns (uint256 total) {
        total = escrow.balanceOf(address(splitter)) + address(splitter).balance - splitter.pendingTreasury();
        uint256 fee;
        uint256 tax;
        if (pons.phase() == 0) {
            fee = curve.quoteFeeBalance();
            tax = curve.creatorTaxBalance();
        } else {
            bytes32 pid = pons.poolId();
            fee = hook.pendingFees(pid);
            tax = hook.pendingCreatorTax(pid);
        }
        total += fee - fee * 3000 / 10_000 + tax;
    }

    struct HarvestSnap {
        uint256 total;
        uint256 cEth;
        uint256 tEth;
        uint256 totC;
        uint256 totT;
        uint256 pend;
        bool refuse;
    }

    function harvest(uint256 callerSeed, bool prep) external {
        _begin(A_HARVEST);
        if (prep) _prepFees(callerSeed);
        if (!_harvestNow(callerSeed)) {
            _reject();
            return;
        }
    }

    /// @dev A refusing treasury no longer fails the harvest: its share is parked at the splitter.
    function _harvestNow(uint256 callerSeed) internal returns (bool done) {
        HarvestSnap memory s = HarvestSnap({
            total: pendingHarvest(),
            cEth: address(conv).balance,
            tEth: address(treasury).balance,
            totC: splitter.totalToConverter(),
            totT: splitter.totalToTreasury(),
            pend: splitter.pendingTreasury(),
            refuse: treasury.rejectEth()
        });
        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));

        vm.prank(caller);
        try splitter.harvest() returns (uint256 toC, uint256 toT) {
            if (s.total == 0) _viol("harvest succeeded though nothing to harvest");
            _onHarvest(s, toC, toT);
            done = true;
        } catch {
            if (s.total != 0) _viol("harvest reverted with fees pending (a refusing treasury must be parked, not fatal)");
            _checkHarvestRevertedClean(s);
        }
    }

    function _prepFees(uint256 seed) internal {
        if (pendingHarvest() != 0) return;
        if (pons.phase() == 0) {
            _buyFor(_actor(seed), 1 ether);
        } else {
            vm.deal(address(this), 1 ether);
            hook.accrue{value: 1 ether}(pons.poolId(), 0.1 ether);
        }
    }

    function _onHarvest(HarvestSnap memory s, uint256 toC, uint256 toT) internal {
        if (toC + toT != s.total) _viol("harvest: swept != pending fees");
        if (toC != s.total * QZConstants.REWARD_PART / (QZConstants.REWARD_PART + QZConstants.TREASURY_PART)) {
            _viol("harvest: converter share is not 20/27");
        }
        if (toT != s.total - toC) _viol("harvest: treasury share is not the remainder");
        uint256 delivered = s.refuse ? 0 : toT;
        if (address(conv).balance - s.cEth != toC) _viol("harvest: converter ETH delta != its share");
        if (address(treasury).balance - s.tEth != delivered) _viol("harvest: treasury ETH delta != its share (0 when it refuses)");
        if (splitter.totalToConverter() - s.totC != toC || splitter.totalToTreasury() - s.totT != delivered) {
            _viol("harvest: ledgers do not follow the payout");
        }
        if (splitter.pendingTreasury() != s.pend + (s.refuse ? toT : 0)) _viol("harvest: parked share off");
        if (address(splitter).balance != splitter.pendingTreasury()) _viol("harvest: splitter holds ETH beyond the parked share");
        if (escrow.balanceOf(address(splitter)) != 0) _viol("harvest: escrow credit left unclaimed");
        if (pons.phase() == 0) {
            if (curve.quoteFeeBalance() != 0 || curve.creatorTaxBalance() != 0) _viol("harvest: curve fees not swept");
        } else if (hook.pendingFees(pons.poolId()) != 0 || hook.pendingCreatorTax(pons.poolId()) != 0) {
            _viol("harvest: hook fees not swept");
        }
        ++gHarvests;
        gHarvested += s.total;
        _ok(A_HARVEST);
    }

    function _checkHarvestRevertedClean(HarvestSnap memory s) internal {
        if (
            address(conv).balance != s.cEth || address(treasury).balance != s.tEth || splitter.totalToConverter() != s.totC
                || splitter.totalToTreasury() != s.totT || splitter.pendingTreasury() != s.pend
        ) _viol("failed harvest changed state");
    }

    function treasuryReject(uint256 seed) external {
        _begin(A_TREASURY);
        if (treasury.rejectEth()) {
            treasury.setReject(false);
        } else if (seed % 3 == 0) {
            treasury.setReject(true);
        } else {
            _reject();
            return;
        }
        _ok(A_TREASURY);
    }

    /// @dev Only the treasury can pull the parked share. An outsider is refused, the treasury gets it while it accepts
    ///      ETH and is refused with the share kept when it does not.
    function claimParked(uint256 seed, bool prep) external {
        _begin(A_CLAIM_PARKED);
        if (seed % 4 == 0) {
            _mustFail(attacker, address(splitter), abi.encodeCall(splitter.claimPendingTreasury, (attacker)), "an outsider claimed the parked treasury share");
            _ok(A_CLAIM_PARKED);
            return;
        }
        if (prep && splitter.pendingTreasury() == 0) {
            bool was = treasury.rejectEth();
            treasury.setReject(true);
            _prepFees(seed);
            _harvestNow(seed);
            treasury.setReject(was);
        }
        uint256 pend = splitter.pendingTreasury();
        bool refuse = treasury.rejectEth();
        bool expect = pend != 0 && !refuse;
        uint256 tEth = address(treasury).balance;
        uint256 sEth = address(splitter).balance;
        uint256 totT = splitter.totalToTreasury();
        vm.prank(address(treasury));
        try splitter.claimPendingTreasury(address(treasury)) {
            if (!expect) _viol("claimPendingTreasury succeeded with nothing parked or a refusing treasury");
            if (
                splitter.pendingTreasury() != 0 || address(treasury).balance - tEth != pend
                    || sEth - address(splitter).balance != pend || splitter.totalToTreasury() - totT != pend
            ) _viol("claimPendingTreasury: ledgers do not follow the payout");
            _ok(A_CLAIM_PARKED);
        } catch {
            if (expect) _viol("claimPendingTreasury reverted with a parked share and a willing treasury");
            if (splitter.pendingTreasury() != pend || address(treasury).balance != tEth) _viol("failed claim changed state");
            _reject();
        }
    }

    // ───────────── donations ─────────────

    function donate(uint256 kind, uint256 seed, uint256 amount) external {
        _begin(A_DONATE);
        kind %= 8;
        uint8 t = uint8(seed % 10);
        if (kind == 0 || kind == 1) {
            amount = bound(amount, 1, 2 ether);
            address to = kind == 0 ? address(splitter) : address(conv);
            vm.deal(address(this), amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) {
                _viol("ETH donation refused");
                return;
            }
            if (kind == 0) gDonatedEthSplitter += amount;
            else gDonatedEthConv += amount;
        } else if (kind == 2 || kind == 3) {
            amount = bound(amount, 1, 1e12);
            address to = kind == 2 ? address(conv) : address(machine);
            usdg.mint(address(this), amount);
            usdg.transfer(to, amount);
            if (kind == 2) gDonatedUsdgConv += amount;
            else gDonatedUsdgMachine += amount;
        } else if (kind == 4) {
            amount = bound(amount, 1, 1e18);
            MockERC20 weth = MockERC20(address(W.weth()));
            weth.mint(address(this), amount);
            weth.transfer(address(conv), amount);
            gDonatedWethConv += amount;
        } else if (kind == 5 || kind == 6) {
            amount = bound(amount, 1, 1e22);
            address to = kind == 5 ? address(vault) : address(conv);
            stocks(t).mint(to, amount);
            if (kind == 5) gDonatedStockVault[t] += amount;
            else gDonatedStockConv[t] += amount;
        } else {
            address who = _actor(seed);
            uint256 bal = qz.balanceOf(who);
            if (bal == 0) {
                _reject();
                return;
            }
            amount = bound(amount, 1, bal);
            vm.prank(who);
            qz.transfer(address(forge), amount);
            gQzDonated += amount;
        }
        _ok(A_DONATE);
    }

    function stocks(uint8 t) internal view returns (MockStock) {
        return W.stocks(t);
    }

    // ───────────── machine transfers ─────────────

    function transferMachine(uint256 idSeed, uint256 toSeed) external {
        _begin(A_TRANSFER);
        uint256 minted = machine.mintedCount();
        if (minted == 0) {
            _reject();
            return;
        }
        uint256 id = 1 + idSeed % minted;
        address from = machine.ownerOf(id);
        address to = _actor(toSeed);
        if (from == to) {
            _reject();
            return;
        }
        bool lit = forge.isLit(id);
        uint256[10] memory before = _claimableAll(id);
        vm.prank(from);
        machine.transferFrom(from, to, id);
        ++gTransfers;
        if (machine.ownerOf(id) != to) _viol("transfer: owner not updated");
        uint256[10] memory afterT = _claimableAll(id);
        for (uint256 t; t < 10; ++t) {
            if (before[t] != afterT[t]) _viol("transfer changed a claimable amount: the right must follow the NFT as is");
        }
        if (forge.isLit(id) != lit || vault.isEnrolled(id) != lit) _viol("transfer changed the lit state");
        if (lit) _oldOwnerCannotClaim(from, id);
        _ok(A_TRANSFER);
    }

    function _claimableAll(uint256 id) internal view returns (uint256[10] memory c) {
        for (uint8 t; t < 10; ++t) {
            c[t] = vault.claimable(id, t);
        }
    }

    function _oldOwnerCannotClaim(address old, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tr = new uint8[](1);
        ids[0] = id;
        tr[0] = litRelic[id] ? 0 : litTrack[id];
        if (_exec(old, address(vault), abi.encodeCall(vault.claim, (ids, tr)))) {
            _viol("the previous owner claimed the rewards of a machine it no longer owns");
        }
    }

    // ───────────── light ─────────────

    /// @dev Set while `_prepLateJoiner` runs, so the lights it triggers do not set up another late joiner.
    bool private _lateGuard;

    /// @dev Builds the late-joiner case on purpose: several unlit machines, one lit machine and a track that has
    ///      already paid out. The light that follows must then enrol a machine into rewards it never earned, and
    ///      `_onLight` checks that it can claim none of them (standard debt start, relic start).
    function _prepLateJoiner(uint256 seed) internal {
        _lateGuard = true;
        for (uint256 k; k < 8 && !machine.revealed() && machine.mintedCount() - forge.litCount() < 8; ++k) {
            if (!_prepOpenMint() || !_mintOne(seed + k, true)) break;
        }
        if (machine.mintedCount() > forge.litCount() + 1) {
            _unpause(1);
            _prepRevealedState(true);
            if (litIds.length == 0) {
                _lightOne(seed - seed % 4 + 2, seed, true);
                _lightOne(seed - seed % 4 + 3, seed, true);
            }
            if (_prepLit(seed) && !_anyNotified() && _prepConvert(seed)) _prepRewards(seed);
        }
        _lateGuard = false;
    }

    struct LightSnap {
        uint256 forgeQz;
        uint256 callerQz;
        uint256 litCount;
        uint256 weightSum;
        uint256 relics;
        bool expect;
    }

    function light(uint256 idSeed, uint256 callerSeed, bool prep) external {
        _begin(A_LIGHT);
        if (!_lightOne(idSeed, callerSeed, prep)) {
            _reject();
            return;
        }
        _ok(A_LIGHT);
    }

    /// @dev The seed of the last prepared light, so the prepared lock steers differently from run to run.
    uint256 private _prepSalt;

    /// @dev `prep`: the owner lights a machine of its own with everything in place; every fourth seed it re-lights a lit
    ///      machine instead (must hit AlreadyLit).
    function _lightOne(uint256 idSeed, uint256 callerSeed, bool prep) internal returns (bool done) {
        if (prep) _prepSalt = idSeed;
        if (prep && machine.mintedCount() == 0) {
            if (!_prepOpenMint()) return false;
            _mintOne(idSeed, true);
        }
        if (prep && idSeed % 4 == 1 && !_lateGuard) _prepLateJoiner(idSeed);
        uint256 minted = machine.mintedCount();
        if (minted == 0) return false;
        uint256 id = _pickLightId(idSeed, prep, minted);
        address caller;
        if (prep) {
            caller = machine.ownerOf(id);
            _prepLightState(caller);
        } else {
            caller = _actor(callerSeed);
        }
        LightSnap memory s = _lightSnap(id, caller);
        vm.prank(caller);
        try forge.light(id) {
            _onLight(id, caller, s);
            done = true;
        } catch {
            if (s.expect) _viol("light reverted though owner, revealed, open, funded, approved and not lit");
        }
    }

    function _pickLightId(uint256 idSeed, bool prep, uint256 minted) internal view returns (uint256) {
        if (!prep) return 1 + idSeed % minted;
        if (idSeed % 4 == 0 && litIds.length != 0) return litIds[(idSeed / 4) % litIds.length];
        if (idSeed % 4 == 2 && machine.revealed()) {
            // a relic first, so the later light of a second relic meets a relic share that already paid out
            for (uint256 k; k < minted; ++k) {
                uint256 id = 1 + (idSeed + k) % minted;
                (,, bool relic) = machine.traitsOf(id);
                if (relic && !forge.isLit(id)) return id;
            }
        }
        if (idSeed % 4 == 3 && machine.revealed()) {
            // a standard machine that has an unlit twin on its track: light one, the twin joins late
            for (uint256 k; k < minted; ++k) {
                uint256 id = 1 + (idSeed + k) % minted;
                if (forge.isLit(id)) continue;
                (, uint8 track, bool relic) = machine.traitsOf(id);
                if (relic) continue;
                for (uint256 j = 1; j <= minted; ++j) {
                    if (j == id || forge.isLit(j)) continue;
                    (, uint8 t2, bool r2) = machine.traitsOf(j);
                    if (!r2 && t2 == track) return id;
                }
            }
        }
        if (idSeed % 4 == 1 && machine.revealed()) {
            // late joiner: an unlit machine on a track that already paid out, so a wrong debt start shows
            for (uint256 k; k < minted; ++k) {
                uint256 id = 1 + (idSeed + k) % minted;
                if (forge.isLit(id)) continue;
                (, uint8 track, bool relic) = machine.traitsOf(id);
                if (relic ? _anyNotified() : vault.totalNotified(track) != 0) return id;
            }
        }
        for (uint256 k; k < minted; ++k) {
            uint256 id = 1 + (idSeed + k) % minted;
            if (!forge.isLit(id)) return id;
        }
        return 1 + idSeed % minted;
    }

    function _anyNotified() internal view returns (bool) {
        for (uint8 t; t < 10; ++t) {
            if (vault.totalNotified(t) != 0) return true;
        }
        return false;
    }

    function _prepLightState(address caller) internal {
        _unpause(1);
        _prepRevealedState(true);
        if (qz.balanceOf(caller) < N) _prepQz(caller);
        vm.prank(caller);
        qz.approve(address(forge), type(uint256).max);
    }

    /// @dev Up to three curve buys until `who` holds the lock amount (after graduation the curve is closed: no QZ).
    function _prepQz(address who) internal {
        for (uint256 i; i < 3 && qz.balanceOf(who) < N && !curve.graduated(); ++i) {
            _buyFor(who, 0.05 ether);
        }
    }

    function _buyFor(address who, uint256 eth) internal {
        vm.deal(who, eth);
        vm.prank(who);
        try curve.buy{value: eth}(eth, 0, who) {}
        catch {
            _viol("prep: curve buy failed before graduation");
        }
    }

    function _lightSnap(uint256 id, address caller) internal view returns (LightSnap memory s) {
        s.forgeQz = qz.balanceOf(address(forge));
        s.callerQz = qz.balanceOf(caller);
        s.litCount = forge.litCount();
        for (uint8 t; t < 10; ++t) {
            s.weightSum += vault.weightOf(t);
        }
        s.relics = vault.relicCount();
        s.expect = !forge.paused() && block.timestamp >= forge.lightingOpensAt() && machine.ownerOf(id) == caller
            && machine.revealed() && !forge.isLit(id) && s.callerQz >= N && qz.allowance(caller, address(forge)) >= N;
    }

    function _onLight(uint256 id, address caller, LightSnap memory s) internal {
        if (!s.expect) _viol("light succeeded though it must not (double light, not owner, paused, early or unrevealed)");
        (uint8 tier, uint8 track, bool relic) = machine.traitsOf(id);
        if (!forge.isLit(id) || !vault.isEnrolled(id)) _viol("light: lit flag or vault enrolment missing");
        if (forge.litCount() != s.litCount + 1) _viol("light: litCount off");
        if (qz.balanceOf(address(forge)) != s.forgeQz + N) _viol("light: forge did not take exactly the lock amount");
        if (qz.balanceOf(caller) != s.callerQz - N) _viol("light: caller did not pay exactly the lock amount");
        if (forge.lockedPrincipal() != forge.litCount() * N) _viol("light: lockedPrincipal != litCount * N");
        uint256 weightSum;
        for (uint8 t; t < 10; ++t) {
            weightSum += vault.weightOf(t);
            if (vault.claimable(id, t) != 0) _viol("a freshly lit machine can claim rewards notified before it was lit");
        }
        if (relic) {
            if (vault.relicCount() != s.relics + 1 || weightSum != s.weightSum) _viol("light: relic enrolment off");
            ++gRelicLit;
        } else {
            if (vault.relicCount() != s.relics || weightSum != s.weightSum + QZConstants.weightOf(tier)) {
                _viol("light: standard weight off");
            }
            ++gStandardLit;
        }
        if (track >= 10) _viol("light: bad track");
        litIds.push(id);
        litTrack[id] = track;
        litRelic[id] = relic;
    }

    // ───────────── converter ─────────────

    function openEpoch(bool prep, bool asExecutor) external {
        _begin(A_OPEN);
        if (prep && !_prepOpen()) {
            _reject();
            return;
        }
        if (!_openNow(prep || asExecutor)) {
            _reject();
            return;
        }
        _ok(A_OPEN);
    }

    function _activeCount() internal view returns (uint256 n) {
        for (uint8 t; t < 10; ++t) {
            if (vault.weightOf(t) != 0) ++n;
        }
    }

    function _activeTracks() internal view returns (uint8[] memory a) {
        a = new uint8[](_activeCount());
        uint256 n;
        for (uint8 t; t < 10; ++t) {
            if (vault.weightOf(t) != 0) a[n++] = t;
        }
    }

    /// @dev Something lit, the converter unpaused, time at the epoch date and at least a minute after the last epoch.
    function _prepOpen() internal returns (bool) {
        _unpause(2);
        if (!_prepLit(0)) return false;
        uint256 nb = conv.lastOpenEpoch() == 0 ? conv.firstEpochAt() : uint256(conv.lastOpenEpoch()) + QZConstants.OPEN_EPOCH_INTERVAL;
        if (block.timestamp < nb) vm.warp(nb);
        return true;
    }

    /// @dev Lights machines (prep) until one standard machine is lit or relics only.
    function _prepLit(uint256 seed) internal returns (bool) {
        if (litIds.length != 0 && (_activeCount() != 0 || vault.relicCount() != 0)) return true;
        for (uint256 i; i < 6 && litIds.length == 0; ++i) {
            if (!_lightOne(seed + i, seed, true)) break;
        }
        return litIds.length != 0;
    }

    struct EpochSnap {
        uint256 eth;
        uint256 wethBal;
        uint256 usdgBal;
        uint256 totW;
        uint256 totU;
        uint256 active;
        uint256 shareW;
        uint256 shareU;
        uint256[10] potW;
        uint256[10] potU;
        uint8[10] w;
        bool expect;
        bool isExec;
    }

    function _openNow(bool asExec) internal returns (bool done) {
        bool fb = conv.fallbackMode();
        address caller = (asExec || fb) ? executor : attacker;
        EpochSnap memory s = _epochSnap(caller == executor);
        vm.prank(caller);
        try conv.openEpoch() {
            if (!s.expect) _viol("openEpoch succeeded though it must not");
            _onEpoch(s);
            done = true;
        } catch {
            if (s.expect) _viol("openEpoch reverted for the executor with routes sealed, lit machines and time due");
        }
    }

    function _epochSnap(bool isExec) internal view returns (EpochSnap memory s) {
        s.isExec = isExec;
        s.eth = address(conv).balance;
        s.wethBal = MockERC20(address(W.weth())).balanceOf(address(conv));
        s.usdgBal = usdg.balanceOf(address(conv));
        s.totW = conv.totalTrackWeth();
        s.totU = conv.totalTrackUsdg();
        for (uint8 t; t < 10; ++t) {
            (s.potW[t], s.potU[t]) = conv.trackPot(t);
            if (vault.weightOf(t) != 0) {
                s.w[t] = 1;
                ++s.active;
            }
        }
        uint256 nb = conv.lastOpenEpoch() == 0 ? conv.firstEpochAt() : uint256(conv.lastOpenEpoch()) + QZConstants.OPEN_EPOCH_INTERVAL;
        s.expect = isExec && !conv.paused() && block.timestamp >= nb && (s.active != 0 || vault.relicCount() != 0);
        if (s.active != 0) {
            uint256 freeW = s.wethBal + s.eth;
            uint256 freeU = s.usdgBal;
            s.shareW = (freeW > s.totW ? freeW - s.totW : 0) / s.active;
            s.shareU = (freeU > s.totU ? freeU - s.totU : 0) / s.active;
        }
    }

    function _onEpoch(EpochSnap memory s) internal {
        gWrapped += s.eth;
        if (address(conv).balance != 0) _viol("openEpoch left ETH unwrapped");
        uint256 grewW;
        uint256 grewU;
        for (uint8 t; t < 10; ++t) {
            (uint256 pw, uint256 pu) = conv.trackPot(t);
            uint256 expW = s.w[t] == 1 ? s.shareW : 0;
            uint256 expU = s.w[t] == 1 ? s.shareU : 0;
            if (pw != s.potW[t] + expW || pu != s.potU[t] + expU) _viol("openEpoch: a pot did not get exactly its equal share");
            grewW += pw - s.potW[t];
            grewU += pu - s.potU[t];
        }
        if (conv.totalTrackWeth() != s.totW + grewW || conv.totalTrackUsdg() != s.totU + grewU) {
            _viol("openEpoch: pot totals off");
        }
        if (s.active != 0 && (grewW != s.shareW * s.active || grewU != s.shareU * s.active)) _viol("openEpoch: shares off");
        if (s.active == 0 && (grewW != 0 || grewU != 0)) _viol("openEpoch assigned funds to a track without a standard machine");
    }

    function poke(uint256 trackSeed, bool asKeeper) external {
        _begin(A_POKE);
        uint8 t = uint8(trackSeed % 10);
        bool fb = conv.fallbackMode();
        bool spaced = lastObservation[t] == 0 || block.timestamp >= lastObservation[t] + KEEPER_SPACING;
        bool expectOk = asKeeper && !fb && spaced;
        address caller = asKeeper ? keeper : attacker;
        vm.prank(caller);
        try conv.poke(t) {
            if (!asKeeper && !fb) _viol("poke by a non-keeper succeeded in normal mode");
            lastObservation[t] = block.timestamp;
            _ok(A_POKE);
        } catch {
            if (expectOk) _viol("keeper poke reverted in normal mode");
            _reject();
        }
    }

    struct ConvSnap {
        uint256 potW;
        uint256 potU;
        uint256 totW;
        uint256 totU;
        uint256 wethBal;
        uint256 usdgBal;
        uint256 stockVault;
        uint256 stockConv;
        uint256 notified;
        uint256 amount;
        uint8 track;
        bool expect;
    }

    function convert(uint256 trackSeed, uint256 amt, uint256 variant, bool prep) external {
        _begin(A_CONVERT);
        if (!_convertOne(trackSeed, amt, variant, prep, false)) {
            _reject();
            return;
        }
        _ok(A_CONVERT);
    }

    function convertUsdg(uint256 trackSeed, uint256 amt, uint256 variant, bool prep) external {
        _begin(A_CONVERT_USDG);
        if (!_convertOne(trackSeed, amt, variant, prep, true)) {
            _reject();
            return;
        }
        _ok(A_CONVERT_USDG);
    }

    function _convertOne(uint256 trackSeed, uint256 amt, uint256 variant, bool prep, bool usdgLeg)
        internal
        returns (bool done)
    {
        ConvSnap memory s;
        if (prep) {
            if (!_prepConvert(trackSeed)) return false;
            uint8[] memory act = _activeTracks();
            s.track = act[trackSeed % act.length];
            _prepReady(s.track);
        } else {
            s.track = uint8(trackSeed % 10);
        }
        bool fb = conv.fallbackMode();
        address caller = (prep || variant % 4 != 3 || fb) ? executor : attacker;
        uint256 deadline = (!prep && variant % 5 == 0) ? block.timestamp - 1 : block.timestamp + 1;
        _convSnap(s);
        uint256 pot = usdgLeg ? s.potU : s.potW;
        s.amount = _convAmount(s.track, pot, amt, variant, prep, usdgLeg);
        bool stockPaused = W.stocks(s.track).tokenPaused();
        bool mustRevert = conv.paused() || (caller != executor && !fb) || deadline < block.timestamp || s.amount == 0
            || s.amount > pot || stockPaused || (!usdgLeg && s.amount > conv.routeOf(s.track).maxChunk);
        s.expect = prep && !mustRevert && !fb;

        vm.prank(caller);
        bool ok;
        if (usdgLeg) {
            try conv.convertUsdg(s.track, s.amount, 1, deadline) {
                ok = true;
            } catch {}
        } else {
            try conv.convert(s.track, s.amount, 1, 1, deadline) {
                ok = true;
            } catch {}
        }
        if (!ok) {
            if (s.expect) _viol("convert reverted in prepared normal mode with a funded pot and 9 fresh keeper observations");
            return false;
        }
        if (mustRevert) _viol("convert succeeded though it must revert (paused, not executor, late, empty, short pot)");
        _onConvert(s, usdgLeg);
        return true;
    }

    function _convSnap(ConvSnap memory s) internal view {
        (s.potW, s.potU) = conv.trackPot(s.track);
        s.totW = conv.totalTrackWeth();
        s.totU = conv.totalTrackUsdg();
        s.wethBal = MockERC20(address(W.weth())).balanceOf(address(conv));
        s.usdgBal = usdg.balanceOf(address(conv));
        s.stockVault = W.stocks(s.track).balanceOf(address(vault));
        s.stockConv = W.stocks(s.track).balanceOf(address(conv));
        s.notified = vault.totalNotified(s.track);
    }

    function _convAmount(uint8 track, uint256 pot, uint256 amt, uint256 variant, bool prep, bool usdgLeg)
        internal
        view
        returns (uint256)
    {
        uint256 limit = usdgLeg ? conv.usdgChunkLimit(track) : conv.routeOf(track).maxChunk;
        uint256 lo = usdgLeg ? 1e4 : 1e12;
        uint256 hi = pot < limit ? pot : limit;
        if (!prep) {
            uint256 v = variant % 6;
            if (v == 1) return pot + 1;
            if (v == 2) return 0;
            if (v == 3) return limit + 1;
        }
        if (hi == 0) return 0;
        if (hi < lo) return hi;
        return lo + amt % (hi - lo + 1);
    }

    function _onConvert(ConvSnap memory s, bool usdgLeg) internal {
        MockStock st = W.stocks(s.track);
        uint256 out = st.balanceOf(address(vault)) - s.stockVault;
        if (out == 0) _viol("convert paid zero stock into the vault");
        if (vault.totalNotified(s.track) != s.notified + out) _viol("vault notified != stock received");
        if (st.balanceOf(address(conv)) != s.stockConv) _viol("converter kept or lost stock");
        (uint256 pw, uint256 pu) = conv.trackPot(s.track);
        MockERC20 weth = MockERC20(address(W.weth()));
        if (usdgLeg) {
            if (pu != s.potU - s.amount || pw != s.potW) _viol("convertUsdg: pot off");
            if (conv.totalTrackUsdg() != s.totU - s.amount || conv.totalTrackWeth() != s.totW) {
                _viol("convertUsdg: pot totals off");
            }
            if (usdg.balanceOf(address(conv)) != s.usdgBal - s.amount) _viol("convertUsdg: spent USDG != usdgIn");
            if (weth.balanceOf(address(conv)) != s.wethBal) _viol("convertUsdg moved WETH");
            gUsdgSpent += s.amount;
        } else {
            if (pw != s.potW - s.amount || pu != s.potU) _viol("convert: pot off");
            if (conv.totalTrackWeth() != s.totW - s.amount || conv.totalTrackUsdg() != s.totU) {
                _viol("convert: pot totals off");
            }
            if (weth.balanceOf(address(conv)) != s.wethBal - s.amount) _viol("convert: spent WETH != wethIn");
            if (usdg.balanceOf(address(conv)) != s.usdgBal) _viol("convert: net USDG change (leg 1 and 2 must net to zero)");
            gWethSpent += s.amount;
        }
        gStockOut[s.track] += out;
    }

    /// @dev Everything a conversion needs, with real calls: converter unpaused, a standard machine lit, the stock
    ///      unpaused, the epoch date reached, a funded pot (ETH donation then `openEpoch`) and nine keeper observations
    ///      100 s apart. Returns false when nothing standard can be lit.
    function _prepConvert(uint256 seed) internal returns (bool) {
        _unpause(2);
        if (_activeCount() == 0) {
            for (uint256 i; i < 8 && _activeCount() == 0; ++i) {
                if (!_lightOne(seed + i * 5, seed, true)) break;
            }
            if (_activeCount() == 0) return false;
        }
        return true;
    }

    function _prepReady(uint8 track) internal {
        if (W.stocks(track).tokenPaused()) W.stocks(track).setPaused(false);
        if (block.timestamp < conv.firstEpochAt()) vm.warp(conv.firstEpochAt());
        (uint256 pw,) = conv.trackPot(track);
        (, uint256 pu) = conv.trackPot(track);
        if (pw < 1e16 || pu < 1e6) {
            vm.deal(address(this), 1 ether);
            (bool ok,) = address(conv).call{value: 1 ether}("");
            if (!ok) _viol("prep: ETH donation to the converter failed");
            gDonatedEthConv += 1 ether;
            usdg.mint(address(conv), 1e9);
            gDonatedUsdgConv += 1e9;
            uint256 nb = conv.lastOpenEpoch() == 0 ? conv.firstEpochAt() : uint256(conv.lastOpenEpoch()) + QZConstants.OPEN_EPOCH_INTERVAL;
            if (block.timestamp < nb) vm.warp(nb);
            EpochSnap memory es = _epochSnap(true);
            if (_must(executor, address(conv), abi.encodeCall(conv.openEpoch, ()), "prep: openEpoch failed")) _onEpoch(es);
        }
        for (uint256 i; i < 9; ++i) {
            _pokeSpaced(track);
            vm.warp(block.timestamp + 100);
        }
    }

    /// @dev A keeper poke after the spacing the converter asks of the newest observation: 60 s in normal mode, 5 min
    ///      in fallback mode (which the wait itself can enter).
    function _pokeSpaced(uint8 track) internal {
        for (uint256 k; k < 2; ++k) {
            uint256 last = lastObservation[track];
            uint256 spacing = conv.fallbackMode() ? QZConstants.FALLBACK_MIN_OBSERVATION_SPACING : KEEPER_SPACING;
            if (last != 0 && block.timestamp < last + spacing) vm.warp(last + spacing);
        }
        if (_must(keeper, address(conv), abi.encodeCall(conv.poke, (track)), "prep: keeper poke failed")) {
            lastObservation[track] = block.timestamp;
        }
    }

    // ───────────── claim ─────────────

    function claim(uint256 seed, uint256 count, bool prep) external {
        _begin(A_CLAIM);
        if (prep) {
            if (!_prepLit(seed)) {
                _reject();
                return;
            }
            if (seed % 2 == 0) _prepRewards(seed);
        }
        if (litIds.length == 0) {
            _reject();
            return;
        }
        if (!_claimOne(seed, bound(count, 1, MAX_ACTORS_PER_CLAIM), prep)) {
            _reject();
            return;
        }
        _ok(A_CLAIM);
    }

    /// @dev Pays some rewards in: a real conversion on the track of the first lit machine, when that machine is standard.
    function _prepRewards(uint256 seed) internal {
        uint8[] memory act = _activeTracks();
        if (act.length == 0) return;
        _convertOne(seed, seed, 0, true, seed % 4 == 0);
    }

    struct ClaimSnap {
        uint256[] ids;
        uint8[] tracks;
        uint256[] pay;
        uint256[10] bal;
        uint256[10] claimedBefore;
        bool[10] paused;
        bool allOwned;
    }

    function _claimOne(uint256 seed, uint256 count, bool prep) internal returns (bool done) {
        uint256 n = litIds.length;
        if (count > n) count = n;
        ClaimSnap memory s;
        address caller = prep ? machine.ownerOf(litIds[seed % n]) : _actor(seed / 7);
        (s.ids, s.tracks) = _claimBatch(seed, count, n, caller, prep);
        if (s.ids.length == 0) return false;
        _claimSnap(s, caller);
        vm.prank(caller);
        try vault.claim(s.ids, s.tracks) {
            if (!s.allOwned) _viol("a non-owner claimed rewards");
            _onClaim(s, caller);
            done = true;
        } catch {
            if (s.allOwned) _viol("claim by the owner of every machine reverted");
        }
    }

    function _claimBatch(uint256 seed, uint256 count, uint256 n, address caller, bool prep)
        internal
        view
        returns (uint256[] memory ids, uint8[] memory tracks)
    {
        uint256[] memory tmpIds = new uint256[](count);
        uint8[] memory tmpTr = new uint8[](count);
        uint256 m;
        for (uint256 k; k < n && m < count; ++k) {
            uint256 id = litIds[(seed + k) % n];
            if (prep && machine.ownerOf(id) != caller) continue;
            tmpIds[m] = id;
            tmpTr[m] = litRelic[id] ? _relicTrack(seed + k) : litTrack[id];
            ++m;
        }
        ids = new uint256[](m);
        tracks = new uint8[](m);
        for (uint256 k; k < m; ++k) {
            ids[k] = tmpIds[k];
            tracks[k] = tmpTr[k];
        }
    }

    function _relicTrack(uint256 seed) internal view returns (uint8) {
        for (uint256 k; k < 10; ++k) {
            uint8 t = uint8((seed + k) % 10);
            if (vault.totalNotified(t) != 0) return t;
        }
        return uint8(seed % 10);
    }

    function _claimSnap(ClaimSnap memory s, address caller) internal view {
        s.pay = new uint256[](s.ids.length);
        s.allOwned = true;
        for (uint256 i; i < s.ids.length; ++i) {
            s.pay[i] = vault.claimable(s.ids[i], s.tracks[i]);
            if (machine.ownerOf(s.ids[i]) != caller) s.allOwned = false;
        }
        for (uint8 t; t < 10; ++t) {
            s.bal[t] = W.stocks(t).balanceOf(caller);
            s.claimedBefore[t] = vault.totalClaimed(t);
            s.paused[t] = W.stocks(t).tokenPaused();
        }
    }

    function _onClaim(ClaimSnap memory s, address caller) internal {
        uint256[10] memory exp;
        for (uint256 i; i < s.ids.length; ++i) {
            uint8 t = s.tracks[i];
            uint256 want = s.paused[t] ? 0 : s.pay[i];
            exp[t] += want;
            uint256 left = vault.claimable(s.ids[i], t);
            if (left != s.pay[i] - want) _viol("claim: claimable after the claim is not what is left");
        }
        for (uint8 t; t < 10; ++t) {
            if (W.stocks(t).balanceOf(caller) - s.bal[t] != exp[t]) _viol("claim: payout != claimable");
            if (vault.totalClaimed(t) != s.claimedBefore[t] + exp[t]) _viol("claim: totalClaimed != payouts");
            gClaimed[t] += exp[t];
        }
    }

    // ───────────── pause switches ─────────────

    function pauseToggle(uint256 which, uint256 seed) external {
        _begin(A_PAUSE);
        which %= 3;
        if (_isPaused(which)) {
            if (!_unpause(which)) {
                _reject();
                return;
            }
        } else if (seed % 3 == 0) {
            if (!_must(pauser, _pausable(which), abi.encodeWithSignature("pause()"), "pauser could not pause")) {
                _reject();
                return;
            }
        if (which == 0) machinePausedAt = block.timestamp;
        } else {
            _reject();
            return;
        }
        _ok(A_PAUSE);
    }

    function _pausable(uint256 which) internal view returns (address) {
        return which == 0 ? address(machine) : which == 1 ? address(forge) : address(conv);
    }

    function _isPaused(uint256 which) internal view returns (bool) {
        return which == 0 ? machine.paused() : which == 1 ? forge.paused() : conv.paused();
    }

    /// @dev Unpause (no-op when running). False when it was not paused.
    function _unpause(uint256 which) internal returns (bool) {
        if (!_isPaused(which)) return false;
        return _must(pauser, _pausable(which), abi.encodeWithSignature("unpause()"), "pauser could not unpause");
    }

    function stockPause(uint256 trackSeed, uint256 seed) external {
        _begin(A_STOCK_PAUSE);
        MockStock st = W.stocks(uint8(trackSeed % 10));
        if (st.tokenPaused()) st.setPaused(false);
        else if (seed % 4 == 0) st.setPaused(true);
        else {
            _reject();
            return;
        }
        _ok(A_STOCK_PAUSE);
    }

    // ───────────── attacks: permission checks that must hold ─────────────

    /// @dev Calls a privileged entry point as someone without the right. Expected to revert; a success is a violation and
    ///      is left in place (the invariants then see the changed state too). The call is counted as done either way: its
    ///      job is the rejection.
    function attack(uint256 kind, uint256 seed) external {
        _begin(A_ATTACK);
        kind %= 11;
        uint256 minted = machine.mintedCount();
        if (kind == 0) {
            // direct register of an unlit machine (needs a revealed machine, or it fails for the wrong reason)
            if (minted == 0) {
                _reject();
                return;
            }
            _prepRevealedState(false);
            uint256 id = _firstUnlit(seed, minted);
            if (id == 0 || !machine.revealed()) {
                _reject();
                return;
            }
            _mustFail(attacker, address(vault), abi.encodeCall(vault.register, (id)), "vault.register by a non-forge");
        } else if (kind == 1) {
            uint8 t = uint8(seed % 10);
            _mustFail(attacker, address(vault), abi.encodeCall(vault.notify, (t, 1e18)), "vault.notify by a non-converter");
        } else if (kind == 2) {
            _mustFail(attacker, address(forge), abi.encodeWithSignature("pause()"), "forge.pause by a non-pauser");
        } else if (kind == 3) {
            _mustFail(attacker, address(machine), abi.encodeWithSignature("pause()"), "machine.pause by a non-pauser");
            _mustFail(attacker, address(conv), abi.encodeWithSignature("pause()"), "converter.pause by a non-pauser");
        } else if (kind == 4) {
            bytes memory data = abi.encodeCall(conv.setRoute, (uint8(seed % 10), W.route(uint8(seed % 10))));
            _mustFail(attacker, address(conv), data, "setRoute by a non-owner");
            _mustFail(ownerAddr, address(conv), data, "setRoute after sealRoutes");
            _mustFail(ownerAddr, address(conv), abi.encodeCall(conv.sealRoutes, ()), "second sealRoutes");
        } else if (kind == 5) {
            bytes memory data = abi.encodeCall(machine.configureMint, (bytes32(seed), bytes32(~seed), uint64(block.timestamp)));
            _mustFail(attacker, address(machine), data, "configureMint by a non-owner");
            _mustFail(ownerAddr, address(machine), data, "second configureMint");
        } else if (kind == 6) {
            uint256 index = entropy.revealedIndex() + 1;
            if (index > W.ONION_LENGTH()) {
                _reject();
                return;
            }
            _mustFail(attacker, address(entropy), abi.encodeCall(entropy.reveal, (uint64(index), W.chain(index))), "entropy.reveal by a non-revealer");
        } else if (kind == 7) {
            _mustFail(attacker, address(splitter), abi.encodeCall(splitter.bind, (attacker, attacker)), "splitter.bind by a non-owner");
            _mustFail(ownerAddr, address(splitter), abi.encodeCall(splitter.bind, (attacker, attacker)), "second splitter.bind");
        } else if (kind == 8) {
            if (minted == 0) {
                _reject();
                return;
            }
            uint256 id = 1 + seed % minted;
            address from = machine.ownerOf(id);
            _mustFail(attacker, address(machine), abi.encodeCall(machine.transferFrom, (from, attacker, id)), "machine stolen by transferFrom");
            if (machine.ownerOf(id) != from) _viol("machine owner changed by an attacker");
        } else if (kind == 9) {
            if (!conv.fallbackMode()) {
                _mustFail(attacker, address(conv), abi.encodeCall(conv.openEpoch, ()), "openEpoch by a non-executor in normal mode");
                _mustFail(attacker, address(conv), abi.encodeCall(conv.poke, (uint8(seed % 10))), "poke by a non-keeper in normal mode");
                _mustFail(
                    attacker,
                    address(conv),
                    abi.encodeCall(conv.convert, (uint8(seed % 10), 1e12, 1, 1, block.timestamp + 1)),
                    "convert by a non-executor in normal mode"
                );
            }
        } else {
            _mustFail(attacker, address(conv), abi.encodeCall(conv.unlockCallback, (bytes(""))), "unlockCallback by a non-PoolManager");
        }
        _ok(A_ATTACK);
    }

    function _firstUnlit(uint256 seed, uint256 minted) internal view returns (uint256) {
        for (uint256 k; k < minted; ++k) {
            uint256 id = 1 + (seed + k) % minted;
            if (!forge.isLit(id)) return id;
        }
        return 0;
    }

    function _mustFail(address who, address target, bytes memory data, string memory what) internal {
        if (_exec(who, target, data)) _viol(string.concat("unauthorized call succeeded: ", what));
    }

    // ───────────── scripted drive (deterministic coverage test) ─────────────

    /// @notice One action by index with arguments derived from three numbers. Used by the deterministic tests, never
    ///         targeted by the fuzzer. Reverts like the action does.
    function drive(uint256 action, uint256 x, uint256 y, uint256 z) external {
        bool prep = z % 4 != 0;
        if (action == A_WARP) this.warp(x, y);
        else if (action == A_MINT) this.mint(x, y, prep);
        else if (action == A_FINALIZE) this.finalize(prep);
        else if (action == A_ENTROPY) this.entropyReveal(x, z % 5 == 0);
        else if (action == A_MREVEAL) this.machineReveal(prep);
        else if (action == A_BUY) this.curveBuy(x, y);
        else if (action == A_SELL) this.curveSell(x, y);
        else if (action == A_GRADUATE) this.graduate(x * 16);
        else if (action == A_ACCRUE) this.hookAccrue(x, y);
        else if (action == A_HARVEST) this.harvest(x, prep);
        else if (action == A_DONATE) this.donate(x, y, z);
        else if (action == A_TRANSFER) this.transferMachine(x, y);
        else if (action == A_LIGHT) this.light(x, y, prep);
        else if (action == A_OPEN) this.openEpoch(prep, z % 2 == 0);
        else if (action == A_POKE) this.poke(x, z % 4 != 0);
        else if (action == A_CONVERT) this.convert(x, y, z, prep);
        else if (action == A_CONVERT_USDG) this.convertUsdg(x, y, z, prep);
        else if (action == A_CLAIM) this.claim(x, y, prep);
        else if (action == A_PAUSE) this.pauseToggle(x, y * 3);
        else if (action == A_STOCK_PAUSE) this.stockPause(x, y * 4);
        else if (action == A_TREASURY) this.treasuryReject(x * 3);
        else if (action == A_LOCK) this.lockHash(x, z % 3 == 0, prep);
        else if (action == A_REARM) this.rearmReveal(prep);
        else if (action == A_CLAIM_PARKED) this.claimParked(x, prep);
        else this.attack(x, y);
    }
}
