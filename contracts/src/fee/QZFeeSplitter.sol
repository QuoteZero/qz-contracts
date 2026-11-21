// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZFeeSplitter} from "../interfaces/IQZFeeSplitter.sol";
import {QZConstants} from "../lib/QZConstants.sol";
import {IPonsFeeEscrow, IPonsFactory, IPonsCurve, IPonsHook} from "./IPons.sol";

/// @title QZFeeSplitter
/// @notice The creator-fee recipient of the QZ launch on Pons. It has no admin: after the owner's single `bind` the
///         recipients and the 20:7 ratio are fixed, and nothing in this contract can move the creator-fee role or any
///         funds anywhere else. See `IQZFeeSplitter` for the behaviour; this file adds the Pons wiring.
///
///         Constructor: the Pons fee escrow, the Pons launch factory, the QZ token address and the Pons hook. The token
///         address is known before the launch (`predictLaunchAddresses`), so this contract is deployed first and is then
///         named as the launch's creator-fee recipient; the launch record (curve, phase, pool parameters) is read from the
///         factory on every harvest.
///
///         `harvest()`:
///           1. asks Pons to sweep the accrued fee into the escrow: `curve.sweepFees(0)` before graduation,
///              `hook.sweepPoolFees(poolId, 0, 0)` after it. The call is made as the creator, which Pons allows when no
///              internal swap is needed. If Pons refuses (it needs its operator for a conversion, or the launch is not
///              yet registered), or the factory is gone or answers in a shape this contract does not understand (the
///              record is read with a bounded `staticcall` and every field is range-checked, so a Pons upgrade cannot
///              revert the decode), the failure is logged and the harvest goes on with what the escrow already holds;
///           2. claims the escrow balance (ETH, native-ETH pair) and splits the whole ETH balance of this contract:
///              `total * 20 / 27` (rounded down) to the converter, everything else to the treasury. The balance is split,
///              not only the claimed amount, so ETH sent here directly cannot stay behind as dust. `total` is the
///              splitter's whole ETH balance after the claim, less the treasury share still waiting to be pulled;
///              `NothingToHarvest` means that amount is zero.
///
///         Recipient failure. The converter is a contract of this system: if its push fails the whole harvest reverts
///         (`TransferFailed`), nothing moves, and the fee stays in the Pons escrow; that is an incident to see, and the
///         reward share must never be paid anywhere else. The treasury is an address chosen at `bind` and cannot be
///         changed, so its push is made with a bounded gas stipend and, when it fails, the share is parked in
///         `pendingTreasury` and the harvest still completes. Only the treasury itself can pull it, to an address of its
///         choice (`claimPendingTreasury`); this gives nobody any new power over funds. The parked ETH stays in this
///         contract's balance, so the ledger `totalToConverter + totalToTreasury + balance + escrow balance` always
///         equals everything Pons ever credited plus what was sent here by hand.
///
///         ETH is the only asset the splitter handles; it holds none between calls except a parked treasury share. A
///         token other than ETH that lands here (Pons pays an ERC-20 creator share only for non-ETH pairs) has no exit;
///         the QZ launch is an ETH pair.
contract QZFeeSplitter is IQZFeeSplitter {
    // ───────────── events / errors (implementation detail, not part of the interface) ─────────────

    /// @notice The Pons sweep was skipped (it reverted: needs the operator, or the pool is not registered yet; or the
    ///         factory read failed: no code, short or malformed answer); the escrow was still claimed. `reason` is the
    ///         raw revert data, or `"factory read"`.
    event SweepSkipped(bytes reason);

    // ───────────── immutables / storage ─────────────

    /// @inheritdoc IQZFeeSplitter
    address public immutable override owner;
    /// @notice Pons `PonsV2FeeEscrow`.
    IPonsFeeEscrow public immutable ESCROW;
    /// @notice Pons `PonsV2LaunchFactory`.
    IPonsFactory public immutable FACTORY;
    /// @notice The QZ token (the launch this splitter collects for).
    address public immutable TOKEN;
    /// @notice Pons `MemeHook` (post-graduation fee sweep).
    address public immutable HOOK;

    /// @inheritdoc IQZFeeSplitter
    uint256 public constant override REWARD_PART = QZConstants.REWARD_PART;
    /// @inheritdoc IQZFeeSplitter
    uint256 public constant override TREASURY_PART = QZConstants.TREASURY_PART;

    /// @notice Gas forwarded to the treasury on a harvest push; a treasury that needs more (or reverts, or burns it)
    ///         gets its share parked instead of blocking the harvest.
    uint256 public constant TREASURY_PUSH_GAS = 100_000;

    /// @notice Gas forwarded to the Pons factory for the launch-record read (about 40k are needed); a factory that burns
    ///         more is treated like a missing one.
    uint256 public constant FACTORY_READ_GAS = 200_000;
    /// @notice Words of the Pons launch record this contract reads (`LaunchedToken` has 15 static fields).
    uint256 private constant RECORD_WORDS = 15;

    /// @inheritdoc IQZFeeSplitter
    address public override converter;
    /// @inheritdoc IQZFeeSplitter
    address public override treasury;
    /// @inheritdoc IQZFeeSplitter
    uint256 public override totalToConverter;
    /// @notice ETH delivered to the treasury (pushed by a harvest or pulled with `claimPendingTreasury`).
    uint256 public override totalToTreasury;
    /// @inheritdoc IQZFeeSplitter
    uint256 public override pendingTreasury;

    bool private _locked;

    constructor(address owner_, address escrow_, address factory_, address token_, address hook_) {
        if (
            owner_ == address(0) || escrow_ == address(0) || factory_ == address(0) || token_ == address(0)
                || hook_ == address(0)
        ) {
            revert ZeroAddress();
        }
        owner = owner_;
        ESCROW = IPonsFeeEscrow(escrow_);
        FACTORY = IPonsFactory(factory_);
        TOKEN = token_;
        HOOK = hook_;
    }

    /// @dev Pons pays the creator share with a plain ETH call from the escrow; anyone may also send ETH here, it is
    ///      split by the next `harvest`.
    receive() external payable {}

    // ───────────── bind ─────────────

    /// @inheritdoc IQZFeeSplitter
    function bind(address converter_, address treasury_) external override {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (isBound()) revert AlreadyBound();
        if (converter_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        converter = converter_;
        treasury = treasury_;
        emit Bound(converter_, treasury_);
    }

    // ───────────── harvest ─────────────

    /// @inheritdoc IQZFeeSplitter
    function harvest() external override returns (uint256 toConverter, uint256 toTreasury) {
        if (_locked) revert Reentrancy();
        _locked = true;

        address converter_ = converter;
        address treasury_ = treasury;
        if (converter_ == address(0)) revert NotBound();

        _sweep();
        // `claim()` reverts `NoBalance` at zero; check first so a donation-only harvest still works.
        if (ESCROW.balanceOf(address(this)) != 0) ESCROW.claim();

        // A parked treasury share is already allocated; it is not split again.
        uint256 total = address(this).balance - pendingTreasury;
        if (total == 0) revert NothingToHarvest();

        toConverter = total * REWARD_PART / (REWARD_PART + TREASURY_PART);
        toTreasury = total - toConverter;

        // Effects before interactions. The treasury share is parked first and released only once the push succeeds.
        totalToConverter += toConverter;
        pendingTreasury += toTreasury;
        emit Harvested(msg.sender, total, toConverter, toTreasury);

        _send(converter_, toConverter);

        if (toTreasury != 0) {
            pendingTreasury -= toTreasury;
            (bool ok,) = treasury_.call{value: toTreasury, gas: TREASURY_PUSH_GAS}("");
            if (ok) {
                totalToTreasury += toTreasury;
            } else {
                pendingTreasury += toTreasury;
                emit TreasuryShareParked(treasury_, toTreasury);
            }
        }

        _locked = false;
    }

    /// @inheritdoc IQZFeeSplitter
    function claimPendingTreasury(address to) external override returns (uint256 amount) {
        if (_locked) revert Reentrancy();
        _locked = true;
        if (msg.sender != treasury) revert NotTreasury(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        amount = pendingTreasury;
        if (amount == 0) revert NothingPending();

        pendingTreasury = 0;
        totalToTreasury += amount;
        emit TreasuryShareClaimed(to, amount);
        _send(to, amount);

        _locked = false;
    }

    // ───────────── views ─────────────

    /// @inheritdoc IQZFeeSplitter
    function isBound() public view override returns (bool) {
        return converter != address(0);
    }

    // ───────────── internals ─────────────

    /// @dev Ask Pons to move the accrued fee into the escrow. Never reverts: a refusal, a missing factory or a changed
    ///      factory ABI must not block claiming what the escrow already holds.
    function _sweep() private {
        (bool read, IPonsFactory.LaunchedToken memory info) = _readLaunch();
        if (!read) {
            emit SweepSkipped("factory read");
            return;
        }
        if (!info.exists) return;

        if (info.phase == 0) {
            try IPonsCurve(info.curve).sweepFees(0) {}
            catch (bytes memory reason) {
                emit SweepSkipped(reason);
            }
        } else {
            try IPonsHook(HOOK).sweepPoolFees(_poolId(info), 0, 0) {}
            catch (bytes memory reason) {
                emit SweepSkipped(reason);
            }
        }
    }

    /// @dev `FACTORY.getLaunchedToken(TOKEN)` without the compiler's decoder: a call to an address without code, a
    ///      reverting factory, a payload shorter than the 15 words relied on, or any field outside its type (dirty
    ///      address bits, a `bool` above 1, a `uint8`/`uint24`/`int24` out of range) returns `ok = false` instead of
    ///      reverting. At most 15 words are copied and the factory gets `FACTORY_READ_GAS`, so an oversized or gas-burning
    ///      answer cannot cost the harvest more than a bounded amount.
    function _readLaunch() private view returns (bool ok, IPonsFactory.LaunchedToken memory info) {
        address factory = address(FACTORY);
        bytes memory data = new bytes(RECORD_WORDS * 32);
        uint256 size;
        bool success;
        bytes memory callData = abi.encodeCall(IPonsFactory.getLaunchedToken, (TOKEN));
        uint256 readGas = FACTORY_READ_GAS;
        assembly ("memory-safe") {
            success := staticcall(readGas, factory, add(callData, 0x20), mload(callData), add(data, 0x20), 480)
            size := returndatasize()
        }
        // a call to an address without code succeeds with an empty answer, which the size check rejects
        if (!success || size < RECORD_WORDS * 32) return (false, info);

        uint256[RECORD_WORDS] memory w;
        for (uint256 i; i < RECORD_WORDS; ++i) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 0x20), mul(i, 0x20)))
            }
            w[i] = word;
        }
        if (
            w[0] >> 160 != 0 || w[1] >> 160 != 0 || w[2] >> 160 != 0 || w[3] >> 160 != 0 || w[4] >> 160 != 0
                || w[6] >> 24 != 0 || w[10] > type(uint8).max || w[14] > 1 || !_fitsInt24(w[7])
        ) {
            return (false, info);
        }

        info.token = address(uint160(w[0]));
        info.curve = address(uint160(w[1]));
        info.pairToken = address(uint160(w[4]));
        info.poolFee = uint24(w[6]);
        info.tickSpacing = int24(int256(w[7]));
        info.phase = uint8(w[10]);
        info.exists = w[14] == 1;
        return (true, info);
    }

    /// @dev True when the sign-extended word is a valid `int24`.
    function _fitsInt24(uint256 word) private pure returns (bool) {
        int256 v = int256(word);
        return v >= -(int256(1) << 23) && v < (int256(1) << 23);
    }

    /// @dev Uniswap v4 pool id of the graduated ETH/QZ pool: keccak of the key (currency0, currency1, fee,
    ///      tickSpacing, hooks), currencies sorted, native ETH being address(0).
    function _poolId(IPonsFactory.LaunchedToken memory info) private view returns (bytes32) {
        (address c0, address c1) =
            info.pairToken < info.token ? (info.pairToken, info.token) : (info.token, info.pairToken);
        return keccak256(abi.encode(c0, c1, info.poolFee, info.tickSpacing, HOOK));
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
    }
}
