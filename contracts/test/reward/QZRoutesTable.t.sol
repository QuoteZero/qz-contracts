// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZRoutes} from "../../src/reward/QZRoutes.sol";
import {QZAddresses} from "../../src/lib/QZAddresses.sol";
import {QZConstants as C} from "../../src/lib/QZConstants.sol";
import {StockRoute} from "../../src/lib/QZTypes.sol";

/// @notice The ten-route table the testnet deployment feeds to `QZConverter.setRoute`. The mainnet table is pinned by hash (the
///         pool parameters and the ten stock addresses); a testnet table differs only in the stock addresses.
contract QZRoutesTableTest is Test {
    bytes32 internal constant MAINNET_TABLE_HASH = 0xef65eb6478ac4e243b53fd68202ee5a9efe774b3ac0cb44de54d98aa1e93e205;

    function _mainnetTable() internal pure returns (StockRoute[] memory rs) {
        rs = new StockRoute[](C.TRACK_COUNT);
        for (uint8 t; t < C.TRACK_COUNT; ++t) {
            rs[t] = QZRoutes.route(t);
        }
    }

    function test_mainnetTableIsPinned() public pure {
        assertEq(keccak256(abi.encode(_mainnetTable())), MAINNET_TABLE_HASH, "mainnet route table changed");
    }

    function test_explicitStockOnlyChangesTheStock() public pure {
        for (uint8 t; t < C.TRACK_COUNT; ++t) {
            address stock = address(uint160(0xA000 + t));
            StockRoute memory main_ = QZRoutes.route(t);
            StockRoute memory custom = QZRoutes.route(t, stock);
            assertEq(custom.stock, stock);
            assertEq(custom.hooks, main_.hooks);
            assertEq(custom.poolFee, main_.poolFee);
            assertEq(custom.tickSpacing, main_.tickSpacing);
            assertEq(custom.v3Fee, main_.v3Fee);
            assertEq(custom.maxChunk, main_.maxChunk);
            assertEq(custom.fallbackDailyCap, main_.fallbackDailyCap);
            assertEq(main_.stock, QZAddresses.stockOf(t));
        }
    }

    function test_badTrackReverts() public {
        vm.expectRevert(abi.encodeWithSelector(QZRoutes.BadTrack.selector, uint8(10)));
        this.routeExt(10);
    }

    function routeExt(uint8 t) external pure returns (StockRoute memory) {
        return QZRoutes.route(t);
    }
}
