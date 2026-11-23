// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZChainlinkSource} from "../../src/dapps/QZChainlinkSource.sol";
import {PriceStatus} from "../../src/interfaces/IQZPriceSource.sol";

interface IFeedLatest {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev Compatibility check against a real Chainlink proxy. Skipped unless `QZ_CL_FORK_URL` (an RPC URL of a chain
///      with the feed) and `QZ_CL_FEED` (the proxy) are set; CI and the default `forge test` run skip it. Read-only.
contract QZChainlinkSourceForkTest is Test {
    function test_liveFeedLatestRoundReadsOk() public {
        string memory url = vm.envOr("QZ_CL_FORK_URL", string(""));
        address feed = vm.envOr("QZ_CL_FEED", address(0));
        if (bytes(url).length == 0 || feed == address(0)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        QZChainlinkSource cl = new QZChainlinkSource(address(this), 1 days);
        cl.setFeed(0, feed);
        (uint80 id,, uint256 updatedAt,,) = IFeedLatest(feed).latestRoundData();
        (uint256 p, uint64 at, PriceStatus s) = cl.priceAt(0, uint64(updatedAt), id);
        assertEq(uint8(s), uint8(PriceStatus.Ok));
        assertGt(p, 0);
        assertEq(at, updatedAt);
    }
}
