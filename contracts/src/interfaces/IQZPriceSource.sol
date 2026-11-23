// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What a price source says about a ticker at one timestamp.
enum PriceStatus {
    NoSource, // 0: no feed is registered for the track
    Ok, // 1: `price` is the last observation at or before `ts`, fresh enough to be a close
    MarketClosed, // 2: the last observation is older than the source's `MAX_AGE` (frozen or stale feed), or there is none
    Paused // 3: the source cannot answer now (feed reverted, bad answer, incomplete round, or flagged by the poster)
}

/// @title IQZPriceSource
/// @notice The price adapter the Closing Bell reads at a close. The answer is the last observation at or before `ts`
///         and never "whatever is latest when the caller shows up", so the caller cannot choose the moment.
///
///         `priceAt` is `view`: the Bell calls it with STATICCALL, so a source cannot write state or re-enter the Bell.
///         A source proves an answer with `hint` (an observation id or timestamp the caller found offchain) and
///         reverts on a hint that is not the last observation at or before `ts`; it never answers `MarketClosed` or
///         `NoSource` for a wrong hint, so a wrong hint can never record a false void in the Bell.
interface IQZPriceSource {
    /// @param track ticker track 0..9 (NVDA, AAPL, TSLA, GME, SPY, PLTR, NFLX, RDDT, MSTR, SPCX)
    /// @param ts the timestamp the price is wanted at (a close)
    /// @param hint observation id (Chainlink round id) or observation timestamp (board)
    /// @return price the observed price (the feed's own decimals; only ratios of the same track are compared)
    /// @return observedAt when the observation was made; zero when there is none
    /// @return status see `PriceStatus`
    function priceAt(uint8 track, uint64 ts, uint256 hint)
        external
        view
        returns (uint256 price, uint64 observedAt, PriceStatus status);

    /// @notice Whether the source can ever answer for `track`. False for a track without a feed (the Bell treats the
    ///         track as not callable). Constant for the life of a sealed source.
    function isSupported(uint8 track) external view returns (bool);
}
