// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {MintPhase} from "../lib/QZTypes.sol";
import {IQZPausable} from "./IQZCommon.sol";

/// @title IQZMachine
/// @notice The machine NFT: plain ERC-721, 2,222 ids, sold for USDG in three phases (SPEC Model B, B.4).
///
///         Mint. GTD (24 h, GTD Merkle proof, `priceGtd`), FCFS (12 h, FCFS Merkle proof, `priceFcfs`), public (until
///         sold out, at most 24 h, no proof, `pricePublic`). One mint per wallet across all phases. A wallet on a
///         list that mints in the public window pays the public price. The payer approves USDG, `mint` pulls the
///         price and splits it in the same transaction: 25% to the converter (first reward pot), 75% to the
///         treasury. Token ids are handed out 1, 2, 3, ... in mint order.
///
///         Reveal. `finalizeMint` (anyone, once the mint is sold out or the public window ended; block `F`) closes the
///         supply and records the entropy position. In blocks `F + 2` to `F + 257` anyone calls `lockHash`, which stores
///         `blockhash(F + 1)` once; a window nobody used can be re-armed with `rearmReveal`, never after a lock.
///         `reveal` (anyone, once the hash is locked and the entropy contract revealed the next link) derives one
///         random rotation `offset = keccak256(seed, lockedHash) mod 2222` and sets
///         `traitId = ((tokenId - 1 + offset) mod 2222) + 1`. Seven days after the lock the link is no longer needed
///         (seed 0). Nobody, the owner included, picks which token gets which trait. Traits come from the fixed
///         table committed by `TRAITS_HASH`.
///
///         Royalty is 0%. There is no admin transfer, no burn and no mint after `finalizeMint`. The owner configures
///         the schedule once, sets the base URI until metadata is frozen, and can pause the mint.
///
///         `machineId` in the other contracts is this contract's token id.
interface IQZMachine is IERC721Metadata, IERC2981, IQZPausable {
    // ───────────── events ─────────────

    /// @notice The mint schedule and both Merkle roots were set (once).
    event MintConfigured(
        bytes32 gtdRoot, bytes32 fcfsRoot, uint64 gtdStart, uint64 gtdEnd, uint64 fcfsEnd, uint64 publicEnd
    );
    /// @param phase the phase the buyer minted in
    /// @param price USDG paid (6 decimals), the price of `phase`
    /// @param toConverter 25% of `price`, to the converter
    /// @param toTreasury 75% of `price`, to the treasury
    event Minted(
        address indexed to,
        uint256 indexed machineId,
        MintPhase phase,
        uint256 price,
        uint256 toConverter,
        uint256 toTreasury
    );
    /// @param supply final supply, `mintedCount()`
    /// @param entropyIndex `IQZEntropy.revealedIndex()` at finalization; the seed of the next link is the reveal seed
    /// @param blockHash always 0: the reveal hash is stored by `lockHash` (see `HashLocked`), not at finalization
    event MintFinalized(uint256 supply, uint64 entropyIndex, bytes32 blockHash);
    /// @param offset the rotation, 0..2221
    /// @param seed `IQZEntropy.seedOf(entropyIndex + 1)`, or 0 when revealed by timeout after `lockHash`
    event Revealed(uint256 offset, bytes32 seed);
    event BaseURISet(string baseURI);
    event MetadataFrozen();
    /// @notice `blockhash(finalizeBlock + 1)` stored for the reveal; `at` is the block timestamp.
    event HashLocked(bytes32 hash, uint64 at);
    /// @notice Nobody locked a hash in the window; `finalizeBlock` is the new reference block.
    event RevealRearmed(uint256 finalizeBlock);
    /// @notice A pause moved the window boundaries still ahead by `by` seconds; `publicEnd` is the new public end.
    event MintWindowExtended(uint64 by, uint64 publicEnd);

    // ───────────── errors ─────────────

    error AlreadyConfigured();
    error NotConfigured();
    /// @notice `mintStart` is in the past, a root is zero, or a window length given to the constructor is outside 1 minute to 7 days.
    error BadSchedule();
    error MintNotOpen(MintPhase phase);
    /// @notice The wallet is not on the list of the current phase (GTD or FCFS) and the phase has no public access.
    error NotEligible(address wallet);
    error AlreadyMinted(address wallet);
    error SoldOut();
    error AlreadyFinalized();
    /// @notice `finalizeMint` before the mint sold out and before the public window ended.
    error CannotFinalizeYet();
    error NotFinalized();
    error AlreadyRevealed();
    error NotRevealed();
    /// @notice The entropy contract has not revealed a link after finalization yet.
    error EntropyNotReady(uint64 have, uint64 need);
    /// @notice `lockHash` before `blockhash(finalizeBlock + 1)` is readable; `readyBlock` is the first block it works.
    error RevealTooEarly(uint256 readyBlock);
    /// @notice The block hash of `finalizeBlock + 1` is no longer readable; call `rearmReveal`.
    error RevealWindowMissed();
    /// @notice `rearmReveal` while `lockHash` still works.
    error RevealWindowOpen();
    error HashAlreadyLocked();
    /// @notice `reveal` before `lockHash`.
    error HashNotLocked();
    /// @notice `blockhash(finalizeBlock + 1)` returned zero.
    error ZeroBlockHash();
    error MetadataAlreadyFrozen();
    error NonexistentMachine(uint256 machineId);
    /// @notice The USDG transfer failed or the recipient balances did not move by the exact split.
    error PaymentFailed();

