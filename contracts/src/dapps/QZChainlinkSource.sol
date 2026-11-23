// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQZPriceSource, PriceStatus} from "../interfaces/IQZPriceSource.sol";

/// @notice The part of a Chainlink data feed proxy (AggregatorV2V3) this adapter reads.
interface IChainlinkProxy {
    function decimals() external view returns (uint8);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title QZChainlinkSource
/// @notice MAINNET adapter: the Closing Bell's price source on Chainlink tokenized-equity feed proxies (proxies, not
///         aggregators: a proxy survives an aggregator upgrade). One feed per track; the owner registers them and then
///         `seal`s the source, after which nothing can change. NFLX and RDDT have no feed and stay unregistered, so the
///         Bell does not let those machines call.
///
///         `priceAt(track, ts, hint)`: `hint` is a round id. The adapter checks the round exists with
///         `updatedAt <= ts` and is the last such round (the latest round, or the next round is later than `ts`). A
///         hint that fails this reverts `BadHint`, so a caller cannot choose the observation and a wrong hint never
///         records a false void. The next round id is `hint + 1`; across a Chainlink phase change that round does not
///         exist and the hint cannot be proven, so the call reverts until the right hint is given or the Bell's
///         `VOID_AFTER` expiry voids the session (the mainnet fork test checks this boundary).
///
///         Status: no feed `NoSource`; `latestRoundData` reverts, answer not positive, round incomplete or the price
///         not fitting 128 bits `Paused`; `ts - updatedAt > maxAge` `MarketClosed`; else `Ok`.
///
///         Calm-day limit: the feeds publish on a 24 h heartbeat and a 0.5% deviation. On a day when the stock moves
///         less than that, the last round before the 4:00 PM ET close can be older than `maxAge` (default 2 h), and the
///         adapter then reports `MarketClosed`: the Bell voids the session (a refund, no streak change) instead of
///         settling. That is the safe direction (nobody loses an ante on a stale price) and a known cost of the feed;
///         `maxAge` is a constructor parameter so a deployment can fit it to what the fork test shows.
contract QZChainlinkSource is IQZPriceSource {
    error ZeroAddress();
    error NotOwner(address caller);
    error Sealed();
    error BadTrack(uint8 track);
    error BadFeed(address feed);
    error BadHint();
    error BadMaxAge();

    event FeedSet(uint8 indexed track, address feed);
    event SealedFeeds();

    uint8 internal constant TRACKS = 10;

    address public immutable owner;
    /// @notice Seconds a round may be older than the wanted `ts` and still count as a close.
    uint64 public immutable maxAge;

    bool public isSealed;
    mapping(uint8 track => address) public feeds;

    constructor(address owner_, uint64 maxAge_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (maxAge_ == 0) revert BadMaxAge();
        owner = owner_;
        maxAge = maxAge_;
    }

    /// @notice Owner only, before `seal`. Registers the feed proxy of `track`.
    function setFeed(uint8 track, address feed) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (isSealed) revert Sealed();
        if (track >= TRACKS) revert BadTrack(track);
        if (feed == address(0)) revert ZeroAddress();
        if (feed.code.length == 0) revert BadFeed(feed);
        try IChainlinkProxy(feed).decimals() returns (uint8 d) {
            if (d == 0 || d > 18) revert BadFeed(feed);
        } catch {
            revert BadFeed(feed);
        }
        feeds[track] = feed;
        emit FeedSet(track, feed);
    }

    /// @notice Owner only, once. The feed set is final.
    function seal() external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (isSealed) revert Sealed();
        isSealed = true;
        emit SealedFeeds();
    }

    /// @inheritdoc IQZPriceSource
    function isSupported(uint8 track) external view returns (bool) {
        return track < TRACKS && feeds[track] != address(0);
    }

    /// @inheritdoc IQZPriceSource
    function priceAt(uint8 track, uint64 ts, uint256 hint)
        external
        view
        returns (uint256 price, uint64 observedAt, PriceStatus status)
    {
        address feed = track < TRACKS ? feeds[track] : address(0);
        if (feed == address(0)) return (0, 0, PriceStatus.NoSource);
        if (hint > type(uint80).max) revert BadHint();

        uint80 latestId;
        try IChainlinkProxy(feed).latestRoundData() returns (uint80 id, int256, uint256, uint256, uint80) {
            latestId = id;
        } catch {
            return (0, 0, PriceStatus.Paused);
        }

        uint80 roundId = uint80(hint);
        int256 answer;
        uint256 updatedAt;
        uint80 answeredIn;
        try IChainlinkProxy(feed).getRoundData(roundId) returns (uint80, int256 a, uint256, uint256 u, uint80 ai) {
            (answer, updatedAt, answeredIn) = (a, u, ai);
        } catch {
            revert BadHint();
        }
        if (updatedAt == 0) return (0, 0, PriceStatus.Paused);
        if (updatedAt > ts) revert BadHint();

        if (roundId != latestId) {
            try IChainlinkProxy(feed).getRoundData(roundId + 1) returns (uint80, int256, uint256, uint256 nu, uint80) {
                if (nu == 0 || nu <= ts) revert BadHint();
            } catch {
                revert BadHint();
            }
        }

        if (answer <= 0 || answeredIn < roundId || uint256(answer) > type(uint128).max) {
            return (0, uint64(updatedAt), PriceStatus.Paused);
        }
        if (uint256(ts) - updatedAt > maxAge) return (uint256(answer), uint64(updatedAt), PriceStatus.MarketClosed);
        return (uint256(answer), uint64(updatedAt), PriceStatus.Ok);
    }
}
