// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RobinhoodFork} from "../utils/RobinhoodFork.sol";
import {QZConverter} from "../../src/reward/QZConverter.sol";
import {IQZConverter} from "../../src/interfaces/IQZConverter.sol";
import {QZRewardVault} from "../../src/reward/QZRewardVault.sol";
import {QZRoutes} from "../../src/reward/QZRoutes.sol";
import {QZAddresses} from "../../src/lib/QZAddresses.sol";
import {StockRoute} from "../../src/lib/QZTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMachine} from "./mocks/RewardMocks.sol";

interface IStockMeta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IBeacon {
    function implementation() external view returns (address);
}

interface IRouterFactory {
    function factory() external view returns (address);
}

contract ForkPot {
    address internal immutable weth;
    uint64 public launchAt;
    uint256 public rewardPot;

    constructor(address weth_) {
        weth = weth_;
    }

    function setLaunchAt(uint64 t) external {
        launchAt = t;
    }

    function setPot(uint256 a) external {
        rewardPot = a;
    }

    function redirected() external pure returns (bool) {
        return false;
    }

    function pullRewardPot() external returns (uint256 a) {
        a = rewardPot;
        rewardPot = 0;
        IERC20(weth).transfer(msg.sender, a);
    }
}

/// @notice Fork test on the real Robinhood Chain: stock token evidence, and the real WETH -> USDG (v3) -> stock (v4)
///         route for all ten tracks, through the real `PoolManager`, with the median/TWAP floors live.
contract ConverterForkTest is RobinhoodFork {
    address internal constant BEACON_SLOT_OWNER = QZAddresses.STOCK_REGISTRY;
    bytes32 internal constant EIP1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    address internal owner = makeAddr("owner");
    address internal pauser = makeAddr("pauser");
    address internal keeper = makeAddr("keeper");
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");

    QZConverter internal conv;
    QZRewardVault internal vault;
    MockMachine internal machine;
    ForkPot internal hook;
    ForkPot internal curve;
    ForkPot internal circuit;

    string[10] internal symbols = ["NVDA", "AAPL", "TSLA", "GME", "SPY", "PLTR", "NFLX", "RDDT", "MSTR", "SPCX"];

    function setUp() public {
        _selectRobinhoodFork();
    }

    function test_fork_stockTokenEvidence() public view {
        for (uint8 t; t < 10; ++t) {
            address s = QZAddresses.stockOf(t);
            assertGt(s.code.length, 0, "stock has code");
            assertEq(IStockMeta(s).symbol(), symbols[t], "symbol");
            assertEq(IStockMeta(s).decimals(), 18, "decimals");
            address beacon = address(uint160(uint256(vm.load(s, EIP1967_BEACON_SLOT))));
            assertEq(beacon, BEACON_SLOT_OWNER, "all ten share one beacon");
            assertEq(IBeacon(beacon).implementation(), QZAddresses.STOCK_IMPLEMENTATION, "implementation pinned");
        }
        assertEq(IStockMeta(QZAddresses.USDG).decimals(), 6);
    }

    function _deploy() internal {
        vm.deal(alice, 1 ether);
        machine = new MockMachine();
        hook = new ForkPot(QZAddresses.WETH);
        curve = new ForkPot(QZAddresses.WETH);
        circuit = new ForkPot(QZAddresses.WETH);
        curve.setLaunchAt(uint64(block.timestamp - 25 hours));
        address v3Factory = IRouterFactory(QZAddresses.V3_SWAP_ROUTER_02).factory();
        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 1);
        vault = new QZRewardVault(address(this), address(machine), predicted);
        conv = new QZConverter(
            QZConverter.Config({
                owner: owner,
                pauser: pauser,
                keeper: keeper,
                executor: executor,
                weth: QZAddresses.WETH,
                usdg: QZAddresses.USDG,
                v3Factory: v3Factory,
                v3Router: QZAddresses.V3_SWAP_ROUTER_02,
                poolManager: QZAddresses.POOL_MANAGER,
                vault: address(vault),
                hook: address(hook),
                curve: address(curve),
                circuit: address(circuit)
            })
        );
        assertEq(address(conv), predicted);
        vm.startPrank(owner);
        for (uint8 t; t < 10; ++t) {
            conv.setRoute(t, QZRoutes.route(t));
        }
        conv.sealRoutes();
        vm.stopPrank();
    }

    /// One track per test: the public node is not an archive node and drops state a few seconds after the fork block,
    /// so each test forks the latest block and stays short. Floors (97% of the v3 TWAP and of the median v4 quote,
    /// `minOut = 1`) are live; the stock must land in the vault and be claimable.
    function _convertTrack(uint8 t) internal {
        _deploy();
        machine.set(100 + t, alice, 1, t, false);
        vault.onHardwire(100 + t);
        uint256 pot = 10 ether;
        // `deal` probes dozens of slots over RPC and outlives the public node's state window; WETH keeps balances at slot 51
        vm.store(QZAddresses.WETH, keccak256(abi.encode(address(hook), uint256(51))), bytes32(pot));
        assertEq(IERC20(QZAddresses.WETH).balanceOf(address(hook)), pot, "weth slot");
        hook.setPot(pot);

        for (uint256 i; i < 10; ++i) {
            vm.prank(keeper);
            conv.poke(t);
            vm.warp(block.timestamp + 2 minutes);
        }
        vm.prank(executor);
        conv.openEpoch();

        StockRoute memory r = QZRoutes.route(t);
        if (r.poolFee >= 30_000) {
            // MSTR: the 3% pool fee alone uses the whole 3% gross budget, so no chunk can clear the floor. The track
            // reverts BelowFloor and its pot stays in the converter.
            vm.prank(executor);
            try conv.convert(t, r.maxChunk, 1, 1, block.timestamp + 1) {
                fail();
            } catch (bytes memory err) {
                assertEq(bytes4(err), IQZConverter.BelowFloor.selector);
            }
            vm.prank(executor);
            try conv.convert(t, 1e12, 1, 1, block.timestamp + 1) {
                fail();
            } catch (bytes memory err) {
                assertEq(bytes4(err), IQZConverter.BelowFloor.selector);
            }
            assertEq(conv.trackPot(t), pot, "pot stays");
            return;
        }
        vm.prank(executor);
        conv.convert(t, r.maxChunk, 1, 1, block.timestamp + 1);
        uint256 got = vault.totalNotified(t);
        assertGt(got, 0, symbols[t]);
        assertEq(IERC20(r.stock).balanceOf(address(vault)), got);
        emit log_named_decimal_uint(
            string.concat(symbols[t], " stock out for maxChunk (", vm.toString(r.maxChunk / 1e15), " mWETH)"), got, 18
        );

        uint256[] memory ids = new uint256[](1);
        uint8[] memory tracks = new uint8[](1);
        ids[0] = 100 + t;
        tracks[0] = t;
        vm.prank(alice);
        vault.claim(ids, tracks);
        assertEq(IERC20(r.stock).balanceOf(alice), got, "claimed to the owner");
    }

    function test_fork_convert_NVDA() public {
        _convertTrack(0);
    }

    function test_fork_convert_AAPL() public {
        _convertTrack(1);
    }

    function test_fork_convert_TSLA() public {
        _convertTrack(2);
    }

    function test_fork_convert_GME() public {
        _convertTrack(3);
    }

    function test_fork_convert_SPY() public {
        _convertTrack(4);
    }

    function test_fork_convert_PLTR() public {
        _convertTrack(5);
    }

    function test_fork_convert_NFLX() public {
        _convertTrack(6);
    }

    function test_fork_convert_RDDT() public {
        _convertTrack(7);
    }

    function test_fork_convert_MSTR() public {
        _convertTrack(8);
    }

    function test_fork_convert_SPCX() public {
        _convertTrack(9);
    }
}
