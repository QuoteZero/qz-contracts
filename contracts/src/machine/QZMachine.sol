// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {LibString} from "solady/utils/LibString.sol";

import {IQZErrors} from "../interfaces/IQZCommon.sol";
import {IQZMachine} from "../interfaces/IQZMachine.sol";
import {QZConstants} from "../lib/QZConstants.sol";
import {QZTraitsTable} from "./QZTraitsTable.sol";

/// @title QZMachine
/// @notice The lit machine: plain ERC-721, ids 1..2222, minted only by `QZCore.hardwire` (SPEC §1.2, §1.3, §5.1).
///
///         - Separate from the ticket mirror, so a machine approval never meets the fungible-side logic (§4.1).
///         - `mint` is `QZCore`-only and each id can be minted once in the contract's lifetime (I3). Nothing burns:
///           there is no burn function and OpenZeppelin refuses transfers to `address(0)`, so `totalMinted()` equals
///           `QZCore.totalHardwired()` and an id never comes back. A bridged machine is locked in the adapter, not burned.
///         - Traits are a fixed table (`QZTraitsTable`, one byte per id) generated from `metadata/traits.json`, whose
///           keccak256 is `TRAITS_HASH`. They are defined for every id, minted or not.
///         - The base URI is set by the owner through `QZCore` until `freezeMetadata`, once.
///         - ERC-2981: 5% of the sale price to `royaltyReceiver` (4% reward pot + 1% treasury, §1.4). The receiver is
///           deployed as `QZRoyaltySplitter` (80% WETH to the converter, 20% to the treasury), never a bare treasury.
///           Marketplaces enforce it on a best-effort basis only.
///         - No owner, no pause and no admin transfer: the only privileged caller is `QZCore`. The mint is not a
///           safe-mint (no receiver callback) so a hardwire cannot be re-entered from the holder.
contract QZMachine is ERC721, IQZMachine {
    address public immutable override core;
    bytes32 public immutable override TRAITS_HASH;
    address public immutable royaltyReceiver;

    uint256 public override totalMinted;
    bool public override metadataFrozen;
    string private baseURI_;

    /// @param core_ `QZCore`; the deployer pre-computes its address from its nonce (C9).
    /// @param traitsHash_ keccak256 of `metadata/traits.json` (unit A0).
    /// @param royaltyReceiver_ ERC-2981 receiver of the 5% royalty.
    constructor(address core_, bytes32 traitsHash_, address royaltyReceiver_) ERC721("QuoteZero Machine", "QZM") {
        if (core_ == address(0) || royaltyReceiver_ == address(0)) revert ZeroAddress();
        core = core_;
        TRAITS_HASH = traitsHash_;
        royaltyReceiver = royaltyReceiver_;
    }

    modifier onlyCore() {
        if (msg.sender != core) revert NotCore(msg.sender);
        _;
    }

    // ───────────── mint (QZCore only) ─────────────

    /// @inheritdoc IQZMachine
    function mint(address to, uint256 machineId) external override onlyCore {
        if (machineId < QZConstants.FIRST_MACHINE_ID || machineId > QZConstants.TOTAL_MACHINES) {
            revert MachineIdOutOfRange(machineId);
        }
        if (_ownerOf(machineId) != address(0)) revert MachineAlreadyMinted(machineId);
        unchecked {
            ++totalMinted;
        }
        // forge-lint: disable-next-line(unsafe-oz-erc721-mint)
        _mint(to, machineId);
    }

    // ───────────── traits ─────────────

    /// @inheritdoc IQZMachine
    function traitsOf(uint256 machineId) external pure override returns (uint8 tier, uint8 track, bool relic) {
        if (machineId < QZConstants.FIRST_MACHINE_ID || machineId > QZConstants.TOTAL_MACHINES) {
            revert MachineIdOutOfRange(machineId);
        }
        uint8 packed = uint8(QZTraitsTable.TABLE[machineId - 1]);
        return (packed >> 4, packed & 0x0f, machineId >= QZConstants.FIRST_RELIC_ID);
    }

    // ───────────── metadata ─────────────

    /// @inheritdoc IQZMachine
    function setBaseURI(string calldata baseURI) external override onlyCore {
        if (metadataFrozen) revert MetadataAlreadyFrozen();
        baseURI_ = baseURI;
    }

    /// @inheritdoc IQZMachine
    function freezeMetadata() external override onlyCore {
        if (metadataFrozen) revert MetadataAlreadyFrozen();
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    /// @dev `baseURI + id`; empty until the owner sets a base URI.
    function tokenURI(uint256 machineId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        if (_ownerOf(machineId) == address(0)) revert NonexistentMachine(machineId);
        string memory base = baseURI_;
        return bytes(base).length == 0 ? "" : string.concat(base, LibString.toString(machineId));
    }

    // ───────────── ERC-2981 ─────────────

    function royaltyInfo(uint256, uint256 salePrice) external view override returns (address, uint256) {
        return (royaltyReceiver, salePrice * QZConstants.ROYALTY_BPS / QZConstants.BPS);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
