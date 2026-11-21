// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {QZConstants} from "../../src/lib/QZConstants.sol";
import {StockRoute} from "../../src/lib/QZTypes.sol";
import {QZEntropy} from "../../src/random/QZEntropy.sol";
import {QZMachine} from "../../src/machine/QZMachine.sol";
import {QZForge} from "../../src/light/QZForge.sol";
import {QZFeeSplitter} from "../../src/fee/QZFeeSplitter.sol";
import {QZConverter} from "../../src/reward/QZConverter.sol";
import {QZRewardVault} from "../../src/reward/QZRewardVault.sol";
import {
    MOCK_PonsFactory,
    MOCK_PonsFeeEscrow,
    MOCK_PonsCurve,
    MOCK_PonsHook,
    MOCK_QZTestToken
} from "../../script/testnet/MockPons.sol";
import {MockERC20, MockWETH, MockStock, MockV3, MockPoolManager} from "../reward/mocks/RewardMocks.sol";
import {QZMerkle} from "../machine/QZMerkle.sol";
import {QZOnion} from "../random/QZOnion.sol";

/// @notice The treasury of the world: takes USDG like any wallet and ETH unless the handler tells it to refuse.
///         With the refusal switched on `QZFeeSplitter.harvest` has to revert as a whole.
contract QZSystemTreasury {
    bool public rejectEth;

    receive() external payable {
        require(!rejectEth, "treasury refuses ETH");
    }

    function setReject(bool v) external {
        rejectEth = v;
    }
}

