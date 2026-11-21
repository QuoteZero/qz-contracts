// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QZFeeSplitter} from "../../src/fee/QZFeeSplitter.sol";
import {FeeFixture} from "./QZFeeSplitter.t.sol";

import {MOCK_PonsCurve, MOCK_QZTestToken} from "../../script/testnet/MockPons.sol";

/// @dev Treasury stand-in that the fuzzer can switch between accepting and rejecting ETH.
contract ToggleSink {
    bool public rejecting;

    function setRejecting(bool v) external {
        rejecting = v;
    }

    receive() external payable {
        require(!rejecting, "rejecting");
    }
}

/// @dev Random buys, sells, operator sweeps, direct donations, escrow credits, treasury accept/reject flips, pulls and
///      harvests against the splitter.
contract FeeHandler is Test {
    QZFeeSplitter internal immutable S;
    FeeFixture internal immutable F;

    uint256 public ghostDonated; // ETH sent to the splitter by hand (plain send)
    uint256 public harvests;
    uint256 public ghostPaid; // sum of everything harvest() returned
    bool public ratioBroken;
    bool public dustLeft;
    bool public bookkeepingBroken;
    bool public handlerCallReverted;
    uint256 public buys;
    uint256 public tradeAttempts;
    uint256 public sells;
    uint256 public sweeps;
    /// @dev Where the treasury pulls its parked share to.
    address public constant DEST = address(0xDE57);

    constructor(FeeFixture f, QZFeeSplitter s) {
        F = f;
        S = s;
    }

    /// @dev The trading helpers read the fixture's getters into locals first: a `vm.prank` is consumed by the next
    ///      external call, and that call must be the one under test. A revert of any of them is a bug of the handler,
    ///      not a legal outcome, so it is recorded instead of being swallowed by `fail-on-revert = false`.
    function buy(uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        address tr = F.trader();
        MOCK_PonsCurve c = F.curve();
        tradeAttempts++;
        vm.deal(tr, amount);
        vm.prank(tr);
        try c.buy{value: amount}(amount, 0, tr) {
            buys++;
        } catch {
            handlerCallReverted = true;
        }
    }

    function sell(uint256 bps) external {
        address tr = F.trader();
        MOCK_PonsCurve c = F.curve();
        MOCK_QZTestToken t = F.token();
        uint256 amount = t.balanceOf(tr) * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        tradeAttempts++;
        vm.startPrank(tr);
        t.approve(address(c), amount);
        try c.sell(amount, 0, tr) {
            sells++;
        } catch {
            handlerCallReverted = true;
        }
        vm.stopPrank();
    }

    function operatorSweep() external {
        address op = F.operator();
        MOCK_PonsCurve c = F.curve();
        if (c.quoteFeeBalance() == 0 && c.creatorTaxBalance() == 0) return;
        tradeAttempts++;
        vm.prank(op);
        try c.sweepFees(0) {
            sweeps++;
        } catch {
            handlerCallReverted = true;
        }
    }

    function donateDirect(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(S).call{value: amount}("");
        require(ok);
        ghostDonated += amount;
    }

    /// @dev Counted by the escrow's own `totalCredited`, not by `ghostDonated`.
    function donateViaEscrow(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), amount);
        F.escrow().credit{value: amount}(address(S));
    }

    /// @dev The treasury is a `ToggleSink`; the fuzzer flips it between accepting and rejecting ETH, so harvests go
    ///      through both the push and the park-and-pull paths.
    function toggleTreasury(bool rejecting) external {
        ToggleSink(payable(F.treasury())).setRejecting(rejecting);
    }

    function claimPending() external {
        address tre = F.treasury();
        if (S.pendingTreasury() == 0) return;
        vm.prank(tre);
        try S.claimPendingTreasury(DEST) {}
        catch {
            handlerCallReverted = true;
        }
    }

    function harvest(uint256 callerSeed) external {
        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));
        uint256 convBefore = F.converter().balance;
        uint256 treBefore = F.treasury().balance + DEST.balance + S.pendingTreasury();
        uint256 pendingBefore = F.escrow().balanceOf(address(S)) + address(S).balance - S.pendingTreasury();
        uint256 pendingCurve = _curvePendingCreator();

        vm.prank(caller);
        try S.harvest() returns (uint256 c, uint256 t) {
            uint256 total = c + t;
            harvests++;
            ghostPaid += total;
            if (c != total * 20 / 27 || t != total - total * 20 / 27) ratioBroken = true;
            if (
                F.converter().balance - convBefore != c
                    || F.treasury().balance + DEST.balance + S.pendingTreasury() - treBefore != t
            ) {
                bookkeepingBroken = true;
            }
            // nothing is left behind except the parked treasury share
            if (address(S).balance != S.pendingTreasury() || F.escrow().balanceOf(address(S)) != 0) dustLeft = true;
            // total = what was pending in the escrow/contract + the curve's creator share that the harvest swept
            if (total != pendingBefore + pendingCurve) bookkeepingBroken = true;
        } catch {
            // only legal when nothing is claimable
            if (pendingBefore + pendingCurve != 0) bookkeepingBroken = true;
        }
    }

    /// @dev Creator share the curve would credit on a sweep now (70% of the base fee + 100% of the tax).
    function _curvePendingCreator() private view returns (uint256) {
        uint256 fee = F.curve().quoteFeeBalance();
        uint256 tax = F.curve().creatorTaxBalance();
        return fee - fee * 3000 / 10_000 + tax;
    }
}

