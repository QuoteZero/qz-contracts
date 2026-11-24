// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title QZTestMarket (TESTNET ONLY)
/// @notice Fixed-price marketplace for QuoteZero machines on the Robinhood Chain testnet (46630), priced in test $QZ.
///         It is never deployed to, and refuses to be created on, Robinhood Chain mainnet (4663). No other contract
///         references it and it has no owner, no fee, no royalty and no admin power.
///
///         Non-custodial: a machine stays in its owner's wallet while listed. The owner approves this contract
///         (`setApprovalForAll` or `approve`) and calls `list`; `buy` moves the test $QZ from the buyer to the seller and
///         the machine from the seller to the buyer in one transaction. A listing whose seller no longer owns the
///         machine, or withdrew the approval, cannot be bought and anyone may `prune` it.
///
///         One buy per wallet per `BUY_COOLDOWN` (24 h), enforced here on chain. A price is at most `maxPrice`, which the
///         deploy sets to no more than the amount the forge locks to light a machine.
contract QZTestMarket {
    using SafeERC20 for IERC20;

    uint256 internal constant MAINNET_CHAIN_ID = 4663;
    /// @notice Seconds a wallet waits between two purchases.
    uint256 public constant BUY_COOLDOWN = 1 days;

    IERC721 public immutable machine;
    /// @notice The test $QZ every price is quoted in.
    IERC20 public immutable token;
    /// @notice The highest price a listing may ask, in test $QZ base units.
    uint256 public immutable maxPrice;

    struct Listing {
        address seller;
        uint256 price; // 0 = not listed
        uint256 index; // position in `_ids`
    }

    mapping(uint256 => Listing) private _listings;
    uint256[] private _ids;
    mapping(address => uint256) private _lastBuyAt;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Delisted(uint256 indexed tokenId, address indexed seller);
    event Bought(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price);

    error WrongChain();
    error ZeroAddress();
    error NotOwner();
    /// @notice The market is not approved to move this machine.
    error Unapproved();
    error NotListed();
    error BadPrice(uint256 price);
    error SelfBuy();
    error LengthMismatch();
    /// @param nextBuyAt when the buyer may buy again (unix seconds)
    error Cooldown(uint256 nextBuyAt);
    /// @notice `prune` on a listing that is still valid.
    error ListingValid();

    constructor(IERC721 machine_, IERC20 token_, uint256 maxPrice_) {
        if (block.chainid == MAINNET_CHAIN_ID) revert WrongChain();
        if (address(machine_) == address(0) || address(token_) == address(0) || maxPrice_ == 0) revert ZeroAddress();
        machine = machine_;
        token = token_;
        maxPrice = maxPrice_;
    }

    // ───────────── sell side ─────────────

    /// @notice List `tokenId` at `price` test $QZ (or change the price of your listing). Caller owns the machine and
    ///         has approved this contract.
    function list(uint256 tokenId, uint256 price) public {
        if (machine.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (price == 0 || price > maxPrice) revert BadPrice(price);
        if (!_approved(msg.sender, tokenId)) revert Unapproved();
        Listing storage l = _listings[tokenId];
        if (l.price == 0) {
            l.index = _ids.length;
            _ids.push(tokenId);
        }
        l.seller = msg.sender;
        l.price = price;
        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice `list` for several machines in one transaction.
    function listMany(uint256[] calldata tokenIds, uint256[] calldata prices) external {
        if (tokenIds.length != prices.length) revert LengthMismatch();
        for (uint256 i; i < tokenIds.length; ++i) {
            list(tokenIds[i], prices[i]);
        }
    }

    /// @notice Remove a listing. The seller or the machine's current owner may.
    function delist(uint256 tokenId) external {
        Listing memory l = _listings[tokenId];
        if (l.price == 0) revert NotListed();
        if (msg.sender != l.seller && machine.ownerOf(tokenId) != msg.sender) revert NotOwner();
        _remove(tokenId, l);
        emit Delisted(tokenId, l.seller);
    }

    /// @notice Anyone: remove a listing whose seller no longer owns the machine or withdrew the approval.
    function prune(uint256 tokenId) external {
        Listing memory l = _listings[tokenId];
        if (l.price == 0) revert NotListed();
        if (_valid(tokenId, l.seller)) revert ListingValid();
        _remove(tokenId, l);
        emit Delisted(tokenId, l.seller);
    }

    // ───────────── buy side ─────────────

    /// @notice Buy a listed machine. The buyer approved this contract for at least the price in test $QZ. One buy per
    ///         wallet per `BUY_COOLDOWN`.
    function buy(uint256 tokenId) external {
        Listing memory l = _listings[tokenId];
        if (l.price == 0 || !_valid(tokenId, l.seller)) revert NotListed();
        if (l.seller == msg.sender) revert SelfBuy();
        uint256 nextAt = nextBuyAt(msg.sender);
        if (nextAt != 0) revert Cooldown(nextAt);
        _lastBuyAt[msg.sender] = block.timestamp;
        _remove(tokenId, l);
        token.safeTransferFrom(msg.sender, l.seller, l.price);
        machine.transferFrom(l.seller, msg.sender, tokenId);
        emit Bought(tokenId, msg.sender, l.seller, l.price);
    }

    // ───────────── views ─────────────

    /// @notice 0 when `who` can buy now, else the unix time the cooldown ends.
    function nextBuyAt(address who) public view returns (uint256) {
        uint256 last = _lastBuyAt[who];
        if (last == 0) return 0;
        uint256 end = last + BUY_COOLDOWN;
        return block.timestamp < end ? end : 0;
    }

    /// @notice The listing of `tokenId`; `price` 0 means not listed. A listing can be stale: see `isBuyable`.
    function listingOf(uint256 tokenId) external view returns (address seller, uint256 price) {
        Listing memory l = _listings[tokenId];
        return (l.seller, l.price);
    }

    /// @notice True when `buy(tokenId)` would pass the listing checks (listed, seller still owns and approves).
    function isBuyable(uint256 tokenId) external view returns (bool) {
        Listing memory l = _listings[tokenId];
        return l.price != 0 && _valid(tokenId, l.seller);
    }

    function listingCount() external view returns (uint256) {
        return _ids.length;
    }

    /// @notice Listings `offset` .. `offset + limit - 1` in listing order (swap-remove: order changes after a removal).
    function listingsPage(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory tokenIds, uint256[] memory prices, address[] memory sellers)
    {
        uint256 total = _ids.length;
        uint256 n = offset >= total ? 0 : (limit > total - offset ? total - offset : limit);
        tokenIds = new uint256[](n);
        prices = new uint256[](n);
        sellers = new address[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = _ids[offset + i];
            Listing memory l = _listings[id];
            tokenIds[i] = id;
            prices[i] = l.price;
            sellers[i] = l.seller;
        }
    }

    // ───────────── internals ─────────────

    function _approved(address owner_, uint256 tokenId) internal view returns (bool) {
        return machine.isApprovedForAll(owner_, address(this)) || machine.getApproved(tokenId) == address(this);
    }

    function _valid(uint256 tokenId, address seller) internal view returns (bool) {
        return machine.ownerOf(tokenId) == seller && _approved(seller, tokenId);
    }

    function _remove(uint256 tokenId, Listing memory l) internal {
        uint256 last = _ids[_ids.length - 1];
        _ids[l.index] = last;
        _listings[last].index = l.index;
        _ids.pop();
        delete _listings[tokenId];
    }
}
