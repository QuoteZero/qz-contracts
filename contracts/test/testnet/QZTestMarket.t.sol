// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QZTestMarket} from "../../src/testnet/QZTestMarket.sol";
import {TestQz, TestMachine} from "./TestMocks.sol";

contract QZTestMarketTest is Test {
    QZTestMarket internal market;
    TestQz internal qz;
    TestMachine internal nft;
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Delisted(uint256 indexed tokenId, address indexed seller);
    event Bought(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price);

    function setUp() public {
        vm.warp(1_800_000_000);
        qz = new TestQz();
        nft = new TestMachine();
        market = new QZTestMarket(nft, qz, 100_000e18);
        for (uint256 i = 1; i <= 5; ++i) {
            nft.mint(seller, i);
        }
        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
        qz.mint(buyer, 1_000_000e18);
        vm.prank(buyer);
        qz.approve(address(market), type(uint256).max);
    }

    function _list(uint256 id, uint256 price) internal {
        vm.prank(seller);
        market.list(id, price);
    }

    function test_listBuyMovesMachineAndMoneyAndEmitsEvents() public {
        vm.expectEmit(true, true, false, true);
        emit Listed(1, seller, 25_000e18);
        _list(1, 25_000e18);
        assertEq(market.listingCount(), 1);
        (address s, uint256 p) = market.listingOf(1);
        assertEq(s, seller);
        assertEq(p, 25_000e18);
        assertTrue(market.isBuyable(1));
        vm.expectEmit(true, true, true, true);
        emit Bought(1, buyer, seller, 25_000e18);
        vm.prank(buyer);
        market.buy(1);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(qz.balanceOf(seller), 25_000e18);
        assertEq(qz.balanceOf(buyer), 975_000e18);
        assertEq(market.listingCount(), 0);
        (, p) = market.listingOf(1);
        assertEq(p, 0);
    }

    function test_oneBuyPerWalletPerDay() public {
        _list(1, 25_000e18);
        _list(2, 40_000e18);
        vm.prank(buyer);
        market.buy(1);
        uint256 end = block.timestamp + 1 days;
        assertEq(market.nextBuyAt(buyer), end);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(QZTestMarket.Cooldown.selector, end));
        market.buy(2);
        vm.warp(end - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(QZTestMarket.Cooldown.selector, end));
        market.buy(2);
        vm.warp(end);
        vm.prank(buyer);
        market.buy(2);
        assertEq(nft.ownerOf(2), buyer);
        assertEq(market.nextBuyAt(stranger), 0);
    }

    function test_buyWithTooLittleQzReverts() public {
        _list(1, 25_000e18);
        address poor = makeAddr("poor");
        qz.mint(poor, 24_999e18);
        vm.startPrank(poor);
        qz.approve(address(market), type(uint256).max);
        vm.expectRevert();
        market.buy(1);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), seller);
        assertEq(market.nextBuyAt(poor), 0);
    }

    function test_buyWithoutApprovalOfQzReverts() public {
        _list(1, 25_000e18);
        vm.prank(stranger);
        vm.expectRevert();
        market.buy(1);
    }

    function test_soldDelistedOrUnknownMachinesCannotBeBought() public {
        _list(1, 25_000e18);
        vm.prank(buyer);
        market.buy(1);
        address other = makeAddr("other");
        qz.mint(other, 1_000_000e18);
        vm.prank(other);
        qz.approve(address(market), type(uint256).max);
        vm.startPrank(other);
        vm.expectRevert(QZTestMarket.NotListed.selector); // sold
        market.buy(1);
        vm.expectRevert(QZTestMarket.NotListed.selector); // never listed
        market.buy(3);
        vm.expectRevert(QZTestMarket.NotListed.selector); // not a token
        market.buy(999);
        vm.stopPrank();
        _list(3, 25_000e18);
        vm.expectEmit(true, true, false, true);
        emit Delisted(3, seller);
        vm.prank(seller);
        market.delist(3);
        vm.prank(other);
        vm.expectRevert(QZTestMarket.NotListed.selector); // delisted
        market.buy(3);
    }

    function test_listByANonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(QZTestMarket.NotOwner.selector);
        market.list(1, 25_000e18);
        // a listed machine's price cannot be changed by someone else either
        _list(1, 25_000e18);
        vm.prank(stranger);
        vm.expectRevert(QZTestMarket.NotOwner.selector);
        market.list(1, 1);
    }

    function test_delistByAStrangerReverts() public {
        _list(1, 25_000e18);
        vm.prank(stranger);
        vm.expectRevert(QZTestMarket.NotOwner.selector);
        market.delist(1);
        vm.expectRevert(QZTestMarket.NotListed.selector);
        market.delist(2);
    }

    function test_priceBoundsAndApproval() public {
        vm.startPrank(seller);
        vm.expectRevert(abi.encodeWithSelector(QZTestMarket.BadPrice.selector, 0));
        market.list(1, 0);
        vm.expectRevert(abi.encodeWithSelector(QZTestMarket.BadPrice.selector, 100_000e18 + 1));
        market.list(1, 100_000e18 + 1);
        market.list(1, 100_000e18);
        nft.setApprovalForAll(address(market), false);
        vm.expectRevert(QZTestMarket.Unapproved.selector);
        market.list(2, 1e18);
        nft.approve(address(market), 2); // a single approval is enough
        market.list(2, 1e18);
        vm.stopPrank();
    }

    function test_staleListingsCannotBeBoughtAndAnyonePrunes() public {
        _list(1, 25_000e18);
        _list(2, 25_000e18);
        vm.startPrank(seller);
        nft.transferFrom(seller, stranger, 1); // moved away
        nft.setApprovalForAll(address(market), false); // approval withdrawn: also makes 2 stale
        vm.stopPrank();
        assertFalse(market.isBuyable(1));
        assertFalse(market.isBuyable(2));
        vm.startPrank(buyer);
        vm.expectRevert(QZTestMarket.NotListed.selector);
        market.buy(1);
        vm.expectRevert(QZTestMarket.NotListed.selector);
        market.buy(2);
        vm.stopPrank();
        market.prune(1);
        market.prune(2);
        assertEq(market.listingCount(), 0);
        vm.expectRevert(QZTestMarket.NotListed.selector);
        market.prune(1);
    }

    function test_pruneOfAValidListingReverts() public {
        _list(1, 25_000e18);
        vm.expectRevert(QZTestMarket.ListingValid.selector);
        market.prune(1);
    }

    function test_sellerCannotBuyOwnMachine() public {
        _list(1, 25_000e18);
        qz.mint(seller, 25_000e18);
        vm.startPrank(seller);
        qz.approve(address(market), type(uint256).max);
        vm.expectRevert(QZTestMarket.SelfBuy.selector);
        market.buy(1);
        vm.stopPrank();
    }

    function test_listManyAndPagingSurviveSwapRemoves() public {
        uint256[] memory ids = new uint256[](5);
        uint256[] memory prices = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            ids[i] = i + 1;
            prices[i] = (i + 1) * 10_000e18;
        }
        vm.prank(seller);
        market.listMany(ids, prices);
        assertEq(market.listingCount(), 5);
        vm.prank(seller);
        market.delist(2); // swap-remove: 5 takes its slot
        (uint256[] memory t, uint256[] memory p, address[] memory s) = market.listingsPage(0, 10);
        assertEq(t.length, 4);
        for (uint256 i; i < t.length; ++i) {
            assertEq(p[i], t[i] * 10_000e18);
            assertEq(s[i], seller);
        }
        (t,,) = market.listingsPage(3, 10);
        assertEq(t.length, 1);
        (t,,) = market.listingsPage(4, 10);
        assertEq(t.length, 0);
        (t,,) = market.listingsPage(99, 10);
        assertEq(t.length, 0);
        vm.prank(seller);
        vm.expectRevert(QZTestMarket.LengthMismatch.selector);
        market.listMany(ids, new uint256[](1));
    }

    function test_relistChangesThePriceWithoutDuplicates() public {
        _list(1, 25_000e18);
        _list(1, 30_000e18);
        assertEq(market.listingCount(), 1);
        (, uint256 p) = market.listingOf(1);
        assertEq(p, 30_000e18);
    }

    function test_mainnetIsRefused() public {
        vm.chainId(4663);
        vm.expectRevert(QZTestMarket.WrongChain.selector);
        new QZTestMarket(nft, qz, 1);
    }
}
