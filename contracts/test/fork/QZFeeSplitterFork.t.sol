// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QZFeeSplitter} from "../../src/fee/QZFeeSplitter.sol";
import {IQZFeeSplitter} from "../../src/interfaces/IQZFeeSplitter.sol";
import {IPonsFactory, IPonsFeeEscrow} from "../../src/fee/IPons.sol";

interface IPonsCurveFull {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sweepFees(uint256 minBuybackTokensOut) external;
    function quoteFeeBalance() external view returns (uint256);
    function creatorTaxBalance() external view returns (uint256);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function graduated() external view returns (bool);
}

interface IPonsFactoryAdmin {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}

/// @notice The splitter against the REAL Pons v2 contracts on Robinhood Chain (chain id 4663), pinned at a block.
///         An existing ETH-pair token with a 2% creator tax is the fixture; its creator-fee recipient is handed to the
///         splitter with the factory's own `transferCreatorFeeRecipient` (the factory also accepts the recipient in
///         `TokenParams.creatorFeeRecipient`). Everything after that is the production path:
///         a real buy on the real curve, the splitter's `harvest()` -> real `sweepFees` -> real escrow `claim()` -> 20:7.
///
///         Run: `forge test --root contracts --match-path 'test/fork/**'
///               --fork-url https://robinhood.drpc.org --fork-block-number 119221300`
///         or set `ROBINHOOD_FORK_URL` (the test then forks that URL at the same pinned block). The public node
///         (robinhood-rpc.publicnode.com) serves no archive state, so a pinned block needs an archive endpoint.
///         Without either, the suite skips.
contract QZFeeSplitterForkTest is Test {
    uint256 internal constant PINNED_BLOCK = 119221300;

    address internal constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address internal constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    // an existing ETH-pair token (Pons config 0, 2% creator tax, not graduated at the pinned block)
    address internal constant TOKEN = 0x193922B3ce4f5377A71E933EA2b94439f69DE6E8;
    address internal constant CURVE = 0x56227d479EDF4Af50D3882f4fEbE941d8F8C3198;

    QZFeeSplitter internal splitter;
    address internal owner = makeAddr("owner");
    address internal converter = makeAddr("converter");
    address internal treasury = makeAddr("treasury");
    address internal trader = makeAddr("trader");

    function setUp() public {
        if (block.chainid != 4663) {
            string memory url = vm.envOr("ROBINHOOD_FORK_URL", string(""));
            if (bytes(url).length == 0) vm.skip(true);
            vm.createSelectFork(url, PINNED_BLOCK);
        }
        assertEq(block.chainid, 4663, "Robinhood Chain 4663");
        assertGt(FACTORY.code.length, 0, "factory has code");
        assertGt(ESCROW.code.length, 0, "escrow has code");
        assertGt(HOOK.code.length, 0, "hook has code");
    }

    function _handover() internal {
        splitter = new QZFeeSplitter(owner, ESCROW, FACTORY, TOKEN, HOOK);
        vm.prank(owner);
        splitter.bind(converter, treasury);

        IPonsFactory.LaunchedToken memory info = IPonsFactory(FACTORY).getLaunchedToken(TOKEN);
        vm.prank(info.creatorFeeRecipient);
        IPonsFactoryAdmin(FACTORY).transferCreatorFeeRecipient(TOKEN, address(splitter));
    }

    /// The ABI the splitter relies on, read off the live contracts.
    function test_fork_ponsAbiMatches() public view {
        IPonsFactory.LaunchedToken memory info = IPonsFactory(FACTORY).getLaunchedToken(TOKEN);
        assertTrue(info.exists);
        assertEq(info.token, TOKEN);
        assertEq(info.curve, CURVE);
        assertEq(info.pairToken, address(0), "native ETH pair");
        assertEq(info.phase, 0, "not graduated");
        assertEq(info.creatorTaxBps, 200, "2% creator tax");
        assertEq(info.poolFee, 0);
        assertEq(info.tickSpacing, 200);
        assertEq(IPonsCurveFull(CURVE).feeBps(), 100, "1% base fee");
        assertEq(IPonsCurveFull(CURVE).creatorTaxBps(), 200);
        assertFalse(IPonsCurveFull(CURVE).graduated());
        // the escrow ledger is readable by address
        IPonsFeeEscrow(ESCROW).balanceOf(info.creatorFeeRecipient);
    }

    function test_fork_harvestSplits20to7OfWhatPonsCredits() public {
        _handover();
        assertEq(IPonsFactory(FACTORY).getLaunchedToken(TOKEN).creatorFeeRecipient, address(splitter));

        // a real trade on the real curve accrues the real fee and tax
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        IPonsCurveFull(CURVE).buy{value: 1 ether}(1 ether, 0, trader);

        uint256 fee = IPonsCurveFull(CURVE).quoteFeeBalance();
        uint256 tax = IPonsCurveFull(CURVE).creatorTaxBalance();
        // Pons policy: protocol keeps 30% of the base fee; the creator gets the rest of it plus the whole tax
        uint256 expected = fee - fee * 3000 / 10_000 + tax;
        assertGt(expected, 0.02 ether, "creator share includes the 2% tax of a 1 ETH buy");
        assertEq(IPonsFeeEscrow(ESCROW).balanceOf(address(splitter)), 0, "nothing swept yet");

        vm.prank(makeAddr("anyone"));
        (uint256 c, uint256 t) = splitter.harvest();

        assertEq(c + t, expected, "splitter received exactly the creator share Pons credited");
        assertEq(c, expected * 20 / 27, "20/27 to the converter, rounded down");
        assertEq(t, expected - expected * 20 / 27, "remainder to the treasury");
        assertEq(converter.balance, c);
        assertEq(treasury.balance, t);
        assertEq(address(splitter).balance, 0, "no dust");
        assertEq(IPonsFeeEscrow(ESCROW).balanceOf(address(splitter)), 0, "escrow emptied");
        assertEq(IPonsCurveFull(CURVE).quoteFeeBalance(), 0, "curve fee swept");
        assertEq(IPonsCurveFull(CURVE).creatorTaxBalance(), 0, "curve tax swept");

        vm.expectRevert(IQZFeeSplitter.NothingToHarvest.selector);
        splitter.harvest();
    }

    /// The splitter holds the creator-fee role from the handover on and has no call that gives it away.
    function test_fork_splitterCannotGiveTheRoleAway() public {
        _handover();
        (bool ok,) = address(splitter)
            .call(abi.encodeWithSignature("transferCreatorFeeRecipient(address,address)", TOKEN, address(0xBEEF)));
        assertFalse(ok);
        vm.prank(owner);
        (ok,) = address(splitter)
            .call(abi.encodeWithSignature("transferCreatorFeeRecipient(address,address)", TOKEN, address(0xBEEF)));
        assertFalse(ok);
        assertEq(IPonsFactory(FACTORY).getLaunchedToken(TOKEN).creatorFeeRecipient, address(splitter));
    }

    /// A harvest with a fee already swept into the escrow by Pons' own operator (the splitter only claims).
    function test_fork_claimsCreditAlreadyInEscrow() public {
        _handover();
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        IPonsCurveFull(CURVE).buy{value: 1 ether}(1 ether, 0, trader);
        // an outsider credits the escrow ledger of the splitter directly (permissionless on the real escrow)
        vm.deal(trader, 27 ether);
        vm.prank(trader);
        (bool ok,) = ESCROW.call{value: 27 ether}(abi.encodeWithSignature("credit(address)", address(splitter)));
        assertTrue(ok);
        uint256 fee = IPonsCurveFull(CURVE).quoteFeeBalance();
        uint256 tax = IPonsCurveFull(CURVE).creatorTaxBalance();
        uint256 expected = 27 ether + fee - fee * 3000 / 10_000 + tax;
        (uint256 c, uint256 t) = splitter.harvest();
        assertEq(c + t, expected);
        assertEq(c, expected * 20 / 27);
        assertEq(address(splitter).balance, 0);
    }
}