contract QZFeeSplitterInvariantTest is FeeFixture {
    FeeHandler internal handler;

    function setUp() public {
        _deploy();
        treasury = address(new ToggleSink());
        _bind();
        handler = new FeeHandler(this, splitter);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = FeeHandler.buy.selector;
        sel[1] = FeeHandler.sell.selector;
        sel[2] = FeeHandler.operatorSweep.selector;
        sel[3] = FeeHandler.donateDirect.selector;
        sel[4] = FeeHandler.donateViaEscrow.selector;
        sel[5] = FeeHandler.harvest.selector;
        sel[6] = FeeHandler.harvest.selector;
        sel[7] = FeeHandler.toggleTreasury.selector;
        sel[8] = FeeHandler.claimPending.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// Everything Pons ever credited to the splitter (plus plain sends) is either paid out, or still waiting in the
    /// escrow or in the splitter's balance. Nothing is created or lost.
    /// forge-config: default.invariant.runs = 10000
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_conservation() public view {
        uint256 credited = escrow.totalCredited(address(splitter)) + handler.ghostDonated();
        uint256 accounted = splitter.totalToConverter() + splitter.totalToTreasury() + address(splitter).balance
            + escrow.balanceOf(address(splitter));
        assertEq(accounted, credited, "conservation");
    }

    /// forge-config: default.invariant.runs = 10000
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_paidOutEqualsHarvested() public view {
        assertEq(
            splitter.totalToConverter() + splitter.totalToTreasury() + splitter.pendingTreasury(),
            handler.ghostPaid(),
            "ledger"
        );
        assertEq(converter.balance, splitter.totalToConverter(), "converter received exactly the ledger");
        assertEq(
            treasury.balance + handler.DEST().balance,
            splitter.totalToTreasury(),
            "treasury received exactly the ledger"
        );
        // the only ETH the splitter holds is the parked treasury share plus plain sends not yet harvested
        assertGe(address(splitter).balance, splitter.pendingTreasury(), "parked share is backed by ETH");
    }

    /// forge-config: default.invariant.runs = 10000
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_everyHarvestIsExact20to7WithNoDust() public view {
        assertFalse(handler.ratioBroken(), "20:7 split rounded down for the reward, remainder to treasury");
        assertFalse(handler.dustLeft(), "no dust");
        assertFalse(handler.bookkeepingBroken(), "harvest total == escrow + balance + curve creator share");
    }

    /// Per harvest c = floor(20T/27) and t = T - c, so 7c <= 20t <= 7c + 26; summed over n harvests.
    /// forge-config: default.invariant.runs = 10000
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_ratioDriftBounded() public view {
        uint256 c = splitter.totalToConverter();
        uint256 t = splitter.totalToTreasury() + splitter.pendingTreasury();
        uint256 n = handler.harvests();
        assertGe(t * 20, c * 7, "treasury not short");
        assertLe(t * 20, c * 7 + 26 * n, "treasury not over");
    }

    /// The trading and sweep calls of the handler are never allowed to revert (a revert would silently turn the
    /// campaign into one that exercises nothing).
    /// forge-config: default.invariant.runs = 10000
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_handlerTradesNeverRevert() public view {
        assertFalse(handler.handlerCallReverted(), "a buy, sell or operator sweep reverted");
    }

    /// Every buy, sell and fee sweep the handler attempted in this run went through (none was silently swallowed).
    /// A run is free to draw no trade at all; that every attempted trade succeeds, and that the handler really does
    /// trade, is pinned by `test_handlerTradesAreReal`.
    function afterInvariant() public view {
        assertEq(handler.buys() + handler.sells() + handler.sweeps(), handler.tradeAttempts(), "a trade was swallowed");
    }

    /// The handler's trading functions succeed when called directly (a consumed prank once made every one of them
    /// revert unseen), and they move real fees into Pons and, through `harvest`, into the splitter's recipients.
    function test_handlerTradesAreReal() public {
        handler.buy(5 ether);
        handler.buy(1 ether);
        handler.sell(5000);
        handler.operatorSweep();
        assertEq(handler.buys(), 2, "buys");
        assertEq(handler.sells(), 1, "sells");
        assertEq(handler.sweeps(), 1, "sweeps");
        assertFalse(handler.handlerCallReverted());
        assertGt(token.balanceOf(trader), 0, "trader holds tokens");
        assertGt(escrow.totalCredited(address(splitter)), 0, "operator sweep credited the escrow");
        handler.harvest(1);
        assertEq(handler.harvests(), 1, "harvest");
        assertGt(converter.balance, 0);
        assertGt(treasury.balance, 0);
    }
}
