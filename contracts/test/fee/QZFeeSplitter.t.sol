// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {QZFeeSplitter} from "../../src/fee/QZFeeSplitter.sol";
import {IQZFeeSplitter} from "../../src/interfaces/IQZFeeSplitter.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {
    MOCK_PonsFactory,
    MOCK_PonsFeeEscrow,
    MOCK_PonsCurve,
    MOCK_PonsHook,
    MOCK_QZTestToken
} from "../../script/testnet/MockPons.sol";

/// @dev Shared fixture: the splitter wired to the Pons mock (the mock names the splitter as the creator-fee
///      recipient, so the splitter address is predicted from the deployer nonce).
abstract contract FeeFixture is Test {
    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public protocol = makeAddr("protocol");
    address public operator = makeAddr("operator");
    address public trader = makeAddr("trader");
    address public anyone = makeAddr("anyone");

    MOCK_PonsFactory public pons;
    MOCK_PonsFeeEscrow public escrow;
    MOCK_PonsCurve public curve;
    MOCK_PonsHook public hook;
    MOCK_QZTestToken public token;
    QZFeeSplitter public splitter;
    address public converter;

    function _deploy() internal {
        converter = address(new EthSink());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        pons = new MOCK_PonsFactory(predicted, protocol, operator);
        escrow = pons.escrow();
        curve = pons.curve();
        hook = pons.hook();
        token = pons.token();
        splitter = new QZFeeSplitter(owner, address(escrow), address(pons), address(token), address(hook));
        assertEq(address(splitter), predicted, "predicted splitter address");
    }

    function _bind() internal {
        vm.prank(owner);
        splitter.bind(converter, treasury);
    }

    function _buy(uint256 quoteIn) internal returns (uint256 out) {
        vm.deal(trader, quoteIn);
        vm.prank(trader);
        out = curve.buy{value: quoteIn}(quoteIn, 0, trader);
    }

    function _sell(uint256 tokensIn) internal returns (uint256 out) {
        vm.startPrank(trader);
        token.approve(address(curve), tokensIn);
        out = curve.sell(tokensIn, 0, trader);
        vm.stopPrank();
    }
}

contract EthSink {
    receive() external payable {}
}