    // ───────────── mint ─────────────

    /// @notice Owner, once. Sets both Merkle roots (leaf = `keccak256(bytes.concat(keccak256(abi.encode(wallet))))`)
    ///         and the schedule: GTD opens at `mintStart`, then 24 h GTD, 12 h FCFS, up to 24 h public.
    function configureMint(bytes32 gtdRoot, bytes32 fcfsRoot, uint64 mintStart) external;

    /// @notice Buy one machine for the price of the current phase. `proof` is checked against the GTD root in the GTD
    ///         window and against the FCFS root in the FCFS window, and ignored in the public window. Needs a USDG
    ///         approval of at least `priceOf(msg.sender, proof)`. Reverts when paused. Returns the new token id.
    function mint(bytes32[] calldata proof) external returns (uint256 machineId);

    /// @notice The USDG price `wallet` pays right now with `proof`. Reverts with `MintNotOpen`, `NotEligible` or
    ///         `AlreadyMinted` exactly where `mint` would.
    function priceOf(address wallet, bytes32[] calldata proof) external view returns (uint256 price);

    /// @notice Anyone, once. Closes the mint after sold out or after the public window; records the entropy position.
    function finalizeMint() external;

    // ───────────── reveal ─────────────

    /// @notice Keeper call. Anyone, once, in blocks `finalizeBlock + 2 ..= finalizeBlock + 257`: stores
    ///         `blockhash(finalizeBlock + 1)` (non-zero) for the reveal.
    function lockHash() external;

    /// @notice Keeper call. Anyone, only when the window passed without a lock (never after one): records the current
    ///         block as the new `finalizeBlock`, so `lockHash` works again from two blocks later.
    function rearmReveal() external;

    /// @notice Anyone, once, after `lockHash` and after the entropy contract revealed a link past the recorded one; after
    ///         `REVEAL_TIMEOUT` (7 days) from the lock the link is not needed (seed 0).
    function reveal() external;

    // ───────────── metadata (owner) ─────────────

    function setBaseURI(string calldata baseURI) external;
    /// @notice Owner, once. After this the base URI never changes.
    function freezeMetadata() external;

    // ───────────── views ─────────────

    /// @notice Current phase, derived from the schedule, the clock and the counters.
    function phase() external view returns (MintPhase);
    /// @notice Machines minted so far. Equals `totalSupply()`; nothing burns.
    function mintedCount() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    /// @notice 2,222.
    function maxSupply() external view returns (uint256);
    function hasMinted(address wallet) external view returns (bool);
    function mintFinalized() external view returns (bool);
    function revealed() external view returns (bool);
    function hashLocked() external view returns (bool);
    /// @notice Block of `finalizeMint`, or of the last `rearmReveal`.
    function finalizeBlock() external view returns (uint256);
    function lockedHash() external view returns (bytes32);
    /// @notice Timestamp of `lockHash`; 0 before.
    function lockedAt() external view returns (uint64);
    /// @notice The rotation 0..2221; reverts with `NotRevealed` before `reveal`.
    function revealOffset() external view returns (uint256);
    /// @notice The slot of the trait table `tokenId` carries, 1..2222; reverts with `NotRevealed` before `reveal`.
    function traitIdOf(uint256 machineId) external view returns (uint256);
    /// @notice Tier, track and relic flag of a minted token; reverts with `NotRevealed` before `reveal`.
    function traitsOf(uint256 machineId) external view returns (uint8 tier, uint8 track, bool relic);
    /// @notice keccak256 of the traits file the table was generated from.
    function TRAITS_HASH() external view returns (bytes32);
    function metadataFrozen() external view returns (bool);

    function owner() external view returns (address);
    function usdg() external view returns (address);
    /// @notice Receives 25% of every mint.
    function converter() external view returns (address);
    /// @notice Receives 75% of every mint.
    function treasury() external view returns (address);
    function entropy() external view returns (address);
    function priceGtd() external view returns (uint256);
    function priceFcfs() external view returns (uint256);
    function pricePublic() external view returns (uint256);
    /// @notice Window lengths in seconds, fixed at deployment (production: 24 h, 12 h, 24 h).
    function gtdWindow() external view returns (uint64);
    function fcfsWindow() external view returns (uint64);
    function publicWindowMax() external view returns (uint64);
    function gtdRoot() external view returns (bytes32);
    function fcfsRoot() external view returns (bytes32);
    /// @notice Schedule, all zero until `configureMint`.
    function mintStart() external view returns (uint64);
    function gtdEnd() external view returns (uint64);
    function fcfsEnd() external view returns (uint64);
    function publicEnd() external view returns (uint64);
}
