// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {QZCloseBell} from "../../src/dapps/QZCloseBell.sol";
import {IQZPriceSource, PriceStatus} from "../../src/interfaces/IQZPriceSource.sol";
import {Direction, CallState, CloseStatus, Profile, SessionTimes} from "../../src/interfaces/IQZCloseBell.sol";
import {MockQZ} from "../light/mocks/LightMocks.sol";
import {MockUSDG} from "../machine/MockUSDG.sol";

/// @dev The part of QZMachine the Bell reads: `ownerOf` (ERC-721) and `traitsOf`. Transfers are the ERC-721 ones.
contract MockMachineLite is ERC721 {
    struct T {
        uint8 track;
        bool relic;
    }

    mapping(uint256 => T) public traits;

    constructor() ERC721("Machine", "QZM") {}

    function mint(address to, uint256 id, uint8 track, bool relic) external {
        _mint(to, id);
        traits[id] = T(track, relic);
    }

    function traitsOf(uint256 id) external view returns (uint8 tier, uint8 track, bool relic) {
        _requireOwned(id);
        T memory t = traits[id];
        return (t.relic ? 0 : 1, t.track, t.relic);
    }
}

/// @dev The part of QZForge the Bell reads.
contract MockForgeLite {
    mapping(uint256 => bool) public isLit;

    function setLit(uint256 id, bool v) external {
        isLit[id] = v;
    }
}

/// @dev A price source with scripted answers and hostile modes. `priceAt` is `view`, so the Bell's STATICCALL can
///      never let it write or re-enter.
contract ScriptedSource is IQZPriceSource {
    enum Mode {
        Normal,
        Revert,
        Garbage,
        Bomb,
        BigReturn,
        BadStatus,
        FutureObs,
        HugePrice,
        OkZero
    }

    struct Ans {
        uint128 price;
        PriceStatus status;
        bool set;
    }

    Mode public mode;
    uint16 public mask = 0x3FF & ~uint16(1 << 6) & ~uint16(1 << 7);
    mapping(uint8 => mapping(uint64 => Ans)) public answers;

    function setMode(Mode m) external {
        mode = m;
    }

    function setMask(uint16 m) external {
        mask = m;
    }

    function setAnswer(uint8 track, uint64 ts, uint128 price, PriceStatus status) external {
        answers[track][ts] = Ans(price, status, true);
    }

    function isSupported(uint8 track) external view returns (bool) {
        return track < 16 && (mask >> track) & 1 == 1;
    }

    function priceAt(uint8 track, uint64 ts, uint256)
        external
        view
        returns (uint256 price, uint64 observedAt, PriceStatus status)
    {
        Mode m = mode;
        if (m == Mode.Revert) revert("scripted revert");
        if (m == Mode.Garbage) {
            assembly {
                mstore(0, 1)
                return(0, 1)
            }
        }
        if (m == Mode.Bomb) {
            while (true) {}
        }
        if (m == Mode.BigReturn) {
            assembly {
                return(0, 1000000)
            }
        }
        if (m == Mode.BadStatus) {
            assembly {
                mstore(0, 1000000000000000000)
                mstore(32, ts)
                mstore(64, 9)
                return(0, 96)
            }
        }
        if (m == Mode.FutureObs) return (1e18, ts + 1, PriceStatus.Ok);
        if (m == Mode.HugePrice) return (type(uint256).max, ts, PriceStatus.Ok);
        if (m == Mode.OkZero) return (0, ts, PriceStatus.Ok);
        Ans memory a = answers[track][ts];
        if (!a.set) return (0, 0, PriceStatus.MarketClosed);
        return (a.price, a.status == PriceStatus.Ok ? ts : 0, a.status);
    }
}

/// @dev $QZ that calls back into the Bell during `transferFrom` (the ante pull) and during `transfer` (burn/refund).
contract ReentrantQZ is ERC20 {
    QZCloseBell public bell;
    bytes public data;
    bool public armed;
    bytes4 public lastRevert;
    bool public reentered;

    constructor() ERC20("QuoteZero", "QZ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(QZCloseBell bell_, bytes calldata data_) external {
        bell = bell_;
        data = data_;
        armed = true;
    }

    function _hook() private {
        if (!armed) return;
        armed = false;
        (bool ok, bytes memory ret) = address(bell).call(data);
        if (ok) reentered = true;
        else lastRevert = bytes4(ret);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _hook();
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _hook();
        return super.transfer(to, amount);
    }
}

