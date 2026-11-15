// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IQZErrors} from "./IQZCommon.sol";

/// @title IQZMachine
/// @notice Lit machine: plain ERC-721, ids 1..4444, minted only by `QZCore.hardwire`, never burned (§5.1, I3).
///         Separate from the ticket mirror so machine approvals never meet fungible-side logic (§4.1).
///         ERC-2981 royalty 5% (4% reward pot + 1% treasury, §1.4), best effort. Traits are fixed by `TRAITS_HASH`.
///         Events: ERC-721 `Transfer`, `Approval`, `ApprovalForAll`.
interface IQZMachine is IERC721Metadata, IERC2981, IQZErrors {
    event MetadataFrozen();

    error MachineAlreadyMinted(uint256 machineId);
    error MachineIdOutOfRange(uint256 machineId);
    error MetadataAlreadyFrozen();
    error NonexistentMachine(uint256 machineId);

    /// @notice `QZCore` only. Mints `machineId` (1..4444) once in the contract's lifetime (I3).
    function mint(address to, uint256 machineId) external;

    /// @notice `tier` 1..4 = I Ticker .. IV Zero Desk, `track` 0..9, `relic` true for #4441..#4444 (tier 0, track 0).
    ///         Defined for every id 1..4444, also before the machine is minted.
    function traitsOf(uint256 machineId) external view returns (uint8 tier, uint8 track, bool relic);
    function totalMinted() external view returns (uint256);
    /// @notice keccak256 of metadata/traits.json (unit A0), constructor argument.
    function TRAITS_HASH() external view returns (bytes32);

    function core() external view returns (address);
    /// @notice `QZCore` only (forwarded owner calls).
    function setBaseURI(string calldata baseURI) external;
    function freezeMetadata() external;
    function metadataFrozen() external view returns (bool);
}
