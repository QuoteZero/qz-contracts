// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibString} from "solady/utils/LibString.sol";

import {IQZEntropy} from "../interfaces/IQZEntropy.sol";
import {IQZMachine} from "../interfaces/IQZMachine.sol";
import {QZConstants} from "../lib/QZConstants.sol";
import {MintPhase} from "../lib/QZTypes.sol";
import {QZTraitsTable} from "./QZTraitsTable.sol";

/// @title QZMachine
/// @notice The machine NFT (SPEC Model B, B.4): plain ERC-721, ids 1..2222, sold for USDG in three phases.
///
///         - Mint. GTD (24 h, GTD proof, `priceGtd`), FCFS (12 h, FCFS proof, `priceFcfs`), public (up to 24 h, no
///           proof, `pricePublic`). The three prices are immutable constructor arguments. One mint per wallet across
///           phases; a listed wallet that mints in the public window pays the public price. The payer approves USDG
///           and `mint` pulls the price straight from the payer to the two recipients in the same transaction (25%
///           converter, 75% treasury), so the contract never holds USDG. A USDG transfer that reverts (paused token,
///           blocklisted payer or recipient) or does not move the exact amount reverts the whole mint.
///         - Supply. Ids are handed out 1, 2, 3, ... in mint order. `finalizeMint` (anyone, once the mint sold out or
///           the public window ended) closes the supply at the minted count. Nothing mints afterwards, nothing burns.
///         - Reveal. `finalizeMint` (block `F`) records the entropy position `i` and `F`. In blocks `F + 2` to `F + 257`
///           anyone calls `lockHash`, which stores `blockhash(F + 1)` once: that hash does not exist while the finalize
///           transaction is built, and once locked nobody can redraw it. `reveal` (anyone) then needs only the entropy
///           link `i + 1` and sets one rotation `offset = keccak256(seedOf(i + 1), lockedHash) mod 2222`. If the link
///           is not published within `REVEAL_TIMEOUT` of the lock, anyone reveals with `seed = 0`. A window nobody
///           locked in can be re-armed (`rearmReveal`, never after a lock). The token `t` carries trait slot
///           `((t - 1 + offset) mod 2222) + 1` of the fixed table committed by `TRAITS_HASH`. The rotation is
///           stored per contract, never per token, so a transfer moves the traits with the token.
///         - Pause. The pauser stops `mint` only. A pause freezes the mint clock: every window boundary still ahead
///           moves by the paused time, so a pause never shortens a phase.
///         - Royalty 0. No admin transfer. The owner (one EOA) configures the schedule and roots once, sets the base
///           URI until `freezeMetadata`, and the pauser can pause the mint only (finalize and reveal never stop).
contract QZMachine is ERC721, ReentrancyGuardTransient, IQZMachine {
    /// @dev Blocks after a block for which `blockhash` still answers.
    uint256 private constant BLOCKHASH_WINDOW = 256;

    /// @notice Seconds after the hash lock after which `reveal` works without the entropy link (seed 0).
    uint64 public constant REVEAL_TIMEOUT = 7 days;
    /// @dev Bounds of each window length given to the constructor.
    uint64 private constant MIN_WINDOW = 1 minutes;
    uint64 private constant MAX_WINDOW = 7 days;

    // ───────────── immutables ─────────────

    address public immutable override owner;
    address public immutable override pauser;
    address public immutable override usdg;
    address public immutable override converter;
    address public immutable override treasury;
    address public immutable override entropy;
    bytes32 public immutable override TRAITS_HASH;
    uint256 public immutable override priceGtd;
    uint256 public immutable override priceFcfs;
    uint256 public immutable override pricePublic;

    /// @notice The three window lengths, in seconds, given to the constructor.
    struct MintWindows {
        uint64 gtd;
        uint64 fcfs;
        uint64 publicMax;
    }

    uint64 public immutable override gtdWindow;
    uint64 public immutable override fcfsWindow;
    uint64 public immutable override publicWindowMax;

    // ───────────── state ─────────────

    bytes32 public override gtdRoot;
    bytes32 public override fcfsRoot;
    uint64 public override mintStart;
    uint64 public override gtdEnd;
    uint64 public override fcfsEnd;
    uint64 public override publicEnd;

    bool public override paused;
    bool public override mintFinalized;
    bool public override revealed;
    bool public override hashLocked;
    bool public override metadataFrozen;

    uint256 private _mintedCount;
    mapping(address wallet => bool) private _hasMinted;

    uint64 private _entropyIndex;
    /// @dev Block of `finalizeMint`, or of the last `rearmReveal`; the reveal reads `blockhash(_finalizeBlock + 1)`.
    uint256 private _finalizeBlock;
    bytes32 private _lockedHash;
    uint64 private _lockedAt;
    uint64 private _pausedAt;
    uint256 private _offset;
    string private baseURI_;

    /// @param owner_ configures the mint once, sets the base URI, freezes metadata.
    /// @param pauser_ can pause and unpause the mint.
    /// @param usdg_ payment token (6 decimals).
    /// @param converter_ receives 25% of every mint; the deployer pre-computes its address (it is deployed later).
    /// @param treasury_ receives 75% of every mint.
    /// @param entropy_ `QZEntropy`.
    /// @param traitsHash_ keccak256 of `metadata/traits.json`.
    /// @param priceGtd_ USDG (6 decimals) paid with a GTD proof in the GTD window.
    /// @param priceFcfs_ USDG paid with an FCFS proof in the FCFS window.
    /// @param pricePublic_ USDG paid in the public window by anyone, listed or not.
    /// @param windows_ lengths in seconds of the GTD, FCFS and public windows (production: 24 h, 12 h, 24 h, the
    ///        `QZConstants` values); each from 1 minute to 7 days.
    constructor(
        address owner_,
        address pauser_,
        address usdg_,
        address converter_,
        address treasury_,
        address entropy_,
        bytes32 traitsHash_,
        uint256 priceGtd_,
        uint256 priceFcfs_,
        uint256 pricePublic_,
        MintWindows memory windows_
    ) ERC721("QuoteZero Machine", "QZM") {
        if (
            owner_ == address(0) || pauser_ == address(0) || usdg_ == address(0) || converter_ == address(0)
                || treasury_ == address(0) || entropy_ == address(0)
        ) revert ZeroAddress();
        if (priceGtd_ == 0 || priceFcfs_ == 0 || pricePublic_ == 0) revert ZeroAmount();
        if (!_windowInBounds(windows_.gtd) || !_windowInBounds(windows_.fcfs) || !_windowInBounds(windows_.publicMax)) {
            revert BadSchedule();
        }
        owner = owner_;
        pauser = pauser_;
        usdg = usdg_;
        converter = converter_;
        treasury = treasury_;
        entropy = entropy_;
        TRAITS_HASH = traitsHash_;
        priceGtd = priceGtd_;
        priceFcfs = priceFcfs_;
        pricePublic = pricePublic_;
        gtdWindow = windows_.gtd;
        fcfsWindow = windows_.fcfs;
        publicWindowMax = windows_.publicMax;
    }

    function _windowInBounds(uint64 w) private pure returns (bool) {
        return w >= MIN_WINDOW && w <= MAX_WINDOW;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyPauser() {
        if (msg.sender != pauser) revert NotPauser(msg.sender);
        _;
    }

    // ───────────── pause ─────────────

    function pause() external override onlyPauser {
        if (paused) revert EnforcedPause();
        paused = true;
        _pausedAt = uint64(block.timestamp);
        emit Paused(msg.sender);
    }

    function unpause() external override onlyPauser {
        if (!paused) revert ExpectedPause();
        paused = false;
        _extendWindows();
        emit Unpaused(msg.sender);
    }

    /// @dev The mint clock stopped at `max(pausedAt, mintStart)`. Every boundary still ahead of that point moves by the
    ///      time since then, so the pause costs no phase any time.
    function _extendWindows() private {
        if (mintStart == 0) return;
        uint64 s = _pausedAt > mintStart ? _pausedAt : mintStart;
        if (block.timestamp <= s) return;
        uint64 d = uint64(block.timestamp) - s;
        if (gtdEnd > s) gtdEnd += d;
        if (fcfsEnd > s) fcfsEnd += d;
        if (publicEnd > s) publicEnd += d;
        emit MintWindowExtended(d, publicEnd);
    }

    /// @dev Time the schedule is measured in: real time, or the freeze point while paused.
    function _mintClock() private view returns (uint256) {
        if (!paused) return block.timestamp;
        uint256 s = _pausedAt > mintStart ? _pausedAt : mintStart;
        return s < block.timestamp ? s : block.timestamp;
    }

    // ───────────── mint ─────────────

    /// @inheritdoc IQZMachine
    function configureMint(bytes32 gtdRoot_, bytes32 fcfsRoot_, uint64 mintStart_) external override onlyOwner {
        if (mintStart != 0) revert AlreadyConfigured();
        if (gtdRoot_ == bytes32(0) || fcfsRoot_ == bytes32(0) || mintStart_ < block.timestamp) revert BadSchedule();
        uint64 gtdEnd_ = mintStart_ + gtdWindow;
        uint64 fcfsEnd_ = gtdEnd_ + fcfsWindow;
        uint64 publicEnd_ = fcfsEnd_ + publicWindowMax;
        gtdRoot = gtdRoot_;
        fcfsRoot = fcfsRoot_;
        mintStart = mintStart_;
        gtdEnd = gtdEnd_;
        fcfsEnd = fcfsEnd_;
        publicEnd = publicEnd_;
        emit MintConfigured(gtdRoot_, fcfsRoot_, mintStart_, gtdEnd_, fcfsEnd_, publicEnd_);
    }

    /// @inheritdoc IQZMachine
    function mint(bytes32[] calldata proof) external override nonReentrant returns (uint256 machineId) {
        if (paused) revert EnforcedPause();
        (MintPhase p, uint256 price) = _quote(msg.sender, proof);

        _hasMinted[msg.sender] = true;
        machineId = ++_mintedCount;
        // forge-lint: disable-next-line(unsafe-oz-erc721-mint)
        _mint(msg.sender, machineId);

        uint256 toConverter = price * QZConstants.MINT_REWARD_BPS / QZConstants.BPS;
        uint256 toTreasury = price - toConverter;
        _pay(converter, toConverter);
        _pay(treasury, toTreasury);
        emit Minted(msg.sender, machineId, p, price, toConverter, toTreasury);
    }

    /// @inheritdoc IQZMachine
    function priceOf(address wallet, bytes32[] calldata proof) external view override returns (uint256 price) {
        (, price) = _quote(wallet, proof);
    }

    /// @inheritdoc IQZMachine
    function finalizeMint() external override {
        if (mintFinalized) revert AlreadyFinalized();
        if (mintStart == 0) revert NotConfigured();
        if (_mintedCount < QZConstants.TOTAL_MACHINES && _mintClock() < publicEnd) revert CannotFinalizeYet();
        mintFinalized = true;
        uint64 index = IQZEntropy(entropy).revealedIndex();
        _entropyIndex = index;
        _finalizeBlock = block.number;
        // The block hash is read at reveal, from the block after this one, so the event carries none.
        emit MintFinalized(_mintedCount, index, bytes32(0));
    }

    /// @dev Phase and price of `wallet` now. Reverts exactly where `mint` would, except for the pause.
    function _quote(address wallet, bytes32[] calldata proof) private view returns (MintPhase p, uint256 price) {
        p = phase();
        if (p == MintPhase.Closed) {
            if (_mintedCount >= QZConstants.TOTAL_MACHINES) revert SoldOut();
            revert MintNotOpen(p);
        }
        if (p == MintPhase.Pending) {
            if (mintStart == 0) revert NotConfigured();
            revert MintNotOpen(p);
        }
        if (_hasMinted[wallet]) revert AlreadyMinted(wallet);
        if (p == MintPhase.Gtd) {
            if (!_listed(gtdRoot, wallet, proof)) revert NotEligible(wallet);
            return (p, priceGtd);
        }
        if (p == MintPhase.Fcfs) {
            if (!_listed(fcfsRoot, wallet, proof)) revert NotEligible(wallet);
            return (p, priceFcfs);
        }
        return (p, pricePublic);
    }

    /// @dev Leaf of `OpenZeppelin StandardMerkleTree` with leaf type `["address"]`.
    function _listed(bytes32 root, address wallet, bytes32[] calldata proof) private pure returns (bool) {
        return MerkleProof.verifyCalldata(proof, root, keccak256(bytes.concat(keccak256(abi.encode(wallet)))));
    }

    /// @dev Pull `amount` USDG from the payer to `to`; the recipient balance must grow by exactly `amount`.
    function _pay(address to, uint256 amount) private {
        IERC20 token = IERC20(usdg);
        uint256 before = token.balanceOf(to);
        try token.transferFrom(msg.sender, to, amount) returns (bool ok) {
            if (!ok) revert PaymentFailed();
        } catch {
            revert PaymentFailed();
        }
        if (token.balanceOf(to) - before != amount) revert PaymentFailed();
    }

    // ───────────── reveal ─────────────

    /// @inheritdoc IQZMachine
    /// @dev Callable in blocks `F + 2 ..= F + 257` (`F` = `finalizeMint` block or last re-arm): `blockhash(F + 1)` is
    ///      unknown before block `F + 1` exists and readable for 256 blocks after it. The hash is stored once; after
    ///      that nothing can change it.
    function lockHash() external override {
        if (!mintFinalized) revert NotFinalized();
        if (hashLocked) revert HashAlreadyLocked();
        uint256 f = _finalizeBlock;
        if (block.number < f + 2) revert RevealTooEarly(f + 2);
        if (block.number > f + 1 + BLOCKHASH_WINDOW) revert RevealWindowMissed();
        bytes32 h = blockhash(f + 1);
        if (h == bytes32(0)) revert ZeroBlockHash();
        _lockedHash = h;
        _lockedAt = uint64(block.timestamp);
        hashLocked = true;
        emit HashLocked(h, _lockedAt);
    }

    /// @inheritdoc IQZMachine
    /// @dev Needs the locked hash and the link `i + 1`. Past `REVEAL_TIMEOUT` after the lock it works without the link,
    ///      with seed 0: the onion holder then picks between the two outcomes, never more.
    function reveal() external override {
        if (!mintFinalized) revert NotFinalized();
        if (revealed) revert AlreadyRevealed();
        if (!hashLocked) revert HashNotLocked();
        uint64 have = IQZEntropy(entropy).revealedIndex();
        uint64 need = _entropyIndex + 1;
        bytes32 seed;
        if (have >= need) {
            seed = IQZEntropy(entropy).seedOf(need);
        } else if (block.timestamp < uint256(_lockedAt) + REVEAL_TIMEOUT) {
            revert EntropyNotReady(have, need);
        }
        uint256 offset = uint256(keccak256(abi.encode(seed, _lockedHash))) % QZConstants.REVEAL_MODULUS;
        revealed = true;
        _offset = offset;
        emit Revealed(offset, seed);
    }

    /// @inheritdoc IQZMachine
    /// @dev Only when nobody locked a hash in the window (a draw then costs the silence of everyone able to call
    ///      `lockHash`), and never after a lock.
    function rearmReveal() external override {
        if (!mintFinalized) revert NotFinalized();
        if (hashLocked) revert HashAlreadyLocked();
        if (block.number <= _finalizeBlock + 1 + BLOCKHASH_WINDOW) revert RevealWindowOpen();
        _finalizeBlock = block.number;
        emit RevealRearmed(block.number);
    }

    // ───────────── metadata ─────────────

    /// @inheritdoc IQZMachine
    function setBaseURI(string calldata baseURI) external override onlyOwner {
        if (metadataFrozen) revert MetadataAlreadyFrozen();
        baseURI_ = baseURI;
        emit BaseURISet(baseURI);
    }

    /// @inheritdoc IQZMachine
    /// @dev Only after the reveal, so a placeholder base URI cannot be frozen in.
    function freezeMetadata() external override onlyOwner {
        if (metadataFrozen) revert MetadataAlreadyFrozen();
        if (!revealed) revert NotRevealed();
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    /// @dev `baseURI + id`; empty until the owner sets a base URI.
    function tokenURI(uint256 machineId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        if (_ownerOf(machineId) == address(0)) revert NonexistentMachine(machineId);
        string memory base = baseURI_;
        return bytes(base).length == 0 ? "" : string.concat(base, LibString.toString(machineId));
    }

    // ───────────── views ─────────────

    /// @inheritdoc IQZMachine
    function phase() public view override returns (MintPhase) {
        if (mintStart == 0) return MintPhase.Pending;
        if (mintFinalized || _mintedCount >= QZConstants.TOTAL_MACHINES) return MintPhase.Closed;
        uint256 t = _mintClock();
        if (t < mintStart) return MintPhase.Pending;
        if (t < gtdEnd) return MintPhase.Gtd;
        if (t < fcfsEnd) return MintPhase.Fcfs;
        if (t < publicEnd) return MintPhase.Public;
        return MintPhase.Closed;
    }

    /// @inheritdoc IQZMachine
    function mintedCount() external view override returns (uint256) {
        return _mintedCount;
    }

    /// @inheritdoc IQZMachine
    function totalSupply() external view override returns (uint256) {
        return _mintedCount;
    }

    /// @inheritdoc IQZMachine
    function maxSupply() external pure override returns (uint256) {
        return QZConstants.TOTAL_MACHINES;
    }

    /// @inheritdoc IQZMachine
    function hasMinted(address wallet) external view override returns (bool) {
        return _hasMinted[wallet];
    }

    /// @inheritdoc IQZMachine
    function finalizeBlock() external view override returns (uint256) {
        return _finalizeBlock;
    }

    /// @inheritdoc IQZMachine
    function lockedHash() external view override returns (bytes32) {
        return _lockedHash;
    }

    /// @inheritdoc IQZMachine
    function lockedAt() external view override returns (uint64) {
        return _lockedAt;
    }

    /// @inheritdoc IQZMachine
    function revealOffset() external view override returns (uint256) {
        if (!revealed) revert NotRevealed();
        return _offset;
    }

    /// @inheritdoc IQZMachine
    function traitIdOf(uint256 machineId) public view override returns (uint256) {
        if (!revealed) revert NotRevealed();
        if (machineId == 0 || machineId > _mintedCount) revert NonexistentMachine(machineId);
        return (machineId - 1 + _offset) % QZConstants.TOTAL_MACHINES + 1;
    }

    /// @inheritdoc IQZMachine
    function traitsOf(uint256 machineId) external view override returns (uint8 tier, uint8 track, bool relic) {
        uint256 traitId = traitIdOf(machineId);
        uint8 packed = uint8(QZTraitsTable.TABLE[traitId - 1]);
        return (packed >> 4, packed & 0x0f, traitId >= QZConstants.FIRST_RELIC_ID);
    }

    // ───────────── ERC-2981 (royalty 0) ─────────────

    function royaltyInfo(uint256, uint256) external pure override returns (address, uint256) {
        return (address(0), QZConstants.MACHINE_ROYALTY_BPS);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
