// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZPriceSource, PriceStatus} from "../interfaces/IQZPriceSource.sol";

/// @title QZBoardSource
/// @notice TESTNET ONLY, TRUSTED. A price board a keeper (`poster`) pushes `(track, ts, price)` entries to after each
///         close, for the Closing Bell proof on the Robinhood testnet, where the mock stocks have no real price. The
///         poster can also flag a track `Paused`. Nothing here is trust-minimised: the owner picks the poster and the
///         poster picks every price. Mainnet uses `QZChainlinkSource`.
///
///         The board is an append-only series per track (`ts` strictly increasing, never in the future). `priceAt`
///         returns the last entry at or before `ts`; `hint` is that entry's timestamp (0 when there is none) and a
///         wrong hint reverts, so a caller cannot pick the observation. An entry older than `maxAge` before `ts`
///         (or no entry at all) means `MarketClosed`: the poster "closes" a session by posting nothing for it.
///
///         `supportedMask` (immutable) lists the tracks the board serves; the testnet proof leaves out NFLX and RDDT
///         (bits 6 and 7) so the Bell treats them as not callable, as on mainnet.
contract QZBoardSource is IQZPriceSource {
    error ZeroAddress();
    error NotOwner(address caller);
    error NotPoster(address caller);
    error Unsupported(uint8 track);
    error BadEntry();
    error BadHint();
    error BadMaxAge();

    event PosterSet(address indexed poster);
    event Posted(uint8 indexed track, uint64 indexed ts, uint128 price);
    event PausedSet(uint8 indexed track, bool paused);

    address public immutable owner;
    /// @notice An observation older than this many seconds before the wanted `ts` is not a close.
    uint64 public immutable maxAge;
    uint16 public immutable supportedMask;

    address public poster;

    mapping(uint8 track => bool) public paused;
    mapping(uint8 track => uint64) public firstTs;
    mapping(uint8 track => uint64) public lastTs;
    mapping(uint8 track => mapping(uint64 ts => uint128)) public priceOfEntry;
    mapping(uint8 track => mapping(uint64 ts => uint64)) public nextTs;

    constructor(address owner_, address poster_, uint64 maxAge_, uint16 supportedMask_) {
        if (owner_ == address(0) || poster_ == address(0)) revert ZeroAddress();
        if (maxAge_ == 0) revert BadMaxAge();
        owner = owner_;
        poster = poster_;
        maxAge = maxAge_;
        supportedMask = supportedMask_;
        emit PosterSet(poster_);
    }

    /// @notice Owner only. Replaces the keeper.
    function setPoster(address poster_) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
        emit PosterSet(poster_);
    }

    /// @notice Poster only. Appends one observation.
    function post(uint8 track, uint64 ts, uint128 price) external {
        if (msg.sender != poster) revert NotPoster(msg.sender);
        if (!isSupported(track)) revert Unsupported(track);
        uint64 last = lastTs[track];
        if (price == 0 || ts <= last || ts > block.timestamp) revert BadEntry();
        priceOfEntry[track][ts] = price;
        if (last == 0) firstTs[track] = ts;
        else nextTs[track][last] = ts;
        lastTs[track] = ts;
        emit Posted(track, ts, price);
    }

    /// @notice Poster only. A paused track answers `Paused` to every `priceAt` until unflagged.
    function setPaused(uint8 track, bool value) external {
        if (msg.sender != poster) revert NotPoster(msg.sender);
        if (!isSupported(track)) revert Unsupported(track);
        paused[track] = value;
        emit PausedSet(track, value);
    }

    /// @inheritdoc IQZPriceSource
    function isSupported(uint8 track) public view returns (bool) {
        return track < 16 && (supportedMask >> track) & 1 == 1;
    }

    /// @inheritdoc IQZPriceSource
    function priceAt(uint8 track, uint64 ts, uint256 hint)
        external
        view
        returns (uint256 price, uint64 observedAt, PriceStatus status)
    {
        if (!isSupported(track)) return (0, 0, PriceStatus.NoSource);
        if (paused[track]) return (0, 0, PriceStatus.Paused);
        if (hint == 0) {
            uint64 first = firstTs[track];
            if (first != 0 && first <= ts) revert BadHint();
            return (0, 0, PriceStatus.MarketClosed);
        }
        if (hint > ts) revert BadHint();
        uint64 at = uint64(hint);
        price = priceOfEntry[track][at];
        if (price == 0) revert BadHint();
        uint64 next = nextTs[track][at];
        if (next != 0 && next <= ts) revert BadHint();
        if (ts - at > maxAge) return (price, at, PriceStatus.MarketClosed);
        return (price, at, PriceStatus.Ok);
    }
}
