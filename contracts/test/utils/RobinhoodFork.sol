// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Fork helper for tests that need real Robinhood Chain state (PoolManager, WETH, stock tokens, LZ endpoint).
///         Reproducible by default: the fork is pinned to block `DEFAULT_ROBINHOOD_FORK_BLOCK` on an archive node (the
///         public read-only nodes keep state for about 100 blocks only, so a latest-block fork is not reproducible).
///         Override the RPC with env `ROBINHOOD_RPC_URL` (any archive node; no key is needed for the default) and the
///         block with `ROBINHOOD_FORK_BLOCK` (`0` = latest block, needs no archive state).
abstract contract RobinhoodFork is Test {
    string internal constant DEFAULT_ROBINHOOD_RPC = "https://robinhood-mainnet.n.conduit.xyz";
    uint256 internal constant DEFAULT_ROBINHOOD_FORK_BLOCK = 115_470_000;
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    uint256 internal robinhoodForkId;

    function _robinhoodRpcUrl() internal view returns (string memory) {
        return vm.envOr("ROBINHOOD_RPC_URL", DEFAULT_ROBINHOOD_RPC);
    }

    /// @dev Creates and selects the fork. Call from `setUp()`.
    function _selectRobinhoodFork() internal returns (uint256 forkId) {
        uint256 pinned = vm.envOr("ROBINHOOD_FORK_BLOCK", DEFAULT_ROBINHOOD_FORK_BLOCK);
        forkId = pinned == 0 ? vm.createSelectFork(_robinhoodRpcUrl()) : vm.createSelectFork(_robinhoodRpcUrl(), pinned);
        robinhoodForkId = forkId;
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RobinhoodFork: wrong chain id");
    }
}
