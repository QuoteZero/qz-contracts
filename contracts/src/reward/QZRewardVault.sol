// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IQZRewardVault} from "../interfaces/IQZRewardVault.sol";
import {IQZConverter} from "../interfaces/IQZConverter.sol";
import {IQZMachine} from "../interfaces/IQZMachine.sol";
import {QZConstants} from "../lib/QZConstants.sol";

/// @title QZRewardVault
/// @notice Stock-token reward accounting per machine and track (SPEC §2.5, I6), MasterChef style.
///
///         Per track `t`: `W[t]` = total weight of the lit standard machines (tier I..IV = 10/15/25/40), `acc[t]` =
///         stock units per weight in scale P = 1e36, `carry[t]` = fraction left over from the division (scale P).
///         The 2 relics take `10% x R / 2` of every `notify` (5% per lit relic) and draw from all ten tracks:
///         `relicAcc[t]` / `relicCarry[t]` per relic. Unlit relic slots fall back to the standard machines.
///
///         A machine enrolled after a `notify` gets nothing from it: standard `debtP = weight x acc[t]` and
///         relic `relicStart[r][t] = relicAcc[t]` are taken at hardwire. Claims round down and leave the fraction
///         recorded in `debtP` / `relicPaid`, so no fraction is paid twice (I6). A machine is keyed by `machineId`, not
///         by owner: a transfer needs no callback and the new owner simply inherits the unclaimed amount.
///
///         `claim` is never paused and is isolated per track (T10): a stock that reverts the transfer (paused, blocklisted,
///         the vault emptied by `adminBurn`) leaves that `(id, track)` unclaimed, raises `TrackFrozen` (or `ClaimFailed`
///         when only the claimant's own transfer fails) and does not
///         touch any other pair of the batch. `notify` pulls the stock with `transferFrom` and checks the balance
///         delta, so `balanceOf(vault) >= Σ claimable` holds at every `notify` and an earlier `adminBurn` cannot wedge
///         the accounting of new rewards.
contract QZRewardVault is IQZRewardVault {
    using SafeERC20 for IERC20;

    uint256 internal constant P = QZConstants.ACC_PRECISION;
    uint256 internal constant TRACKS = QZConstants.TRACK_COUNT;

    /// @dev `QZCore`: the only caller of `onHardwire`.
    address public immutable core;
    /// @dev `QZMachine`: ownership of a machine at home decides who claims (design B, §2.2).
    address public immutable machine;
    /// @dev `QZConverter`: the only caller of `notify`; its sealed routes name the stock token per track.
    address public immutable converter;

    struct Enrollment {
        bool enrolled;
        bool relic;
        uint8 track;
        /// @dev standard machine: tier weight; relic: unused
        uint8 weight;
    }

    mapping(uint8 track => uint256) internal _weightSum;
    mapping(uint8 track => uint256) internal _acc;
    mapping(uint8 track => uint256) internal _carry;
    mapping(uint8 track => uint256) internal _relicAcc;
    mapping(uint8 track => uint256) internal _relicCarry;
    mapping(uint8 track => uint256) internal _notified;
    mapping(uint8 track => uint256) internal _claimed;
    mapping(uint8 track => bool) internal _frozen;
    uint256 internal _relics;

    mapping(uint256 id => Enrollment) internal _enrollment;
    /// @dev standard machine: weight x acc[track] at enrolment plus everything paid out, scale P
    mapping(uint256 id => uint256) internal _debtP;
    /// @dev relic id: `relicAcc[t]` at enrolment, scale P
    mapping(uint256 id => mapping(uint8 track => uint256)) internal _relicStart;
    /// @dev relic id: stock units already paid per track
    mapping(uint256 id => mapping(uint8 track => uint256)) internal _relicPaid;

    uint256 private _entered = 1;

    constructor(address core_, address machine_, address converter_) {
        if (core_ == address(0) || machine_ == address(0) || converter_ == address(0)) revert ZeroAddress();
        core = core_;
        machine = machine_;
        converter = converter_;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    // ───────────── hardwire ─────────────

    /// @inheritdoc IQZRewardVault
    function onHardwire(uint256 id) external {
        if (msg.sender != core) revert NotCore(msg.sender);
        Enrollment storage e = _enrollment[id];
        if (e.enrolled) revert AlreadyEnrolled(id);

        (uint8 tier, uint8 track, bool relic) = IQZMachine(machine).traitsOf(id);
        e.enrolled = true;
        if (relic) {
            e.relic = true;
            ++_relics;
            for (uint8 t; t < TRACKS; ++t) {
                _relicStart[id][t] = _relicAcc[t];
            }
        } else {
            uint256 weight = QZConstants.weightOf(tier);
            if (track >= TRACKS) revert BadTrack(track);
            e.track = track;
            e.weight = uint8(weight);
            _weightSum[track] += weight;
            _debtP[id] = weight * _acc[track];
        }
    }

    // ───────────── notify ─────────────

    /// @inheritdoc IQZRewardVault
    /// @dev Pulls `amount` of the track's stock from the converter (which approved exactly that) and proves the
    ///      vault received it. The relic share is `amount x 10% x R / 2`, floored; the rest goes to the standard side.
    function notify(uint8 track, uint256 amount) external nonReentrant {
        if (msg.sender != converter) revert NotConverter(msg.sender);
        if (track >= TRACKS) revert BadTrack(track);
        if (amount == 0) revert ZeroAmount();
        uint256 w = _weightSum[track];
        if (w == 0) revert TrackNotActive(track);

        IERC20 token = IERC20(stockOf(track));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received < amount) revert Slippage(amount, received);

        uint256 r = _relics;
        uint256 rel = amount * QZConstants.RELIC_SHARE_BPS * r / (QZConstants.BPS * QZConstants.RELIC_COUNT);
        uint256 std = amount - rel;

        uint256 num = std * P + _carry[track];
        _acc[track] += num / w;
        _carry[track] = num % w;

        if (r != 0) {
            uint256 numR = rel * P + _relicCarry[track];
            _relicAcc[track] += numR / r;
            _relicCarry[track] = numR % r;
        }

        _notified[track] += amount;
        emit RewardNotified(track, amount, _acc[track]);
    }

    // ───────────── claim ─────────────

    /// @inheritdoc IQZRewardVault
    /// @dev A pair with nothing to claim is skipped (never reverts): a machine hardwired after the last `notify`
    ///      has `claimable == 0` and `claim` must not revert for it. A pair whose stock transfer fails is skipped and
    ///      its state restored; every other pair of the batch still pays. A failure that is the claimant's own (a
    ///      blocklisted recipient: the vault can still move `pay` to itself) raises `ClaimFailed` for that pair only;
    ///      a failure that would hit any recipient (paused token, blocklisted or emptied vault) freezes the track and
    ///      raises `TrackFrozen` with the revert data.
    function claim(uint256[] calldata ids, uint8[] calldata tracks) external nonReentrant {
        if (ids.length != tracks.length) revert LengthMismatch();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint8 track = tracks[i];
            if (track >= TRACKS) revert BadTrack(track);
            if (IQZMachine(machine).ownerOf(id) != msg.sender) revert NotOwnerOfMachine(id, msg.sender);

            uint256 pay = claimable(id, track);
            if (pay == 0) continue;

            _applyPayout(id, track, pay);
            (bool ok, bytes memory ret) = _tryTransfer(stockOf(track), msg.sender, pay);
            if (!ok) {
                _undoPayout(id, track, pay);
                (bool vaultCanPay,) = _tryTransfer(stockOf(track), address(this), pay);
                if (vaultCanPay) {
                    emit ClaimFailed(id, track, msg.sender, ret);
                } else {
                    _frozen[track] = true;
                    emit TrackFrozen(track, ret);
                }
                continue;
            }
            if (_frozen[track]) {
                _frozen[track] = false;
                emit TrackThawed(track);
            }
            emit Claimed(id, track, msg.sender, pay);
        }
    }

    /// @dev Effects of paying `pay` units to `(id, track)`: debt first, then the token moves (CEI).
    function _applyPayout(uint256 id, uint8 track, uint256 pay) internal {
        if (_enrollment[id].relic) _relicPaid[id][track] += pay;
        else _debtP[id] += pay * P;
        _claimed[track] += pay;
    }

    function _undoPayout(uint256 id, uint8 track, uint256 pay) internal {
        if (_enrollment[id].relic) _relicPaid[id][track] -= pay;
        else _debtP[id] -= pay * P;
        _claimed[track] -= pay;
    }

    /// @dev ERC-20 `transfer` that reports failure instead of reverting (also when the call returns `false`).
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool ok, bytes memory ret) {
        if (token.code.length == 0) return (false, "");
        (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && ret.length != 0) ok = ret.length >= 32 && abi.decode(ret, (bool));
    }

    // ───────────── views ─────────────

    /// @inheritdoc IQZRewardVault
    /// @dev Standard machine: `floor((weight x acc[track] - debtP) / P)`, only for its own track. Relic:
    ///      `floor((relicAcc[t] - relicStart) / P) - relicPaid`, any track. Never negative: `acc` and `relicAcc` only grow.
    function claimable(uint256 id, uint8 track) public view returns (uint256) {
        Enrollment memory e = _enrollment[id];
        if (!e.enrolled || track >= TRACKS) return 0;
        if (e.relic) return (_relicAcc[track] - _relicStart[id][track]) / P - _relicPaid[id][track];
        if (track != e.track) return 0;
        return (uint256(e.weight) * _acc[track] - _debtP[id]) / P;
    }

    function weightOf(uint8 track) external view returns (uint256) {
        return _weightSum[track];
    }

    function relicCount() external view returns (uint256) {
        return _relics;
    }

    function accPerWeight(uint8 track) external view returns (uint256) {
        return _acc[track];
    }

    function relicAccPerUnit(uint8 track) external view returns (uint256) {
        return _relicAcc[track];
    }

    /// @notice The stock token of `track`, from the converter's sealed route table.
    function stockOf(uint8 track) public view returns (address) {
        return IQZConverter(converter).routeOf(track).stock;
    }

    function trackFrozen(uint8 track) external view returns (bool) {
        return _frozen[track];
    }

    function totalNotified(uint8 track) external view returns (uint256) {
        return _notified[track];
    }

    function totalClaimed(uint8 track) external view returns (uint256) {
        return _claimed[track];
    }

    function isEnrolled(uint256 id) external view returns (bool) {
        return _enrollment[id].enrolled;
    }

    /// @notice Remainder of the standard division, scale P (< `W[track]`). Test and indexer visibility.
    function carryOf(uint8 track) external view returns (uint256 standard, uint256 relic) {
        return (_carry[track], _relicCarry[track]);
    }
}
