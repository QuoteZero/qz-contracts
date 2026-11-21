// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The slice of the Pons v2 launchpad that `QZFeeSplitter` calls. Only the functions below are used; the
///         signatures were read off the verified Pons contracts on Robinhood Chain (docs/CONTRACT.md, "QZFeeSplitter").

/// @dev `PonsV2FeeEscrow`. The creator share of every sweep is credited to `creatorFeeRecipient`'s native ledger.
interface IPonsFeeEscrow {
    /// @notice Pay the caller its whole native balance (reverts `NoBalance` at zero, sends ETH to `msg.sender`).
    function claim() external returns (uint256 amount);

    function balanceOf(address recipient) external view returns (uint256);
}

/// @dev `PonsV2LaunchFactory`: only the launch record of one token.
interface IPonsFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

/// @dev The per-launch bonding curve, before graduation. Callable by the creator fee recipient or the sweep operator.
interface IPonsCurve {
    function sweepFees(uint256 minBuybackTokensOut) external;
}

/// @dev `MemeHook`, after graduation. Same callers as the curve; the creator may not trigger an internal swap.
interface IPonsHook {
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}