contract QZFeeSplitterTest is FeeFixture {
    event Bound(address indexed converter, address indexed treasury);
    event Harvested(address indexed caller, uint256 total, uint256 toConverter, uint256 toTreasury);
    event SweepSkipped(bytes reason);

    function setUp() public {
        _deploy();
    }

    // ───────────── bind ─────────────

    function test_bind_onceByOwner() public {
        assertFalse(splitter.isBound());
        vm.expectEmit(true, true, false, true);
        emit Bound(converter, treasury);
        _bind();
        assertTrue(splitter.isBound());
        assertEq(splitter.converter(), converter);
        assertEq(splitter.treasury(), treasury);
        assertEq(splitter.owner(), owner);
        assertEq(splitter.REWARD_PART(), 20);
        assertEq(splitter.TREASURY_PART(), 7);
    }

    function test_bind_notOwnerReverts() public {
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotOwner.selector, anyone));
        splitter.bind(converter, treasury);
    }

    function test_bind_secondCallReverts() public {
        _bind();
        vm.prank(owner);
        vm.expectRevert(IQZFeeSplitter.AlreadyBound.selector);
        splitter.bind(makeAddr("c2"), makeAddr("t2"));
        assertEq(splitter.converter(), converter);
        assertEq(splitter.treasury(), treasury);
    }

    function test_bind_zeroAddressReverts() public {
        vm.startPrank(owner);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        splitter.bind(address(0), treasury);
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        splitter.bind(converter, address(0));
        vm.stopPrank();
        assertFalse(splitter.isBound());
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZFeeSplitter(address(0), address(escrow), address(pons), address(token), address(hook));
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZFeeSplitter(owner, address(0), address(pons), address(token), address(hook));
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZFeeSplitter(owner, address(escrow), address(0), address(token), address(hook));
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZFeeSplitter(owner, address(escrow), address(pons), address(0), address(hook));
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        new QZFeeSplitter(owner, address(escrow), address(pons), address(token), address(0));
    }

    // ───────────── harvest guards ─────────────

    function test_harvest_beforeBindReverts() public {
        _buy(10 ether);
        vm.expectRevert(IQZFeeSplitter.NotBound.selector);
        splitter.harvest();
    }

    function test_harvest_nothingToHarvestReverts() public {
        _bind();
        vm.expectRevert(IQZFeeSplitter.NothingToHarvest.selector);
        splitter.harvest();
    }

    function test_harvest_afterFullHarvestRevertsNothing() public {
        _bind();
        _buy(10 ether);
        splitter.harvest();
        vm.expectRevert(IQZFeeSplitter.NothingToHarvest.selector);
        splitter.harvest();
    }

    // ───────────── the split ─────────────

    function test_harvest_exactSplitAfterBuy() public {
        _bind();
        _buy(10 ether);
        // creator share = 70% of the 1% base fee + 100% of the 2% tax = 0.07 + 0.2 ETH
        uint256 expectedTotal = 0.27 ether;

        vm.expectEmit(true, false, false, true);
        emit Harvested(anyone, expectedTotal, 0.2 ether, 0.07 ether);
        vm.prank(anyone);
        (uint256 toConverter, uint256 toTreasury) = splitter.harvest();

        assertEq(toConverter, 0.2 ether, "reward 2.00%");
        assertEq(toTreasury, 0.07 ether, "treasury 0.70%");
        assertEq(converter.balance, 0.2 ether);
        assertEq(treasury.balance, 0.07 ether);
        assertEq(address(splitter).balance, 0, "no dust");
        assertEq(escrow.balanceOf(address(splitter)), 0);
        assertEq(splitter.totalToConverter(), 0.2 ether);
        assertEq(splitter.totalToTreasury(), 0.07 ether);
        // Pons kept its 30% of the base fee.
        assertEq(escrow.balanceOf(protocol), 0.03 ether);
    }

    function test_harvest_afterSellAccruesToo() public {
        _bind();
        uint256 got = _buy(10 ether);
        splitter.harvest();
        uint256 before_ = converter.balance + treasury.balance;
        _sell(got / 2);
        splitter.harvest();
        assertGt(converter.balance + treasury.balance, before_, "sell fee reached the split");
        assertEq(address(splitter).balance, 0);
    }

    function test_harvest_remainderGoesToTreasury() public {
        _bind();
        // choose an input whose creator share is not a multiple of 27 wei
        _buy(1_000_000_007 wei * 1000 + 13);
        (uint256 c, uint256 t) = splitter.harvest();
        uint256 total = c + t;
        assertEq(c, total * 20 / 27);
        assertEq(t, total - total * 20 / 27);
        assertEq(converter.balance, c);
        assertEq(treasury.balance, t);
        assertEq(address(splitter).balance, 0);
    }

    function test_harvest_isPermissionless() public {
        _bind();
        _buy(5 ether);
        vm.prank(makeAddr("random"));
        splitter.harvest();
        assertGt(converter.balance, 0);
    }

    function test_harvest_claimsWhatPonsAlreadySwept() public {
        _bind();
        _buy(5 ether);
        // Pons' operator sweeps first; the splitter finds the credit already in the escrow.
        vm.prank(operator);
        curve.sweepFees(0);
        assertGt(escrow.balanceOf(address(splitter)), 0);
        splitter.harvest();
        assertEq(escrow.balanceOf(address(splitter)), 0);
        assertEq(address(splitter).balance, 0);
        assertEq(converter.balance, 0.1 ether); // 0.135 ETH total * 20/27
    }

    function test_harvest_donationIsSplitToo() public {
        _bind();
        vm.deal(anyone, 100 ether);
        vm.prank(anyone);
        (bool ok,) = address(splitter).call{value: 1 wei}("");
        assertTrue(ok);
        (uint256 c, uint256 t) = splitter.harvest();
        assertEq(c, 0);
        assertEq(t, 1);
        assertEq(address(splitter).balance, 0);

        // escrow credit made by a third party for the splitter
        vm.prank(anyone);
        escrow.credit{value: 27 ether}(address(splitter));
        (c, t) = splitter.harvest();
        assertEq(c, 20 ether);
        assertEq(t, 7 ether);
    }

    // ───────────── Pons refusing the sweep ─────────────

    function test_postGraduation_hookSweepPaysThroughEscrow() public {
        _bind();
        _buy(10 ether);
        pons.graduate();
        // pre-graduation fees are still accrued in the curve (mock keeps them): sweep as operator, then hook fee arrives
        vm.prank(operator);
        curve.sweepFees(0);
        bytes32 poolId = pons.poolId();
        hook.accrue{value: 1 ether}(poolId, 0.4 ether); // 0.6 fee + 0.4 tax -> creator 0.42 + 0.4 = 0.82
        (uint256 c, uint256 t) = splitter.harvest();
        // 0.135... curve credit (0.27 total) + 0.82 hook credit
        assertEq(c + t, 0.27 ether + 0.82 ether);
        uint256 expectedTotal = 0.27 ether + 0.82 ether;
        assertEq(c, expectedTotal * 20 / 27);
        assertEq(address(splitter).balance, 0);
    }

    function test_postGraduation_operatorOnlySweepIsSkippedNotFatal() public {
        _bind();
        _buy(10 ether);
        vm.prank(operator);
        curve.sweepFees(0);
        pons.graduate();
        hook.accrue{value: 1 ether}(pons.poolId(), 0);
        hook.setNeedsOperator(true);

        vm.expectEmit(false, false, false, true);
        emit SweepSkipped(abi.encodeWithSelector(MOCK_PonsHook.InternalSwapRequiresOperator.selector));
        (uint256 c, uint256 t) = splitter.harvest();
        // only the credit Pons had already put in the escrow is split; the hook's fee waits for the operator
        assertEq(c + t, 0.27 ether);

        // operator sweeps the hook; the next harvest picks it up
        bytes32 poolId = pons.poolId();
        vm.prank(operator);
        hook.sweepPoolFees(poolId, 0, 0);
        (c, t) = splitter.harvest();
        assertEq(c + t, 0.7 ether);
    }

    using PoolIdLibrary for PoolKey;

    /// The pool id the splitter derives (and the mock hook registers) is the Uniswap v4 `PoolKey.toId()`.
    function test_poolIdMatchesUniswapV4() public view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        assertEq(PoolId.unwrap(key.toId()), pons.poolId());
    }

    function test_sweepSkippedBeforeAnythingAccrued_stillRevertsNothing() public {
        _bind();
        // curve sweep is a no-op, escrow empty
        vm.expectRevert(IQZFeeSplitter.NothingToHarvest.selector);
        splitter.harvest();
    }

    // ───────────── hostile recipients ─────────────

    function test_converterRevertingBubblesTransferFailedAndKeepsState() public {
        RevertingSink bad = new RevertingSink();
        vm.prank(owner);
        splitter.bind(address(bad), treasury);
        _buy(10 ether);
        vm.expectRevert(abi.encodeWithSelector(IQZFeeSplitter.TransferFailed.selector, address(bad), 0.2 ether));
        splitter.harvest();
        // nothing was lost: the sweep and the claim reverted with the call, so Pons still holds the whole fee
        assertEq(address(splitter).balance, 0);
        assertEq(splitter.totalToConverter(), 0);
        assertEq(splitter.totalToTreasury(), 0);
        assertEq(escrow.balanceOf(address(splitter)), 0, "escrow credit unchanged");
        assertEq(escrow.totalCredited(address(splitter)), 0, "escrow never credited");
        assertEq(address(escrow).balance, 0, "escrow ETH unchanged");
        assertEq(curve.quoteFeeBalance(), 0.1 ether, "curve base fee unchanged");
        assertEq(curve.creatorTaxBalance(), 0.2 ether, "curve tax unchanged");
        assertEq(address(curve).balance, 10 ether, "curve ETH unchanged");
    }

    /// The Pons sell side takes the 1% fee and the 2% creator tax from the ETH output; what the splitter harvests
    /// afterwards is exactly the creator share of buy and sell together.
    function test_sellSide_creatorTaxIsExactAndHarvested() public {
        _bind();
        uint256 out = _buy(10 ether);
        assertEq(curve.creatorTaxBalance(), 0.2 ether, "buy tax");
        assertEq(curve.quoteFeeBalance(), 0.1 ether, "buy fee");

        uint256 tokensIn = out / 2;
        uint256 gross = tokensIn * curve.quoteReserve() / (curve.tokenReserve() + tokensIn);
        uint256 fee = gross * 100 / 10_000;
        uint256 tax = gross * 200 / 10_000;
        assertGt(tax, 0);
        uint256 quoteOut = _sell(tokensIn);

        assertEq(quoteOut, gross - fee - tax, "sell output after fee and tax");
        assertEq(curve.creatorTaxBalance(), 0.2 ether + tax, "sell adds exactly 2% of the gross");
        assertEq(curve.quoteFeeBalance(), 0.1 ether + fee, "sell adds exactly 1% of the gross");

        uint256 creatorShare = (0.1 ether + fee) - (0.1 ether + fee) * 3000 / 10_000 + 0.2 ether + tax;
        (uint256 c, uint256 t) = splitter.harvest();
        assertEq(c + t, creatorShare, "harvest total == 70% of the base fee + 100% of the tax");
        assertEq(c, creatorShare * 20 / 27);
        assertEq(t, creatorShare - creatorShare * 20 / 27);
    }

    function test_reentrancyViaConverterIsBlocked() public {
        ReentrantSink evil = new ReentrantSink(splitter);
        vm.prank(owner);
        splitter.bind(address(evil), treasury);
        _buy(10 ether);
        splitter.harvest();
        assertEq(evil.lastSelector(), IQZFeeSplitter.Reentrancy.selector);
        assertEq(address(evil).balance, 0.2 ether);
        assertEq(treasury.balance, 0.07 ether);
    }

    function test_reentrancyViaTreasuryIsBlocked() public {
        ReentrantSink evil = new ReentrantSink(splitter);
        vm.prank(owner);
        splitter.bind(converter, address(evil));
        _buy(10 ether);
        splitter.harvest();
        assertEq(evil.lastSelector(), IQZFeeSplitter.Reentrancy.selector);
        assertEq(address(evil).balance, 0.07 ether);
    }

    // ───────────── a recipient that cannot take ETH ─────────────

    event TreasuryShareParked(address indexed treasury, uint256 amount);
    event TreasuryShareClaimed(address indexed to, uint256 amount);

    function test_treasuryRevertingParksShareAndHarvestCompletes() public {
        RevertingSink bad = new RevertingSink();
        vm.prank(owner);
        splitter.bind(converter, address(bad));
        _buy(10 ether);

        vm.expectEmit(true, false, false, true);
        emit TreasuryShareParked(address(bad), 0.07 ether);
        (uint256 c, uint256 t) = splitter.harvest();

        assertEq(c, 0.2 ether, "reward share unaffected");
        assertEq(t, 0.07 ether);
        assertEq(converter.balance, 0.2 ether, "converter paid");
        assertEq(splitter.totalToConverter(), 0.2 ether);
        assertEq(address(bad).balance, 0);
        assertEq(splitter.pendingTreasury(), 0.07 ether, "parked");
        assertEq(address(splitter).balance, 0.07 ether, "parked ETH stays here");
        assertEq(splitter.totalToTreasury(), 0, "not delivered yet");

        // the parked share is not split again by the next harvest
        vm.expectRevert(IQZFeeSplitter.NothingToHarvest.selector);
        splitter.harvest();

        // a second harvest adds to it; the new split is only of the new ETH
        _buy(10 ether);
        (c, t) = splitter.harvest();
        assertEq(c, 0.2 ether);
        assertEq(t, 0.07 ether);
        assertEq(splitter.pendingTreasury(), 0.14 ether);
        assertEq(address(splitter).balance, 0.14 ether);
        assertEq(converter.balance, 0.4 ether);
    }

    function test_treasuryPullPaysOnlyTheTreasuryToAnAddressItChooses() public {
        RevertingSink bad = new RevertingSink();
        vm.prank(owner);
        splitter.bind(converter, address(bad));
        _buy(10 ether);
        splitter.harvest();

        address dest = makeAddr("dest");
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IQZFeeSplitter.NotTreasury.selector, anyone));
        splitter.claimPendingTreasury(dest);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IQZFeeSplitter.NotTreasury.selector, owner));
        splitter.claimPendingTreasury(dest);

        vm.startPrank(address(bad));
        vm.expectRevert(IQZErrors.ZeroAddress.selector);
        splitter.claimPendingTreasury(address(0));
        // the destination may itself refuse: the call reverts and the share stays parked
        vm.expectRevert(abi.encodeWithSelector(IQZFeeSplitter.TransferFailed.selector, address(bad), 0.07 ether));
        splitter.claimPendingTreasury(address(bad));
        assertEq(splitter.pendingTreasury(), 0.07 ether);

        vm.expectEmit(true, false, false, true);
        emit TreasuryShareClaimed(dest, 0.07 ether);
        assertEq(splitter.claimPendingTreasury(dest), 0.07 ether);
        vm.expectRevert(IQZFeeSplitter.NothingPending.selector);
        splitter.claimPendingTreasury(dest);
        vm.stopPrank();

        assertEq(dest.balance, 0.07 ether);
        assertEq(splitter.pendingTreasury(), 0);
        assertEq(splitter.totalToTreasury(), 0.07 ether, "delivered once pulled");
        assertEq(address(splitter).balance, 0);
    }

    function test_treasuryBurningAllGasCannotBlockTheHarvest() public {
        GasBurner burner = new GasBurner();
        vm.prank(owner);
        splitter.bind(converter, address(burner));
        _buy(10 ether);
        (uint256 c, uint256 t) = splitter.harvest{gas: 3_000_000}();
        assertEq(c, 0.2 ether);
        assertEq(t, 0.07 ether);
        assertEq(converter.balance, 0.2 ether);
        assertEq(splitter.pendingTreasury(), 0.07 ether);
    }

    function test_treasuryContractThatNeedsMoreThanItsStipendStillGetsPaidByPull() public {
        // a treasury whose receive() works but is heavier than the stipend: parked, then pulled
        HeavyReceiver heavy = new HeavyReceiver();
        vm.prank(owner);
        splitter.bind(converter, address(heavy));
        _buy(10 ether);
        splitter.harvest();
        assertEq(splitter.pendingTreasury(), 0.07 ether);
        assertEq(address(heavy).balance, 0);
        vm.prank(address(heavy));
        splitter.claimPendingTreasury(address(heavy));
        assertEq(address(heavy).balance, 0.07 ether);
    }

    function test_pullIsReentrancyGuarded() public {
        RevertingSink bad = new RevertingSink();
        vm.prank(owner);
        splitter.bind(converter, address(bad));
        _buy(10 ether);
        splitter.harvest();
        ReentrantSink evil = new ReentrantSink(splitter);
        vm.prank(address(bad));
        splitter.claimPendingTreasury(address(evil));
        assertEq(evil.lastSelector(), IQZFeeSplitter.Reentrancy.selector);
        assertEq(address(evil).balance, 0.07 ether);
    }

    /// The treasury tries to pull from inside the harvest push (its receive hook): the shared lock refuses it, the
    /// push still succeeds, and the earlier parked share is still there to be pulled afterwards.
    function test_treasuryPullDuringHarvestPushIsBlocked() public {
        PullingTreasury tre = new PullingTreasury(splitter);
        vm.prank(owner);
        splitter.bind(converter, address(tre));

        tre.setRejecting(true);
        _buy(10 ether);
        splitter.harvest();
        assertEq(splitter.pendingTreasury(), 0.07 ether, "parked");

        tre.setRejecting(false);
        _buy(10 ether);
        splitter.harvest();
        assertEq(tre.lastSelector(), IQZFeeSplitter.Reentrancy.selector, "pull inside the push is refused");
        assertEq(address(tre).balance, 0.07 ether, "the push itself succeeded");
        assertEq(splitter.pendingTreasury(), 0.07 ether, "parked share untouched");
        assertEq(splitter.totalToTreasury(), 0.07 ether);

        tre.pullTo(makeAddr("dest2"));
        assertEq(makeAddr("dest2").balance, 0.07 ether);
        assertEq(splitter.pendingTreasury(), 0);
        assertEq(address(splitter).balance, 0);
    }

    // ───────────── no admin surface ─────────────

    function test_noAdminSurface() public {
        _bind();
        _buy(10 ether);
        bytes[7] memory calls = [
            abi.encodeWithSignature("transferCreatorFeeRecipient(address,address)", address(token), anyone),
            abi.encodeWithSignature("withdraw()"),
            abi.encodeWithSignature("withdraw(address)", owner),
            abi.encodeWithSignature("transferOwnership(address)", anyone),
            abi.encodeWithSignature("setConverter(address)", anyone),
            abi.encodeWithSignature("setTreasury(address)", anyone),
            abi.encodeWithSignature("sweep(address,address)", address(0), owner)
        ];
        vm.startPrank(owner);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(splitter).call(calls[i]);
            assertFalse(ok, "unexpected selector");
        }
        vm.stopPrank();
        assertEq(owner.balance, 0);
        // the creator-fee role stays with the splitter on the Pons side
        assertEq(pons.getLaunchedToken(address(token)).creatorFeeRecipient, address(splitter));
    }

    // ───────────── fuzz: conservation ─────────────

    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_conservation(uint256 buyA, uint256 buyB, uint256 sellBps, uint256 donation) public {
        _bind();
        buyA = bound(buyA, 1, 1_000 ether);
        buyB = bound(buyB, 1, 1_000 ether);
        sellBps = bound(sellBps, 0, 10_000);
        donation = bound(donation, 0, 10 ether);

        uint256 got = _buy(buyA);
        got += _buy(buyB);
        uint256 toSell = got * sellBps / 10_000;
        if (toSell != 0) _sell(toSell);
        if (donation != 0) {
            vm.deal(anyone, donation);
            vm.prank(anyone);
            (bool ok,) = address(splitter).call{value: donation}("");
            assertTrue(ok);
        }

        vm.prank(operator);
        curve.sweepFees(0); // sweep leaves the creator share in the escrow; protocol share is Pons'
        uint256 swept = escrow.balanceOf(address(splitter)) + donation;
        uint256 convBefore = converter.balance;
        uint256 treBefore = treasury.balance;

        if (swept == 0) {
            vm.expectRevert(IQZFeeSplitter.NothingToHarvest.selector);
            splitter.harvest();
            return;
        }
        (uint256 c, uint256 t) = splitter.harvest();

        assertEq(c + t, swept, "paid == swept");
        assertEq(c, swept * 20 / 27, "reward share rounded down");
        assertEq(t, swept - swept * 20 / 27, "treasury gets the remainder");
        assertEq(converter.balance - convBefore, c);
        assertEq(treasury.balance - treBefore, t);
        assertEq(address(splitter).balance, 0, "no dust");
        assertEq(escrow.balanceOf(address(splitter)), 0);
        // the 7/27 floor: the treasury is never short of its ratio
        assertGe(t * 20, c * 7);
    }
}