/// @dev One season of `N` eight-minute sessions around `BASE`; machines and players of the Closing Bell tests.
abstract contract BellFixture is Test {
    uint64 internal constant BASE = 1_900_000_000;
    uint128 internal constant ANTE = 1000e18;
    uint16 internal constant S1 = 1;
    uint32 internal constant N = 4;
    uint64 internal constant VOID_AFTER = 20 minutes;
    uint64 internal constant CLAIM_DELAY = 20 minutes;
    uint64 internal constant MIN_LEAD = 2 minutes;
    uint64 internal constant SNAP_DELAY = 30;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockQZ internal qz;
    MockUSDG internal usdg;
    MockMachineLite internal machine;
    MockForgeLite internal forge;
    ScriptedSource internal src;
    QZCloseBell internal bell;

    address internal calendar = makeAddr("calendar");
    address internal treasury = makeAddr("treasury");
    address internal sponsor = makeAddr("sponsor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal rel = makeAddr("relicHolder");
    address internal dave = makeAddr("dave");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant A = 1; // alice, NVDA (0), lit
    uint256 internal constant B = 2; // bob, TSLA (2), lit
    uint256 internal constant C = 3; // carol, NVDA, NOT lit
    uint256 internal constant NF = 4; // NFLX (6), lit, not callable
    uint256 internal constant A2 = 5; // alice, NVDA, lit
    uint256 internal constant R = 2221; // relic, lit

    uint8 internal constant NVDA = 0;
    uint8 internal constant TSLA = 2;
    uint8 internal constant GME = 3;

    function setUp() public virtual {
        vm.warp(BASE);
        qz = new MockQZ();
        usdg = new MockUSDG();
        machine = new MockMachineLite();
        forge = new MockForgeLite();
        src = new ScriptedSource();
        bell = _newBell(address(qz), address(usdg));

        machine.mint(alice, A, NVDA, false);
        machine.mint(bob, B, TSLA, false);
        machine.mint(carol, C, NVDA, false);
        machine.mint(dave, NF, 6, false);
        machine.mint(alice, A2, NVDA, false);
        machine.mint(rel, R, 0, true);
        forge.setLit(A, true);
        forge.setLit(B, true);
        forge.setLit(NF, true);
        forge.setLit(A2, true);
        forge.setLit(R, true);

        address[5] memory players = [alice, bob, carol, rel, dave];
        for (uint256 i; i < players.length; ++i) {
            qz.mint(players[i], 1_000_000e18);
            vm.prank(players[i]);
            qz.approve(address(bell), type(uint256).max);
        }
        usdg.mint(treasury, 1_000_000e6);
        usdg.mint(sponsor, 1_000_000e6);
        vm.prank(treasury);
        usdg.approve(address(bell), type(uint256).max);
        vm.prank(sponsor);
        usdg.approve(address(bell), type(uint256).max);

        _createSeason(S1, 1, BASE - 1 hours, ANTE, BASE + 5 minutes, N);
    }

    function _profile() internal pure returns (Profile memory) {
        return Profile({voidAfter: VOID_AFTER, claimDelay: CLAIM_DELAY, minLead: MIN_LEAD, snapshotDelay: SNAP_DELAY});
    }

    function _newBell(address qz_, address usdg_) internal returns (QZCloseBell) {
        return new QZCloseBell(
            address(machine), address(forge), qz_, usdg_, address(src), calendar, treasury, sponsor, _profile()
        );
    }

    function _times(uint64 start, uint32 n) internal pure returns (SessionTimes[] memory t) {
        t = new SessionTimes[](n);
        for (uint32 i; i < n; ++i) {
            uint64 o = start + 8 minutes * i;
            t[i] = SessionTimes(o, o + 4 minutes, o + 6 minutes);
        }
    }

    function _createSeason(uint16 season, uint32 first, uint64 baseline, uint128 ante, uint64 start, uint32 n)
        internal
    {
        vm.prank(calendar);
        bell.createSeason(season, first, baseline, ante, _times(start, n));
    }

    // session k (1-based, season 1) times
    function opensOf(uint32 k) internal pure returns (uint64) {
        return BASE + 5 minutes + 8 minutes * (k - 1);
    }

    function cutoffOf(uint32 k) internal pure returns (uint64) {
        return opensOf(k) + 4 minutes;
    }

    function closeOf_(uint32 k) internal pure returns (uint64) {
        return opensOf(k) + 6 minutes;
    }

    function _toWindow(uint32 k) internal {
        vm.warp(opensOf(k) + 1);
    }

    function _toSnap(uint32 k) internal {
        vm.warp(closeOf_(k) + SNAP_DELAY);
    }

    function _callAs(address who, uint256 id, uint32 k, uint8 track, Direction dir) internal {
        vm.prank(who);
        bell.call(id, k, track, dir);
    }

    function _post(uint8 track, uint32 k, uint128 price) internal {
        src.setAnswer(track, closeOf_(k), price, PriceStatus.Ok);
    }

    function _baseline(uint8 track, uint128 price) internal {
        src.setAnswer(track, BASE - 1 hours, price, PriceStatus.Ok);
        bell.snapshotBaseline(S1, track, 0);
    }

    function _snap(uint8 track, uint32 k) internal {
        bell.snapshot(track, k, 0);
    }

    function _status(uint8 track, uint32 k) internal view returns (CloseStatus s) {
        (,,, s) = bell.closeOf(track, k);
    }

    function _state(uint256 id, uint32 k) internal view returns (CallState s) {
        (,,, s) = bell.callOf(id, k);
    }

    function _heat(uint256 id) internal view returns (uint32 streak, uint32 best, uint32 wins, uint32 losses) {
        (streak, best, wins, losses,) = bell.heatOf(id);
    }
}