/// @title QZSystemWorld
/// @notice The whole Model B system as the testnet deploy builds it, in one constructor: the real `QZMachine`,
///         `QZEntropy`, `QZForge`, `QZRewardVault`, `QZConverter` and `QZFeeSplitter`, the Pons mock
///         (`MOCK_PonsFactory`, curve, escrow, hook, QZ token), a mock USDG, a WETH9 stand-in, ten mock stocks, the v3 mock
///         and the constant-liquidity v4 `PoolManager` mock with ten initialised USDG/stock pools. Circular constructor
///         arguments (machine -> converter -> vault -> forge -> vault, splitter <-> Pons) are solved with predicted
///         CREATE addresses, in the order the deployment uses.
///
///         The v4 `PoolManager` is the repo's constant-liquidity stand-in (`test/reward/mocks/RewardMocks.sol`): the real
///         one needs the uninitialised nested `solmate` submodule. Both token orders of the USDG/stock pools are covered
///         (stocks alternate below and above USDG), as in `ConverterFixture`.
contract QZSystemWorld is Test {
    uint64 public constant START = 1_800_000_000;
    uint64 public constant LIGHTING_OPENS_AT = START + 61 hours;
    uint256 public constant ONION_LENGTH = 1_100;
    bytes32 public constant ONION_SEED = keccak256("qz system onion");
    bytes32 public constant TRAITS_HASH = 0xb9fe99db267885cafeffec71666b542c89d40c25017f7e008b21b296e7abd41e;
    int24 public constant WETH_USDG_TICK = -200_000;
    int24 public constant STOCK_TICK = 223_320;
    uint128 public constant LIQUIDITY = 2e16;

    uint256 public constant GTD_ACTORS = 6;
    uint256 public constant FCFS_ACTORS = 6;
    uint256 public constant PUBLIC_ACTORS = 8;

    // roles
    address public owner = makeAddr("owner");
    address public pauser = makeAddr("pauser");
    address public keeper = makeAddr("keeper");
    address public executor = makeAddr("executor");
    address public revealer = address(0xBEEF);
    address public protocolRecipient = makeAddr("protocol");
    address public sweepOperator = makeAddr("operator");
    address public attacker = makeAddr("attacker");

    // tokens and venues
    MockERC20 public usdg;
    MockWETH public weth;
    MockStock[10] public stocks;
    MockV3 public v3;
    MockPoolManager public pm;
    QZSystemTreasury public treasury;

    // Pons
    MOCK_PonsFactory public pons;
    MOCK_PonsFeeEscrow public escrow;
    MOCK_PonsCurve public curve;
    MOCK_PonsHook public hook;
    MOCK_QZTestToken public qz;

    // the system
    QZEntropy public entropy;
    QZMachine public machine;
    QZForge public forge;
    QZRewardVault public vault;
    QZConverter public conv;
    QZFeeSplitter public splitter;

    bytes32[] public chain;

    // wallets
    address[] internal _actors;
    mapping(address => bool) public isGtd;
    mapping(address => bool) public isFcfs;
    mapping(address => bytes32[]) internal _gtdProof;
    mapping(address => bytes32[]) internal _fcfsProof;

    constructor() {
        vm.warp(START - 1 days);
        chain = QZOnion.build(ONION_SEED, ONION_LENGTH);
        _deployTokensAndVenues();
        _deployPons();
        _deploySystem();
        _wire();
        _makeActors();
    }

    // ───────────── deployment ─────────────

    function _deployTokensAndVenues() private {
        pm = new MockPoolManager();
        // WETH below USDG (token0 of the v3 pool is WETH); stocks alternate below and above USDG
        address usdgAddr = address(uint160(0x8000000000000000000000000000000000000001));
        deployCodeTo("RewardMocks.sol:MockERC20", abi.encode("USDG", "USDG", uint8(6)), usdgAddr);
        usdg = MockERC20(usdgAddr);
        weth = MockWETH(address(uint160(0x4000000000000000000000000000000000000001)));
        deployCodeTo("RewardMocks.sol:MockWETH", address(weth));
        for (uint256 i; i < 10; ++i) {
            address a =
                i % 2 == 0 ? address(uint160((uint256(1) << 156) + i)) : address(uint160((uint256(15) << 156) + i));
            deployCodeTo("RewardMocks.sol:MockStock", a);
            stocks[i] = MockStock(a);
        }
        v3 = new MockV3(MockERC20(address(weth)), usdg, WETH_USDG_TICK);
        treasury = new QZSystemTreasury();
    }

    /// @dev The Pons mock names the splitter as its creator-fee recipient, so the splitter address is predicted.
    function _deployPons() private {
        entropy = new QZEntropy(revealer, chain[0]);
        address predictedSplitter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        pons = new MOCK_PonsFactory(predictedSplitter, protocolRecipient, sweepOperator);
        escrow = pons.escrow();
        curve = pons.curve();
        hook = pons.hook();
        qz = pons.token();
        splitter = new QZFeeSplitter(owner, address(escrow), address(pons), address(qz), address(hook));
        require(address(splitter) == predictedSplitter, "splitter address prediction");
    }

    /// @dev Creation order: machine (n), forge (n+1), vault (n+2), converter (n+3).
    function _deploySystem() private {
        uint256 n = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), n + 2);
        address predictedConverter = vm.computeCreateAddress(address(this), n + 3);
        machine = new QZMachine(
            owner,
            pauser,
            address(usdg),
            predictedConverter,
            address(treasury),
            address(entropy),
            TRAITS_HASH,
            QZConstants.PRICE_GTD,
            QZConstants.PRICE_FCFS,
            QZConstants.PRICE_PUBLIC,
            QZMachine.MintWindows({
                gtd: QZConstants.GTD_WINDOW, fcfs: QZConstants.FCFS_WINDOW, publicMax: QZConstants.PUBLIC_WINDOW_MAX
            })
        );
        forge = new QZForge(address(qz), address(machine), predictedVault, owner, pauser, LIGHTING_OPENS_AT);
        vault = new QZRewardVault(address(forge), address(machine), predictedConverter);
        conv = new QZConverter(
            QZConverter.Config({
                owner: owner,
                pauser: pauser,
                keeper: keeper,
                executor: executor,
                weth: address(weth),
                usdg: address(usdg),
                v3Factory: address(v3),
                v3Router: address(v3),
                poolManager: address(pm),
                vault: address(vault),
                lightingOpensAt: LIGHTING_OPENS_AT
            })
        );
        require(address(vault) == predictedVault && address(conv) == predictedConverter, "address prediction");
    }

    function _wire() private {
        vm.prank(owner);
        splitter.bind(address(conv), address(treasury));

        for (uint8 t; t < 10; ++t) {
            pm.initialize(poolKey(t), TickMath.getSqrtPriceAtTick(usdgIs0(t) ? STOCK_TICK : -STOCK_TICK), LIQUIDITY);
            usdg.mint(address(pm), 1e15);
            stocks[t].mint(address(pm), 1e27);
        }
        vm.startPrank(owner);
        for (uint8 t; t < 10; ++t) {
            conv.setRoute(t, route(t));
        }
        conv.sealRoutes();
        vm.stopPrank();
    }

    function _makeActors() private {
        address[] memory gtdList = new address[](GTD_ACTORS + 1);
        address[] memory fcfsList = new address[](FCFS_ACTORS + 1);
        for (uint256 i; i < GTD_ACTORS; ++i) {
            address a = makeAddr(string.concat("gtd", vm.toString(i)));
            gtdList[i] = a;
            isGtd[a] = true;
            _actors.push(a);
        }
        for (uint256 i; i < FCFS_ACTORS; ++i) {
            address a = makeAddr(string.concat("fcfs", vm.toString(i)));
            fcfsList[i] = a;
            isFcfs[a] = true;
            _actors.push(a);
        }
        address both = makeAddr("both");
        gtdList[GTD_ACTORS] = both;
        fcfsList[FCFS_ACTORS] = both;
        isGtd[both] = true;
        isFcfs[both] = true;
        _actors.push(both);
        for (uint256 i; i < PUBLIC_ACTORS; ++i) {
            _actors.push(makeAddr(string.concat("pub", vm.toString(i))));
        }

        bytes32[] memory gtdTree = QZMerkle.buildTree(gtdList);
        bytes32[] memory fcfsTree = QZMerkle.buildTree(fcfsList);
        for (uint256 i; i < gtdList.length; ++i) {
            _gtdProof[gtdList[i]] = QZMerkle.proofOf(gtdTree, gtdList[i]);
        }
        for (uint256 i; i < fcfsList.length; ++i) {
            _fcfsProof[fcfsList[i]] = QZMerkle.proofOf(fcfsTree, fcfsList[i]);
        }
        vm.prank(owner);
        machine.configureMint(gtdTree[0], fcfsTree[0], START);
    }

    // ───────────── views the handler and the invariants use ─────────────

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function gtdProofOf(address a) external view returns (bytes32[] memory) {
        return _gtdProof[a];
    }

    function fcfsProofOf(address a) external view returns (bytes32[] memory) {
        return _fcfsProof[a];
    }

    function route(uint8 t) public view returns (StockRoute memory r) {
        r = StockRoute({
            stock: address(stocks[t]),
            hooks: address(0),
            poolFee: 3000,
            tickSpacing: 60,
            v3Fee: 100,
            maxChunk: uint128(QZConstants.DEFAULT_MAX_CHUNK),
            fallbackDailyCap: uint128(QZConstants.DEFAULT_FALLBACK_DAILY_CAP)
        });
    }

    function usdgIs0(uint8 t) public view returns (bool) {
        return address(usdg) < address(stocks[t]);
    }

    function poolKey(uint8 t) public view returns (PoolKey memory) {
        bool u0 = usdgIs0(t);
        return PoolKey({
            currency0: Currency.wrap(u0 ? address(usdg) : address(stocks[t])),
            currency1: Currency.wrap(u0 ? address(stocks[t]) : address(usdg)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}
