// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZEntropy} from "../interfaces/IQZEntropy.sol";
import {IQZCore} from "../interfaces/IQZCore.sol";
import {QZConstants} from "../lib/QZConstants.sol";

/// @title QZEntropy
/// @notice Commit-reveal machine draw (SPEC §4.3). No admin, no owner powers: `onionRoot`, `revealer` and `core` are
///         immutable. The revealer can only submit the next hash-onion preimage; it cannot choose a value.
///
/// Hash onion. `onionRoot = H^N(s)` with `H = keccak256` over one 32 byte word. The k-th reveal (k = 1, 2, ...) is
///         `r_k = H^(N-k)(s)`, verified by `keccak256(r_k) == previous r` (`r_0 = onionRoot`). Epochs are revealed
///         strictly in order, one link per epoch, starting at the epoch of deployment, so N = 2 630 160 links last
///         3653 days, 10 years or more (`QZConstants.ONION_LENGTH`). `seed[e] = keccak256(abi.encode(r_e, e))` (two 32 byte words).
///
/// Queues. Tickets born in epoch b join the queue of b in call order. Epochs close at `(b + 1) * 120`. The queue of
///         b is drawn with `seed[b]` once `reveal(b)` lands within 1 hour of the close (`currentEpoch() < b + 31`).
///         If `reveal(b)` is late (or absent past the deadline), the whole queue of b moves, in front of whatever
///         the target holds, to the epoch that is open when the reveal lands (`EpochRolled(b, open)`), the "next
///         epoch still open" of §4.3 step 5. Reveals are sequential, so queues rolled into one target keep ascending
///         order, all in front of the tickets born there. The target freezes when it closes: it uses its own seed,
///         or rolls on if that reveal is late too. Withholding or delaying a reveal only delays the draw.
///         Because reveals are sequential, nothing at or after a missing epoch can be drawn until it is revealed.
///         Epochs are drawn in ascending order of their (effective) epoch; inside one, entries keep arrival order.
///
/// Freeze rules (§4.3 step 4). `effective epoch(b, t)` follows a ticket's queue: b, then the open epoch every late
///         reveal sent it to, and, for a reveal that has not landed yet and is already past its hour, the epoch open
///         at t. A ticket dissolved at time t:
///         - while its effective epoch is still open: leaves the queue (no draw is consumed);
///         - after that epoch closed and before it is drawn: keeps its slot (`Zombie`): the draw still happens with
///           the same seed and pool position, and the machine goes to the return buffer stamped with the dissolve
///           epoch;
///         - after it was drawn: its machine goes to the return buffer stamped with the current epoch.
///         Draw pool of effective epoch E = pool left by the previous draws + all buffered returns stamped <= E,
///         appended in ascending machineId order (an order that does not depend on arrival or `processQueue` slicing).
///         Returns stamped > E wait in the buffer. So inputs of E are fixed when E closes, before `r_E` is public.
///         The merge of the buffer into the pool is resumable and `processQueue(max)` spends at most
///         `MERGE_BUDGET x (1 + max / MERGE_DRAWS_PER_SLICE)` work units on it (about 2.5M gas per slice, so a call with
///         `max < 64`, such as the one inside `QZCore.hardwire`, merges at most about 2.5M gas): a holder who
///         dissolves thousands of drawn tickets cannot make one `processQueue` call exceed the block gas limit, he can
///         only make the draw of that epoch take a few more calls.
///
/// Exhaustion. When the pool of E runs dry in the middle of its queue (zombies and live tickets outnumber the
///         machines), the buffer is merged again with the same cutoff `<= E`: that takes in the machines of the
///         zombies drawn earlier in this very queue, whose stamps are old, and nothing stamped after E. If the pool
///         is still empty, a zombie is dropped (no machine, no callback) and a live ticket is carried, with the rest
///         of the queue and in the same order, to the next epoch whose seed is public (`E + 1`; the carry waits for
///         that reveal). It draws with that seed from the pool of `E + 1` (returns stamped <= E + 1). A return
///         stamped after the epoch whose seed a draw uses is never admitted.
///
/// Integration. `QZCore` MUST NOT call `onDissolve` when a ticket is burned by `hardwire`: a drawn machine that is
///         hardwired never returns to the pool (I3). Hardwire only consumes the ticket, the machine left the pool at
///         the draw.
contract QZEntropy is IQZEntropy {
    // ───────────── errors beyond the interface ─────────────

    error TicketIdTooLarge(uint256 ticketId);
    error AlreadyQueued(uint256 ticketId, uint64 nonce);
    error UnknownTicket(uint256 ticketId, uint64 nonce);
    error TicketNotDissolvable(uint256 ticketId, uint64 nonce);
    error ZeroOnionRoot();
    error Reentrancy();

    // ───────────── types ─────────────

    enum Status {
        None,
        Queued, // waiting for its draw, live
        Zombie, // dissolved after its epoch closed: draw still consumed, machine returns afterwards
        Removed, // dissolved while its epoch was open: not drawn
        Drawn, // machine assigned
        Returned // machine returned to the pool (ticket dissolved)
    }

    /// @dev One storage slot: 48 + 64 + 40 + 40 + 16 + 8 = 216 bits.
    struct Entry {
        uint48 ticketId;
        uint64 nonce;
        uint40 birth; // epoch the ticket was born in
        uint40 stamp; // epoch of the dissolve, for Zombie / Returned
        uint16 machineId;
        Status status;
    }

    /// @dev Tickets born in one epoch are contiguous in `_entries`; the segment ends where the next segment starts.
    struct Segment {
        uint32 start;
        uint32 next; // next segment id in the same group, 0 = none
    }

    struct Group {
        uint32 head;
        uint32 tail;
    }

    struct DrawItem {
        uint32 seg;
        uint40 epoch; // effective epoch whose seed draws this segment
    }

    enum Step {
        Skipped,
        Drawn,
        Exhausted
    }

    // ───────────── immutables ─────────────

    address public immutable override core;
    address public immutable override revealer;
    bytes32 public immutable override onionRoot;
    /// @dev Epoch of deployment: the first epoch to reveal.
    uint64 public immutable START_EPOCH;

    uint64 private constant EPOCH = QZConstants.EPOCH_DURATION;
    /// @dev `reveal(b)` is on time while `currentEpoch() < b + ROLL_EPOCHS` (1 hour after the close of b).
    uint64 private constant ROLL_EPOCHS = 1 + QZConstants.REVEAL_ROLLOVER / QZConstants.EPOCH_DURATION;
    /// @dev Bitmap words to cover machine ids 1..TOTAL_MACHINES.
    uint256 private constant BITMAP_WORDS = QZConstants.TOTAL_MACHINES / 256 + 1;
    /// @dev Merge work units: 1 per buffered machine skipped (one cold SLOAD, ~2.3k gas), `MERGE_APPEND_COST` per
    ///      machine appended to the pool (a fresh pool slot, ~25k gas). `processQueue(max)` may spend one slice of
    ///      `MERGE_BUDGET` units (about 2.5M gas), plus one more per `MERGE_DRAWS_PER_SLICE` draws it was asked for,
    ///      at most `MERGE_MAX_SLICES`: the merge work grows with the draws the caller pays for. A full buffer of all
    ///      machines needs 49 slices, so a caller that asks for thousands of draws gets the whole merge in one call.
    uint256 private constant MERGE_BUDGET = 1024;
    uint256 private constant MERGE_DRAWS_PER_SLICE = 64;
    uint256 private constant MERGE_MAX_SLICES = 64;
    uint256 private constant MERGE_APPEND_COST = 11;
    bytes32 private constant LOCK_SLOT = 0x4c6f636b5a45745261636b536c6f7451555a45726f456e74726f7079000000a1;

    // ───────────── reveal state ─────────────

    uint64 private _nextReveal;
    bytes32 private _lastR;
    mapping(uint64 => bytes32) private _seed;
    /// @dev Epoch a late `reveal(e)` rolled the queue of e into; 0 while on time or not revealed.
    mapping(uint64 => uint64) private _rollTo;

    // ───────────── queue state ─────────────

    Entry[] private _entries;
    /// @dev keccak(ticketId, nonce) => entry index + 1.
    mapping(bytes32 => uint32) private _slotOf;
    Segment[] private _segs; // segment id = index + 1
    mapping(uint40 => uint32) private _nativeSeg; // birth epoch => segment id of the tickets born then
    mapping(uint64 => Group) private _group; // epoch => segments rolled into it, in draw order (before its own)
    DrawItem[] private _items; // segments ready to draw, in draw order
    uint32 private _itemIdx;
    uint32 private _offset; // entries of `_items[_itemIdx]` already visited
    uint256 private _pending;

    // ───────────── pool state ─────────────

    /// @dev Virtual array: slot i holds `_pool[i]`, or `i + 1` while never written (initial pool = machines 1..4444).
    mapping(uint256 => uint16) private _pool;
    uint16 private _poolSize = uint16(QZConstants.TOTAL_MACHINES);
    uint64 private _poolEpoch; // epoch whose returns were last merged
    uint64 private _carry; // exhaustion carry: items draw with at least this epoch's seed and pool
    /// @dev Return buffer: one bit per machine id (bit set = returned and not yet in the pool) and the epoch stamp of
    ///      its return. A machine is in the buffer at most once (it left the pool when drawn), so the buffer never
    ///      holds more than `TOTAL_MACHINES` entries whatever the sequence of dissolves.
    mapping(uint256 word => uint256) private _retBits;
    mapping(uint256 => uint40) private _retStamp;
    uint16 private _retCount;

    /// @dev A merge that ran out of its per-call budget: `cursor` = next machine id to look at, `limit` = the
    ///      admission cutoff it was started with.
    struct MergeState {
        bool active;
        uint16 cursor;
        uint40 limit;
    }
    MergeState private _merge;

    constructor(address core_, address revealer_, bytes32 onionRoot_) {
        if (core_ == address(0) || revealer_ == address(0)) revert ZeroAddress();
        if (onionRoot_ == bytes32(0)) revert ZeroOnionRoot();
        core = core_;
        revealer = revealer_;
        onionRoot = onionRoot_;
        uint64 start = uint64(block.timestamp / EPOCH);
        START_EPOCH = start;
        _nextReveal = start;
        _lastR = onionRoot_;
    }

    modifier onlyCore() {
        if (msg.sender != core) revert NotCore(msg.sender);
        _;
    }

    modifier nonReentrant() {
        uint256 locked;
        bytes32 slot = LOCK_SLOT;
        assembly {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrancy();
        assembly {
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    // ───────────── reveal ─────────────

    /// @inheritdoc IQZEntropy
    function reveal(uint64 epoch, bytes32 r) external {
        if (msg.sender != revealer) revert NotRevealer(msg.sender);
        uint64 next = _nextReveal;
        if (epoch < next) revert EpochAlreadyRevealed(epoch);
        if (epoch > next) revert EpochOutOfOrder(epoch, next);
        uint64 cur = currentEpoch();
        if (cur <= epoch) revert EpochNotClosed(epoch, cur);
        if (keccak256(abi.encodePacked(r)) != _lastR) revert BadReveal(epoch, r);

        _lastR = r;
        _nextReveal = epoch + 1;
        bytes32 seed = keccak256(abi.encode(r, epoch));
        _seed[epoch] = seed;
        emit EpochRevealed(epoch, seed);

        uint64 to = cur;
        if (cur >= epoch + ROLL_EPOCHS) {
            _rollTo[epoch] = to;
            emit EpochRolled(epoch, to);
            _rollGroup(epoch, to);
        } else {
            _readyGroup(epoch);
        }
    }

    /// @dev Detach the whole queue of `epoch`: segments rolled into it, then the one born there. Returns head and tail.
    function _takeQueue(uint64 epoch) private returns (uint32 head, uint32 tail) {
        Group memory g = _group[epoch];
        delete _group[epoch];
        uint32 own = _nativeSeg[uint40(epoch)];
        if (own == 0) return (g.head, g.tail);
        if (g.head == 0) return (own, own);
        _segs[g.tail - 1].next = own;
        return (g.head, own);
    }

    /// @dev Move the whole queue of `from` behind what was already rolled into `to` (and in front of `to`'s own).
    function _rollGroup(uint64 from, uint64 to) private {
        (uint32 head, uint32 tail) = _takeQueue(from);
        if (head == 0) return;
        Group storage dst = _group[to];
        if (dst.head == 0) {
            dst.head = head;
        } else {
            _segs[dst.tail - 1].next = head;
        }
        dst.tail = tail;
    }

    /// @dev The queue of `epoch` is final and its seed is public: schedule its segments for drawing.
    function _readyGroup(uint64 epoch) private {
        (uint32 seg,) = _takeQueue(epoch);
        while (seg != 0) {
            _items.push(DrawItem({seg: seg, epoch: uint40(epoch)}));
            seg = _segs[seg - 1].next;
        }
    }

    // ───────────── queue (core only) ─────────────

    /// @inheritdoc IQZEntropy
    function enqueue(uint256 ticketId, uint64 nonce) external onlyCore {
        if (ticketId > type(uint48).max) revert TicketIdTooLarge(ticketId);
        bytes32 key = _key(ticketId, nonce);
        if (_slotOf[key] != 0) revert AlreadyQueued(ticketId, nonce);

        uint40 birth = uint40(currentEpoch());
        uint256 idx = _entries.length;
        uint32 seg = _nativeSeg[birth];
        if (seg == 0) {
            _segs.push(Segment({start: uint32(idx), next: 0}));
            _nativeSeg[birth] = uint32(_segs.length);
        }
        _entries.push(
            Entry({
                ticketId: uint48(ticketId), nonce: nonce, birth: birth, stamp: 0, machineId: 0, status: Status.Queued
            })
        );
        _slotOf[key] = uint32(idx + 1);
        ++_pending;
    }

    /// @inheritdoc IQZEntropy
    function onDissolve(uint256 ticketId, uint64 nonce) external onlyCore {
        uint32 slot = _slotOf[_key(ticketId, nonce)];
        if (slot == 0) revert UnknownTicket(ticketId, nonce);
        Entry storage e = _entries[slot - 1];
        Status st = e.status;
        uint64 cur = currentEpoch();

        if (st == Status.Queued) {
            if (cur > _effectiveEpoch(e.birth, cur)) {
                e.status = Status.Zombie;
                e.stamp = uint40(cur);
            } else {
                e.status = Status.Removed;
                --_pending;
            }
        } else if (st == Status.Drawn) {
            e.status = Status.Returned;
            e.stamp = uint40(cur);
            _addReturn(cur, e.machineId);
            emit MachineReturned(e.machineId, cur);
        } else {
            revert TicketNotDissolvable(ticketId, nonce);
        }
    }

    /// @dev Effective epoch of an undrawn ticket born in `birth`, as seen at epoch `cur`. See the contract notice.
    function _effectiveEpoch(uint64 birth, uint64 cur) private view returns (uint64 e) {
        e = birth;
        uint64 next = _nextReveal;
        while (true) {
            if (e < next) {
                uint64 to = _rollTo[e];
                if (to == 0) return e;
                e = to;
            } else {
                return cur >= e + ROLL_EPOCHS ? cur : e;
            }
        }
    }

    // ───────────── draw ─────────────

    /// @inheritdoc IQZEntropy
    function processQueue(uint256 max) external nonReentrant returns (uint256 processed) {
        uint256 budget = max;
        uint256 mergeLeft = _mergeAllowance(max);
        uint256 itemCount = _items.length;
        uint256 idx = _itemIdx;
        uint256 off = _offset;
        uint64 poolEpoch = _poolEpoch;
        uint64 carry = _carry;
        while (budget != 0 && idx < itemCount) {
            DrawItem memory it = _items[idx];
            uint256 start = _segs[it.seg - 1].start;
            uint256 end = _segEnd(it.seg);
            bool stalled;
            while (budget != 0 && start + off < end) {
                uint64 ep = it.epoch > carry ? uint64(it.epoch) : carry;
                // An open merge (saved by an earlier call that ran out of allowance, whether it started at an epoch
                // change or at pool exhaustion) is finished before any draw: a draw from a half-merged pool would
                // make the result depend on how the callers sliced `processQueue`.
                if (_merge.active || ep != poolEpoch) {
                    (bool merged, uint256 used) = _mergeReturns(ep, mergeLeft);
                    mergeLeft = used >= mergeLeft ? 0 : mergeLeft - used;
                    if (!merged) {
                        stalled = true;
                        break;
                    }
                    poolEpoch = ep;
                }
                Step step = _step(start + off, _seed[ep]);
                if (step == Step.Exhausted) {
                    (bool merged, uint256 used) = _mergeReturns(ep, mergeLeft);
                    mergeLeft = used >= mergeLeft ? 0 : mergeLeft - used;
                    if (!merged) {
                        stalled = true;
                        break;
                    }
                    if (_poolSize != 0) continue;
                    if (_dropZombie(start + off)) {
                        --budget;
                        ++off;
                        continue;
                    }
                    // Live ticket: carry to the next public seed, or wait for its reveal.
                    if (_seed[ep + 1] == 0) {
                        stalled = true;
                        break;
                    }
                    carry = ep + 1;
                    continue;
                }
                --budget;
                ++off;
                if (step == Step.Drawn) ++processed;
            }
            if (stalled) break;
            if (start + off == end) {
                ++idx;
                off = 0;
            }
        }
        _itemIdx = uint32(idx);
        _offset = uint32(off);
        _poolEpoch = poolEpoch;
        _carry = carry;
    }

    function _segEnd(uint32 seg) private view returns (uint256) {
        return seg < _segs.length ? _segs[seg].start : _entries.length;
    }

    function _dropZombie(uint256 entryIdx) private returns (bool) {
        Entry storage e = _entries[entryIdx];
        if (e.status != Status.Zombie) return false;
        e.status = Status.Removed;
        --_pending;
        return true;
    }

    function _step(uint256 entryIdx, bytes32 seed) private returns (Step) {
        Entry storage e = _entries[entryIdx];
        Status st = e.status;
        if (st != Status.Queued && st != Status.Zombie) return Step.Skipped;

        uint256 size = _poolSize;
        if (size == 0) return Step.Exhausted;

        uint256 ticketId = e.ticketId;
        uint64 nonce = e.nonce;
        uint16 machineId = _popPool(uint256(keccak256(abi.encode(seed, ticketId, nonce))) % size, size);
        --_pending;
        e.machineId = machineId;

        if (st == Status.Zombie) {
            e.status = Status.Returned;
            _addReturn(e.stamp, machineId);
            emit MachineReturned(machineId, e.stamp);
        } else {
            e.status = Status.Drawn;
            try IQZCore(core).onTicketRevealed(ticketId, nonce, machineId) {}
            catch {
                // The core refused the callback (it no longer knows this ticket): give the machine back.
                uint64 cur = currentEpoch();
                e.status = Status.Returned;
                e.stamp = uint40(cur);
                _addReturn(cur, machineId);
                emit MachineReturned(machineId, cur);
            }
        }
        return Step.Drawn;
    }

    // ───────────── pool ─────────────

    function _poolAt(uint256 i) private view returns (uint16 m) {
        m = _pool[i];
        if (m == 0) m = uint16(i + 1);
    }

    function _popPool(uint256 i, uint256 size) private returns (uint16 m) {
        uint256 last = size - 1;
        m = _poolAt(i);
        if (i != last) _pool[i] = _poolAt(last);
        _poolSize = uint16(last);
    }

    function _addReturn(uint64 stamp, uint16 machineId) private {
        _retStamp[machineId] = uint40(stamp);
        _retBits[machineId >> 8] |= 1 << (machineId & 255);
        ++_retCount;
    }

    /// @dev Merge work units a `processQueue(max)` call may spend: one slice plus one per `MERGE_DRAWS_PER_SLICE`
    ///      draws asked for, at most `MERGE_MAX_SLICES`.
    function _mergeAllowance(uint256 max) private pure returns (uint256) {
        uint256 slices = 1 + max / MERGE_DRAWS_PER_SLICE;
        return (slices > MERGE_MAX_SLICES ? MERGE_MAX_SLICES : slices) * MERGE_BUDGET;
    }

    /// @dev Append every buffered return stamped <= `limit` to the pool in ascending machineId order, spending at most
    ///      `allowance` work units (`used` is what it spent). A merge that reaches the allowance stops and returns
    ///      false; the next call resumes at the saved machine id with the saved limit, so the final pool order is the
    ///      same as in one go and a call costs at most what its caller asked for (a merge of every machine in one
    ///      transaction would exceed the block gas limit). The caller draws only after a merge returned true. A return
    ///      that arrives while a merge is open is stamped after its limit (the limit is an epoch whose seed is public,
    ///      so that epoch is closed), so it never enters the open merge.
    function _mergeReturns(uint64 limit, uint256 allowance) private returns (bool, uint256) {
        uint256 cursor;
        uint256 count = _retCount;
        if (_merge.active) {
            limit = _merge.limit;
            cursor = _merge.cursor;
        } else if (count == 0) {
            return (true, 0);
        }

        uint256 size = _poolSize;
        uint256 units;
        for (uint256 w = cursor >> 8; w < BITMAP_WORDS; ++w) {
            uint256 pending = _retBits[w];
            if (w == cursor >> 8) pending &= type(uint256).max << (cursor & 255);
            while (pending != 0) {
                uint256 id = (w << 8) + _lowestBitIndex(pending & (~pending + 1));
                if (units >= allowance) {
                    _retCount = uint16(count);
                    _poolSize = uint16(size);
                    _merge = MergeState({active: true, cursor: uint16(id), limit: uint40(limit)});
                    return (false, units);
                }
                pending &= pending - 1;
                if (_retStamp[id] <= limit) {
                    _pool[size++] = uint16(id);
                    _retBits[w] &= ~(uint256(1) << (id & 255));
                    --count;
                    units += MERGE_APPEND_COST;
                } else {
                    ++units;
                }
            }
        }
        _retCount = uint16(count);
        _poolSize = uint16(size);
        if (_merge.active) _merge = MergeState({active: false, cursor: 0, limit: 0});
        return (true, units);
    }

    /// @dev Index of the single set bit of `low`.
    function _lowestBitIndex(uint256 low) private pure returns (uint256 bit) {
        if (low >> 128 != 0) bit += 128;
        if ((low >> bit) & type(uint64).max == 0) bit += 64;
        if ((low >> bit) & type(uint32).max == 0) bit += 32;
        if ((low >> bit) & type(uint16).max == 0) bit += 16;
        if ((low >> bit) & type(uint8).max == 0) bit += 8;
        if ((low >> bit) & 0xf == 0) bit += 4;
        if ((low >> bit) & 0x3 == 0) bit += 2;
        if ((low >> bit) & 0x1 == 0) bit += 1;
    }

    function _key(uint256 ticketId, uint64 nonce) private pure returns (bytes32) {
        return keccak256(abi.encode(ticketId, nonce));
    }

    // ───────────── views ─────────────

    /// @inheritdoc IQZEntropy
    function seedOf(uint64 epoch) external view returns (bytes32) {
        return _seed[epoch];
    }

    /// @inheritdoc IQZEntropy
    function currentEpoch() public view returns (uint64) {
        return uint64(block.timestamp / EPOCH);
    }

    /// @inheritdoc IQZEntropy
    function pendingCount() external view returns (uint256) {
        return _pending;
    }

    /// @inheritdoc IQZEntropy
    /// @dev The epoch of the next draw item when one is ready, else the next epoch awaiting its reveal (nothing
    ///      below it has an undrawn queue).
    function nextEpochToProcess() external view returns (uint64) {
        return _itemIdx < _items.length ? uint64(_items[_itemIdx].epoch) : _nextReveal;
    }

    /// @inheritdoc IQZEntropy
    /// @dev Before the first reveal returns `(0, onionRoot)`.
    function lastRevealed() external view returns (uint64 epoch, bytes32 r) {
        uint64 next = _nextReveal;
        epoch = next == START_EPOCH ? 0 : next - 1;
        r = _lastR;
    }

    /// @notice Next epoch the revealer has to reveal.
    function nextReveal() external view returns (uint64) {
        return _nextReveal;
    }

    /// @inheritdoc IQZEntropy
    function poolSize() external view returns (uint256) {
        return _poolSize;
    }

    /// @inheritdoc IQZEntropy
    function mergeInProgress() external view returns (bool) {
        return _merge.active;
    }

    /// @inheritdoc IQZEntropy
    /// @dev Historical: stays set after the ticket dissolved and the machine returned to the pool.
    function machineOf(uint256 ticketId, uint64 nonce) external view returns (uint256) {
        uint32 slot = _slotOf[_key(ticketId, nonce)];
        if (slot == 0) return 0;
        return _entries[slot - 1].machineId;
    }

    /// @notice Whether `reveal(epoch)` landed after the 1 hour window (its queue rolled to the epoch open then).
    function isLate(uint64 epoch) external view returns (bool) {
        return _rollTo[epoch] != 0;
    }
}