contract RevertingSink {
    receive() external payable {
        revert("no");
    }
}

/// @dev Tries to harvest again from inside the ETH transfer and records how that failed.
contract ReentrantSink {
    QZFeeSplitter private immutable S;
    bytes4 public lastSelector;

    constructor(QZFeeSplitter s) {
        S = s;
    }

    receive() external payable {
        try S.harvest() {}
        catch (bytes memory r) {
            lastSelector = bytes4(r);
        }
    }
}

/// @dev Answers every call with 1 MB of zeros (a return bomb), cheaply.
contract BigAnswerFactory {
    fallback() external {
        assembly {
            return(0, 1000000)
        }
    }
}

/// @dev A treasury that tries to pull its parked share from inside the harvest push; it can also be switched to
///      reject ETH so that a share gets parked.
contract PullingTreasury {
    QZFeeSplitter private immutable S;
    bool public rejecting;
    bytes4 public lastSelector;

    constructor(QZFeeSplitter s) {
        S = s;
    }

    function setRejecting(bool v) external {
        rejecting = v;
    }

    function pullTo(address to) external {
        S.claimPendingTreasury(to);
    }

    receive() external payable {
        require(!rejecting, "rejecting");
        try S.claimPendingTreasury(address(this)) {}
        catch (bytes memory r) {
            lastSelector = bytes4(r);
        }
    }
}

contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// @dev Accepts ETH, but with more work than the harvest's treasury stipend allows.
contract HeavyReceiver {
    uint256[40] private _slots;

    receive() external payable {
        for (uint256 i; i < 40; ++i) {
            _slots[i] = i + 1;
        }
    }
}

/// @dev A stand-in for a Pons factory that has changed its ABI: answers every call with a fixed raw payload (or reverts).
contract PayloadFactory {
    bytes private _payload;
    bool private _reverts;

    constructor(bytes memory payload, bool reverts) {
        _payload = payload;
        _reverts = reverts;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (_reverts) revert("changed");
        return _payload;
    }
}

/// @dev The sweep must never block the claim: a factory that is missing, reverts, answers short, answers garbage or
///      answers with out-of-range fields only skips the sweep, and the escrow credit is still harvested.
contract QZFeeSplitterFactoryRobustnessTest is FeeFixture {
    event SweepSkipped(bytes reason);

    function setUp() public {
        _deploy();
    }

    function _harvestWithFactory(address factory, bool expectSkip) internal {
        QZFeeSplitter s = new QZFeeSplitter(owner, address(escrow), factory, address(token), address(hook));
        vm.prank(owner);
        s.bind(converter, treasury);
        escrow.credit{value: 2.7 ether}(address(s));

        if (expectSkip) {
            vm.expectEmit(false, false, false, true, address(s));
            emit SweepSkipped("factory read");
        } else {
            vm.recordLogs();
        }
        uint256 convBefore = converter.balance;
        uint256 treBefore = treasury.balance;
        (uint256 c, uint256 t) = s.harvest();
        if (!expectSkip) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                assertTrue(logs[i].topics[0] != SweepSkipped.selector, "a valid record must not log SweepSkipped");
            }
        }
        assertEq(c, 2 ether, "reward share");
        assertEq(t, 0.7 ether, "treasury share");
        assertEq(converter.balance - convBefore, 2 ether);
        assertEq(treasury.balance - treBefore, 0.7 ether);
        assertEq(address(s).balance, 0);
        assertEq(escrow.balanceOf(address(s)), 0, "escrow claimed");
    }

    function _payload(uint256 len) internal pure returns (bytes memory p) {
        p = new bytes(len);
    }

    function test_factoryWithoutCodeStillClaims() public {
        _harvestWithFactory(makeAddr("nobody"), true);
    }

    function test_factoryRevertingStillClaims() public {
        _harvestWithFactory(address(new PayloadFactory("", true)), true);
    }

    function test_factoryEmptyAnswerStillClaims() public {
        _harvestWithFactory(address(new PayloadFactory("", false)), true);
    }

    function test_factoryShortAnswersStillClaim() public {
        _harvestWithFactory(address(new PayloadFactory(_payload(32), false)), true);
        _harvestWithFactory(address(new PayloadFactory(_payload(14 * 32), false)), true);
        _harvestWithFactory(address(new PayloadFactory(_payload(15 * 32 - 1), false)), true);
    }

    function test_factoryAllOnesGarbageStillClaims() public {
        bytes memory p = new bytes(15 * 32);
        for (uint256 i; i < p.length; ++i) {
            p[i] = 0xff;
        }
        _harvestWithFactory(address(new PayloadFactory(p, false)), true);
    }

    /// A 15-word record with one field outside its type is skipped; so are dirty address bits.
    function test_factoryOutOfRangeFieldsStillClaim() public {
        uint256[9] memory idx = [uint256(0), 1, 2, 3, 4, 6, 7, 10, 14];
        uint256[9] memory bad = [uint256(1) << 160, 1 << 160, 1 << 160, 1 << 160, 1 << 200, 1 << 24, 1 << 23, 256, 2];
        for (uint256 k; k < idx.length; ++k) {
            bytes memory p = abi.encode(pons.getLaunchedToken(address(token)));
            assertEq(p.length, 480);
            uint256 at = 32 + idx[k] * 32;
            uint256 v = bad[k];
            assembly {
                mstore(add(p, at), v)
            }
            _harvestWithFactory(address(new PayloadFactory(p, false)), true);
        }
        // a negative tick spacing is a valid int24
        bytes memory q = abi.encode(pons.getLaunchedToken(address(token)));
        uint256 neg = uint256(type(uint256).max - 59); // int24(-60) sign-extended
        assembly {
            mstore(add(q, add(32, mul(7, 32))), neg)
            mstore(add(q, add(32, mul(14, 32))), 0)
        }
        _harvestWithFactory(address(new PayloadFactory(q, false)), false);
    }

    /// An oversized answer is only read up to the 15 words and costs nothing extra; with `exists = false` it skips
    /// the sweep without a log.
    function test_factoryOversizedAnswerIsBounded() public {
        address factory = address(new BigAnswerFactory());
        QZFeeSplitter s = new QZFeeSplitter(owner, address(escrow), factory, address(token), address(hook));
        vm.prank(owner);
        s.bind(converter, treasury);
        escrow.credit{value: 2.7 ether}(address(s));
        uint256 g = gasleft();
        s.harvest();
        assertLt(g - gasleft(), 700_000, "the splitter copies 15 words, not the whole answer");
    }

    /// The real record still drives the sweep (guards the raw decoder against drifting from the struct layout).
    function test_rawDecoderReadsTheRealRecord() public {
        vm.prank(owner);
        splitter.bind(converter, treasury);
        _buy(10 ether);
        splitter.harvest();
        assertEq(curve.quoteFeeBalance(), 0, "sweep reached the curve");
        assertEq(curve.creatorTaxBalance(), 0);
    }
}
