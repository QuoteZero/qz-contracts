// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Fork helper for tests that need real Robinhood Chain state (PoolManager, WETH, stock tokens, LZ endpoint).
///         RPC from env `ROBINHOOD_RPC_URL` (default: the public read-only node). Optional `ROBINHOOD_FORK_BLOCK` pins a
///         block (needs an archive node); default is the latest block. No key is ever needed.
abstract contract RobinhoodFork is Test {
    string internal constant DEFAULT_ROBINHOOD_RPC = "https://robinhood-rpc.publicnode.com";
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    uint256 internal robinhoodForkId;

    function _robinhoodRpcUrl() internal view returns (string memory) {
        return vm.envOr("ROBINHOOD_RPC_URL", DEFAULT_ROBINHOOD_RPC);
    }

    /// @dev Creates and selects the fork. Call from `setUp()`.
    function _selectRobinhoodFork() internal returns (uint256 forkId) {
        uint256 pinned = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        forkId = pinned == 0 ? vm.createSelectFork(_robinhoodRpcUrl()) : vm.createSelectFork(_robinhoodRpcUrl(), pinned);
        robinhoodForkId = forkId;
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RobinhoodFork: wrong chain id");
    }
}
