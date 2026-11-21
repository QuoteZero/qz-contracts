// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {QZEntropy} from "../../src/random/QZEntropy.sol";
import {QZMachine} from "../../src/machine/QZMachine.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {QZOnion} from "../random/QZOnion.sol";
import {MockUSDG} from "./MockUSDG.sol";
import {QZMerkle} from "./QZMerkle.sol";

/// @notice The real `QZMachine` and `QZEntropy` with a mock USDG, a GTD list, an FCFS list and a configured mint
///         that opens at `START`. Prices are the ones of B.4 (3, 4 and 5 USDG).
abstract contract MachineFixture is Test {
    uint256 internal constant GTD_PRICE = QZConstants.PRICE_GTD;
    uint256 internal constant FCFS_PRICE = QZConstants.PRICE_FCFS;
    uint256 internal constant PUBLIC_PRICE = QZConstants.PRICE_PUBLIC;
    uint256 internal constant MAX = QZConstants.TOTAL_MACHINES;
    uint256 internal constant ONION_LENGTH = 1_100;
    uint64 internal constant START = 1_800_000_000;
    bytes32 internal constant TRAITS_HASH = 0xb9fe99db267885cafeffec71666b542c89d40c25017f7e008b21b296e7abd41e;
    bytes32 internal constant ONION_SEED = keccak256("qz machine onion");
    address internal constant REVEALER = address(0xBEEF);

    MockUSDG internal usdg;
    QZEntropy internal entropy;
    QZMachine internal machine;
    bytes32[] internal chain;

    address internal owner = makeAddr("owner");
    address internal pauser = makeAddr("pauser");
    address internal converter = makeAddr("converter");
    address internal treasury = makeAddr("treasury");

    address[] internal gtdList;
    address[] internal fcfsList;
    bytes32[] internal gtdTree;
    bytes32[] internal fcfsTree;
    bytes32 internal gtdRoot;
    bytes32 internal fcfsRoot;

    /// @dev Four GTD wallets (`gtd0..gtd3`) and four FCFS wallets (`fcfs0..fcfs3`); `nobody` is on neither list and
    ///      `both` is on both lists.
    address internal gtd0 = makeAddr("gtd0");
    address internal gtd1 = makeAddr("gtd1");
    address internal gtd2 = makeAddr("gtd2");
    address internal gtd3 = makeAddr("gtd3");
    address internal fcfs0 = makeAddr("fcfs0");
    address internal fcfs1 = makeAddr("fcfs1");
    address internal fcfs2 = makeAddr("fcfs2");
    address internal fcfs3 = makeAddr("fcfs3");
    address internal both = makeAddr("both");
    address internal nobody = makeAddr("nobody");

    function setUp() public virtual {
        chain = QZOnion.build(ONION_SEED, ONION_LENGTH);
        vm.warp(START - 1 days);

        usdg = new MockUSDG();
        entropy = new QZEntropy(REVEALER, chain[0]);
        machine = new QZMachine(
            owner,
            pauser,
            address(usdg),
            converter,
            treasury,
            address(entropy),
            TRAITS_HASH,
            GTD_PRICE,
            FCFS_PRICE,
            PUBLIC_PRICE,
            QZMachine.MintWindows(_gtdWindow(), _fcfsWindow(), _publicWindow())
        );

        gtdList = [gtd0, gtd1, gtd2, gtd3, both];
        fcfsList = [fcfs0, fcfs1, fcfs2, fcfs3, both];
        gtdTree = QZMerkle.buildTree(gtdList);
        fcfsTree = QZMerkle.buildTree(fcfsList);
        gtdRoot = gtdTree[0];
        fcfsRoot = fcfsTree[0];

        vm.prank(owner);
        machine.configureMint(gtdRoot, fcfsRoot, START);
    }

    /// @dev A machine on the fixture's token, recipients and entropy, with the given prices and windows.
    function _deploy(address o, address p, uint256 pg, uint256 pf, uint256 pp, uint64 gw, uint64 fw, uint64 pw)
        internal
        returns (QZMachine)
    {
        return new QZMachine(
            o,
            p,
            address(usdg),
            converter,
            treasury,
            address(entropy),
            TRAITS_HASH,
            pg,
            pf,
            pp,
            QZMachine.MintWindows(gw, fw, pw)
        );
    }

    // ───────────── time ─────────────

    /// @dev Window lengths the fixture deploys with: the production defaults. A subclass overrides them to run the same
    ///      suite on a short schedule.
    function _gtdWindow() internal view virtual returns (uint64) {
        return QZConstants.GTD_WINDOW;
    }

    function _fcfsWindow() internal view virtual returns (uint64) {
        return QZConstants.FCFS_WINDOW;
    }

    function _publicWindow() internal view virtual returns (uint64) {
        return QZConstants.PUBLIC_WINDOW_MAX;
    }

    function _warpGtd() internal {
        vm.warp(START);
    }

    function _warpFcfs() internal {
        vm.warp(START + _gtdWindow());
    }

    function _warpPublic() internal {
        vm.warp(START + _gtdWindow() + _fcfsWindow());
    }

    function _warpAfterPublic() internal {
        vm.warp(START + _gtdWindow() + _fcfsWindow() + _publicWindow());
    }

    // ───────────── proofs ─────────────

    function _gtdProof(address a) internal view returns (bytes32[] memory) {
        return QZMerkle.proofOf(gtdTree, a);
    }

    function _fcfsProof(address a) internal view returns (bytes32[] memory) {
        return QZMerkle.proofOf(fcfsTree, a);
    }

    function _noProof() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](0);
    }

    // ───────────── buying ─────────────

    /// @dev Fund `who` with `amount` USDG and approve exactly `amount`.
    function _fund(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(machine), amount);
    }

    function _mintAs(address who, uint256 pay, bytes32[] memory proof) internal returns (uint256 id) {
        _fund(who, pay);
        vm.prank(who);
        id = machine.mint(proof);
    }

    /// @dev Sell `count` machines in the public window to fresh wallets `address(0xA0000 + i)`.
    function _sellPublic(uint256 first, uint256 count) internal {
        _warpPublic();
        bytes32[] memory none = _noProof();
        for (uint256 i; i < count; ++i) {
            _mintAs(address(uint160(0xA0000 + first + i)), PUBLIC_PRICE, none);
        }
    }

    // ───────────── reveal ─────────────

    /// @dev Finalize at block `F`, move to block `F + 2` where `blockhash(F + 1)` is `blockHash`, and lock it.
    function _finalizeWith(bytes32 blockHash) internal {
        machine.finalizeMint();
        uint256 f = vm.getBlockNumber();
        vm.roll(f + 2);
        vm.setBlockhash(f + 1, blockHash);
        machine.lockHash();
    }

    function _revealLink(uint64 index) internal {
        vm.prank(REVEALER);
        entropy.reveal(index, chain[index]);
    }

    /// @dev The rotation the spec formula gives for the link `index` and a block hash.
    function _expectedOffset(uint64 index, bytes32 blockHash) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(QZOnion.seedOf(chain[index], index), blockHash))) % MAX;
    }
}
