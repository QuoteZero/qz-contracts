// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import {QZMachine} from "../../src/machine/QZMachine.sol";
import {IQZMachine} from "../../src/interfaces/IQZMachine.sol";
import {IQZErrors} from "../../src/interfaces/IQZCommon.sol";
import {QZConstants} from "../../src/lib/QZConstants.sol";
import {MintPhase} from "../../src/lib/QZTypes.sol";
import {MachineFixture} from "./MachineFixture.sol";

/// @notice B1: the phased USDG mint. Phase prices, proofs, one mint per wallet, the 25/75 split in the mint
///         transaction, no USDG left on the contract, and every way the payment can fail.
contract QZMachineMintTest is MachineFixture {
    // ───────────── constructor and configuration ─────────────

    function test_constructorSealsPricesAndAddresses() public view {
        assertEq(machine.priceGtd(), 3_000_000);
        assertEq(machine.priceFcfs(), 4_000_000);
        assertEq(machine.pricePublic(), 5_000_000);
        assertEq(machine.owner(), owner);
        assertEq(machine.pauser(), pauser);
        assertEq(machine.usdg(), address(usdg));
        assertEq(machine.converter(), converter);
        assertEq(machine.treasury(), treasury);
        assertEq(machine.entropy(), address(entropy));
        assertEq(machine.TRAITS_HASH(), TRAITS_HASH);
        assertEq(machine.maxSupply(), 2222);
        assertEq(machine.name(), "QuoteZero Machine");
    }

    function test_constructorPricesAreArguments() public {
        QZMachine m = _deploy(owner, pauser, 11, 22, 33, 24 hours, 12 hours, 24 hours);
        assertEq(m.priceGtd(), 11);
        assertEq(m.priceFcfs(), 22);
        assertEq(m.pricePublic(), 33);
    }

    function test_constructorRejectsZeroes() public {
        address[6] memory a = [owner, pauser, address(usdg), converter, treasury, address(entropy)];
        for (uint256 i; i < 6; ++i) {
            address[6] memory b = a;
            b[i] = address(0);
            vm.expectRevert(IQZErrors.ZeroAddress.selector);
            new QZMachine(
                b[0],
                b[1],
                b[2],
                b[3],
                b[4],
                b[5],
                TRAITS_HASH,
                3,
                4,
                5,
                QZMachine.MintWindows(_gtdWindow(), _fcfsWindow(), _publicWindow())
            );
        }
        vm.expectRevert(IQZErrors.ZeroAmount.selector);
        new QZMachine(
            owner,
            pauser,
            address(usdg),
            converter,
            treasury,
            address(entropy),
            TRAITS_HASH,
            0,
            4,
            5,
            QZMachine.MintWindows(1 days, 1 days, 1 days)
        );
        vm.expectRevert(IQZErrors.ZeroAmount.selector);
        new QZMachine(
            owner,
            pauser,
            address(usdg),
            converter,
            treasury,
            address(entropy),
            TRAITS_HASH,
            3,
            0,
            5,
            QZMachine.MintWindows(1 days, 1 days, 1 days)
        );
        vm.expectRevert(IQZErrors.ZeroAmount.selector);
        new QZMachine(
            owner,
            pauser,
            address(usdg),
            converter,
            treasury,
            address(entropy),
            TRAITS_HASH,
            3,
            4,
            0,
            QZMachine.MintWindows(1 days, 1 days, 1 days)
        );
    }

    function test_scheduleIsSetOnce() public view {
        assertEq(machine.gtdRoot(), gtdRoot);
        assertEq(machine.fcfsRoot(), fcfsRoot);
        assertEq(machine.mintStart(), START);
        assertEq(machine.gtdEnd(), START + 24 hours);
        assertEq(machine.fcfsEnd(), START + 36 hours);
        assertEq(machine.publicEnd(), START + 60 hours);
    }

    function test_configureEmitsAndOnlyOnce() public {
        QZMachine m = _fresh();
        vm.expectEmit(address(m));
        emit IQZMachine.MintConfigured(gtdRoot, fcfsRoot, START, START + 24 hours, START + 36 hours, START + 60 hours);
        vm.prank(owner);
        m.configureMint(gtdRoot, fcfsRoot, START);

        vm.prank(owner);
        vm.expectRevert(IQZMachine.AlreadyConfigured.selector);
        m.configureMint(gtdRoot, fcfsRoot, START + 1 days);
    }

    function test_configureOnlyOwner() public {
        QZMachine m = _fresh();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotOwner.selector, pauser));
        m.configureMint(gtdRoot, fcfsRoot, START);
    }

    function test_configureBadSchedule() public {
        QZMachine m = _fresh();
        vm.startPrank(owner);
        vm.expectRevert(IQZMachine.BadSchedule.selector);
        m.configureMint(bytes32(0), fcfsRoot, START);
        vm.expectRevert(IQZMachine.BadSchedule.selector);
        m.configureMint(gtdRoot, bytes32(0), START);
        vm.expectRevert(IQZMachine.BadSchedule.selector);
        m.configureMint(gtdRoot, fcfsRoot, uint64(block.timestamp - 1));
        // a failed call leaves it open to a good one
        m.configureMint(gtdRoot, fcfsRoot, uint64(block.timestamp));
        vm.stopPrank();
        assertEq(m.mintStart(), block.timestamp);
    }

    function test_mintBeforeConfigureReverts() public {
        QZMachine m = _fresh();
        assertEq(uint8(m.phase()), uint8(MintPhase.Pending));
        _fund(gtd0, GTD_PRICE);
        vm.prank(gtd0);
        usdg.approve(address(m), GTD_PRICE);
        vm.prank(gtd0);
        vm.expectRevert(IQZMachine.NotConfigured.selector);
        m.mint(_gtdProof(gtd0));
        vm.expectRevert(IQZMachine.NotConfigured.selector);
        m.finalizeMint();
    }

    // ───────────── phases ─────────────

    function test_phaseFollowsTheClock() public {
        assertEq(uint8(machine.phase()), uint8(MintPhase.Pending));
        vm.warp(START - 1);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Pending));
        vm.warp(START);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Gtd));
        vm.warp(START + 24 hours - 1);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Gtd));
        vm.warp(START + 24 hours);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Fcfs));
        vm.warp(START + 36 hours - 1);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Fcfs));
        vm.warp(START + 36 hours);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Public));
        vm.warp(START + 60 hours - 1);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Public));
        vm.warp(START + 60 hours);
        assertEq(uint8(machine.phase()), uint8(MintPhase.Closed));
    }

    function test_mintBeforeOpenReverts() public {
        _fund(gtd0, GTD_PRICE);
        bytes32[] memory proof = _gtdProof(gtd0);
        vm.prank(gtd0);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.MintNotOpen.selector, MintPhase.Pending));
        machine.mint(proof);
    }

    function test_mintAfterPublicWindowReverts() public {
        _warpAfterPublic();
        _fund(nobody, PUBLIC_PRICE);
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.MintNotOpen.selector, MintPhase.Closed));
        machine.mint(_noProof());
    }

    // ───────────── exact prices per phase ─────────────

    function test_gtdProofPaysExactlyThreeUsdg() public {
        _warpGtd();
        _assertPaid(gtd0, _gtdProof(gtd0), 3e6, MintPhase.Gtd);
    }

    function test_fcfsProofPaysExactlyFourUsdg() public {
        _warpFcfs();
        _assertPaid(fcfs0, _fcfsProof(fcfs0), 4e6, MintPhase.Fcfs);
    }

    function test_publicMintPaysExactlyFiveUsdg() public {
        _warpPublic();
        _assertPaid(nobody, _noProof(), 5e6, MintPhase.Public);
    }

    function test_gtdWalletMintingInPublicWindowPaysPublicPrice() public {
        _warpPublic();
        // the GTD proof is ignored in the public window; the wallet pays 5 USDG, not 3
        _assertPaid(gtd1, _gtdProof(gtd1), 5e6, MintPhase.Public);
    }

    function test_fcfsWalletMintingInPublicWindowPaysPublicPrice() public {
        _warpPublic();
        _assertPaid(fcfs1, _fcfsProof(fcfs1), 5e6, MintPhase.Public);
    }

    function test_gtdWalletInFcfsWindowNeedsFcfsProof() public {
        _warpFcfs();
        _fund(gtd2, FCFS_PRICE);
        // its own GTD proof does not open the FCFS window
        bytes32[] memory proof = _gtdProof(gtd2);
        vm.prank(gtd2);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, gtd2));
        machine.mint(proof);
    }

    function test_fcfsWalletInGtdWindowReverts() public {
        _warpGtd();
        _fund(fcfs2, GTD_PRICE);
        bytes32[] memory proof = _fcfsProof(fcfs2);
        vm.prank(fcfs2);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, fcfs2));
        machine.mint(proof);
    }

    function test_walletOnBothListsPaysEachWindowsPrice() public {
        _warpGtd();
        _assertPaid(both, _gtdProof(both), 3e6, MintPhase.Gtd);
    }

    function test_unlistedWalletCannotMintInGtdOrFcfs() public {
        _fund(nobody, PUBLIC_PRICE);
        bytes32[] memory proof = _gtdProof(gtd0);
        _warpGtd();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, nobody));
        machine.mint(proof);
        proof = _fcfsProof(fcfs0);
        _warpFcfs();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, nobody));
        machine.mint(proof);
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, nobody));
        machine.mint(_noProof());
    }

    function test_badProofReverts() public {
        _warpGtd();
        _fund(gtd0, GTD_PRICE);
        // someone else's proof, a truncated proof, a tampered proof
        bytes32[] memory other = _gtdProof(gtd1);
        bytes32[] memory own = _gtdProof(gtd0);
        bytes32[] memory truncated = new bytes32[](own.length - 1);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = own[i];
        }
        bytes32[] memory tampered = _gtdProof(gtd0);
        tampered[0] = bytes32(uint256(tampered[0]) ^ 1);

        vm.startPrank(gtd0);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, gtd0));
        machine.mint(other);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, gtd0));
        machine.mint(truncated);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, gtd0));
        machine.mint(tampered);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, gtd0));
        machine.mint(_noProof());
        vm.stopPrank();
        assertEq(machine.mintedCount(), 0);
        assertEq(usdg.balanceOf(gtd0), GTD_PRICE);
    }

    // ───────────── one mint per wallet ─────────────

    function test_secondMintSamePhaseReverts() public {
        _warpGtd();
        _mintAs(gtd0, GTD_PRICE, _gtdProof(gtd0));
        _fund(gtd0, GTD_PRICE);
        bytes32[] memory proof = _gtdProof(gtd0);
        vm.prank(gtd0);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.AlreadyMinted.selector, gtd0));
        machine.mint(proof);
    }

    function test_secondMintInLaterPhaseReverts() public {
        _warpGtd();
        _mintAs(both, GTD_PRICE, _gtdProof(both));

        _warpFcfs();
        _fund(both, FCFS_PRICE);
        bytes32[] memory proof = _fcfsProof(both);
        vm.prank(both);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.AlreadyMinted.selector, both));
        machine.mint(proof);

        _warpPublic();
        _fund(both, PUBLIC_PRICE);
        vm.prank(both);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.AlreadyMinted.selector, both));
        machine.mint(_noProof());
        assertEq(machine.balanceOf(both), 1);
    }

    function test_publicMintThenAnotherPublicMintReverts() public {
        _warpPublic();
        _mintAs(nobody, PUBLIC_PRICE, _noProof());
        _fund(nobody, PUBLIC_PRICE);
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.AlreadyMinted.selector, nobody));
        machine.mint(_noProof());
    }

    function test_sendingTheMachineAwayDoesNotAllowAnotherMint() public {
        _warpPublic();
        uint256 id = _mintAs(nobody, PUBLIC_PRICE, _noProof());
        vm.prank(nobody);
        machine.transferFrom(nobody, gtd0, id);
        assertTrue(machine.hasMinted(nobody));
        _fund(nobody, PUBLIC_PRICE);
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.AlreadyMinted.selector, nobody));
        machine.mint(_noProof());
    }

    function test_idsAreSequentialInMintOrder() public {
        _warpGtd();
        assertEq(_mintAs(gtd0, GTD_PRICE, _gtdProof(gtd0)), 1);
        assertEq(_mintAs(gtd1, GTD_PRICE, _gtdProof(gtd1)), 2);
        _warpPublic();
        assertEq(_mintAs(nobody, PUBLIC_PRICE, _noProof()), 3);
        assertEq(machine.ownerOf(1), gtd0);
        assertEq(machine.ownerOf(3), nobody);
        assertEq(machine.totalSupply(), 3);
        assertEq(machine.mintedCount(), 3);
    }

    // ───────────── priceOf ─────────────

    function test_priceOfMatchesMintAndRevertsWhereMintDoes() public {
        // before open
        bytes32[] memory gProof = _gtdProof(gtd0);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.MintNotOpen.selector, MintPhase.Pending));
        machine.priceOf(gtd0, gProof);

        _warpGtd();
        assertEq(machine.priceOf(gtd0, gProof), GTD_PRICE);
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.NotEligible.selector, nobody));
        machine.priceOf(nobody, gProof);

        _warpFcfs();
        assertEq(machine.priceOf(fcfs0, _fcfsProof(fcfs0)), FCFS_PRICE);

        _warpPublic();
        assertEq(machine.priceOf(nobody, _noProof()), PUBLIC_PRICE);
        assertEq(machine.priceOf(gtd0, gProof), PUBLIC_PRICE);

        _mintAs(nobody, PUBLIC_PRICE, _noProof());
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.AlreadyMinted.selector, nobody));
        machine.priceOf(nobody, _noProof());

        _warpAfterPublic();
        vm.expectRevert(abi.encodeWithSelector(IQZMachine.MintNotOpen.selector, MintPhase.Closed));
        machine.priceOf(gtd0, gProof);
    }

    // ───────────── payment failures ─────────────

    function test_pausedUsdgRevertsTheMint() public {
        _warpPublic();
        _fund(nobody, PUBLIC_PRICE);
        usdg.setPaused(true);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());
        _assertNothingMoved(nobody, PUBLIC_PRICE);

        usdg.setPaused(false);
        vm.prank(nobody);
        machine.mint(_noProof());
        assertEq(machine.ownerOf(1), nobody);
    }

    function test_blocklistedPayerRevertsTheMint() public {
        _warpPublic();
        _fund(nobody, PUBLIC_PRICE);
        usdg.setBlocked(nobody, true);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());
        _assertNothingMoved(nobody, PUBLIC_PRICE);
    }

    function test_blocklistedConverterOrTreasuryRevertsTheMint() public {
        _warpPublic();
        _fund(nobody, PUBLIC_PRICE);
        usdg.setBlocked(converter, true);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());
        _assertNothingMoved(nobody, PUBLIC_PRICE);
        usdg.setBlocked(converter, false);

        usdg.setBlocked(treasury, true);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());
        _assertNothingMoved(nobody, PUBLIC_PRICE);
    }

    function test_missingApprovalOrBalanceRevertsTheMint() public {
        _warpPublic();
        usdg.mint(nobody, PUBLIC_PRICE);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());

        // approval one unit short
        vm.prank(nobody);
        usdg.approve(address(machine), PUBLIC_PRICE - 1);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());

        // approved but a gtd price in the wallet
        vm.prank(nobody);
        usdg.approve(address(machine), PUBLIC_PRICE);
        vm.prank(nobody);
        usdg.transfer(treasury, 2e6);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());
        assertEq(machine.mintedCount(), 0);
        assertFalse(machine.hasMinted(nobody));
    }

    function test_tokenThatReturnsFalseRevertsTheMint() public {
        _warpPublic();
        _fund(nobody, PUBLIC_PRICE);
        usdg.setReturnFalse(true);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());
        assertEq(machine.mintedCount(), 0);
    }

    function test_tokenThatMovesFundsThenReturnsFalseRevertsTheMint() public {
        _warpPublic();
        _fund(nobody, PUBLIC_PRICE);
        usdg.setReturnFalseAfterMove(true);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());
        // the revert undoes the transfers: nothing moved, no machine minted
        _assertNothingMoved(nobody, PUBLIC_PRICE);
    }

    function test_feeOnTransferTokenRevertsTheMint() public {
        _warpPublic();
        _fund(nobody, PUBLIC_PRICE);
        usdg.setFeeBps(1);
        vm.prank(nobody);
        vm.expectRevert(IQZMachine.PaymentFailed.selector);
        machine.mint(_noProof());
        assertEq(machine.mintedCount(), 0);
        assertEq(usdg.balanceOf(nobody), PUBLIC_PRICE);
    }

    // ───────────── pause ─────────────

    function test_pauseStopsTheMintAndOnlyThePauserSwitchesIt() public {
        _warpPublic();
        _fund(nobody, PUBLIC_PRICE);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotPauser.selector, owner));
        machine.pause();

        vm.prank(pauser);
        machine.pause();
        assertTrue(machine.paused());
        vm.prank(pauser);
        vm.expectRevert(IQZErrors.EnforcedPause.selector);
        machine.pause();

        vm.prank(nobody);
        vm.expectRevert(IQZErrors.EnforcedPause.selector);
        machine.mint(_noProof());

        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IQZErrors.NotPauser.selector, nobody));
        machine.unpause();
        vm.prank(pauser);
        machine.unpause();
        vm.prank(pauser);
        vm.expectRevert(IQZErrors.ExpectedPause.selector);
        machine.unpause();

        vm.prank(nobody);
        machine.mint(_noProof());
        assertEq(machine.mintedCount(), 1);
    }

    // ───────────── ERC-721 surface ─────────────

    function test_royaltyIsZero() public view {
        (address receiver, uint256 amount) = machine.royaltyInfo(1, 1_000_000 ether);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
        assertTrue(machine.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(machine.supportsInterface(type(IERC721).interfaceId));
        assertTrue(machine.supportsInterface(type(IERC721Metadata).interfaceId));
    }

    function test_minterReceivesWithoutCallback() public {
        // a contract that cannot receive ERC-721 still gets the machine: the mint is not a safe mint
        _warpPublic();
        Deaf deaf = new Deaf();
        usdg.mint(address(deaf), PUBLIC_PRICE);
        deaf.buy(machine, MockUSDGLike(address(usdg)));
        assertEq(machine.ownerOf(1), address(deaf));
    }

    // ───────────── helpers ─────────────

    function _fresh() internal returns (QZMachine m) {
        m = _deploy(owner, pauser, GTD_PRICE, FCFS_PRICE, PUBLIC_PRICE, _gtdWindow(), _fcfsWindow(), _publicWindow());
    }

    /// @dev Mint as `who` and check the exact USDG: payer down by `price`, converter up by 25%, treasury up by 75%,
    ///      nothing on the machine, and the `Minted` event.
    function _assertPaid(address who, bytes32[] memory proof, uint256 price, MintPhase expectedPhase) internal {
        _fund(who, price);
        uint256 c0 = usdg.balanceOf(converter);
        uint256 t0 = usdg.balanceOf(treasury);
        uint256 nextId = machine.mintedCount() + 1;

        vm.expectEmit(true, true, false, true, address(machine));
        emit IQZMachine.Minted(who, nextId, expectedPhase, price, price / 4, price - price / 4);
        vm.prank(who);
        uint256 id = machine.mint(proof);

        assertEq(id, nextId);
        assertEq(machine.ownerOf(id), who);
        assertEq(usdg.balanceOf(who), 0, "payer paid the whole price");
        assertEq(usdg.balanceOf(converter) - c0, price * 25 / 100, "25% to the converter");
        assertEq(usdg.balanceOf(treasury) - t0, price * 75 / 100, "75% to the treasury");
        assertEq(usdg.balanceOf(address(machine)), 0, "no USDG on the machine");
        assertEq(usdg.allowance(who, address(machine)), 0, "allowance fully spent");
        assertTrue(machine.hasMinted(who));
        // exact amounts from the spec table
        if (expectedPhase == MintPhase.Gtd) {
            assertEq(usdg.balanceOf(converter) - c0 + usdg.balanceOf(treasury) - t0, 3e6);
        }
        if (expectedPhase == MintPhase.Fcfs) {
            assertEq(usdg.balanceOf(converter) - c0 + usdg.balanceOf(treasury) - t0, 4e6);
        }
        if (expectedPhase == MintPhase.Public) {
            assertEq(usdg.balanceOf(converter) - c0 + usdg.balanceOf(treasury) - t0, 5e6);
        }
    }

    function _assertNothingMoved(address who, uint256 balance) internal view {
        assertEq(machine.mintedCount(), 0);
        assertFalse(machine.hasMinted(who));
        assertEq(usdg.balanceOf(who), balance);
        assertEq(usdg.balanceOf(converter), 0);
        assertEq(usdg.balanceOf(treasury), 0);
        assertEq(usdg.balanceOf(address(machine)), 0);
    }
}

/// @dev A contract with no `onERC721Received`.
contract Deaf {
    function buy(QZMachine m, MockUSDGLike usdg) external {
        usdg.approve(address(m), type(uint256).max);
        m.mint(new bytes32[](0));
    }
}

interface MockUSDGLike {
    function approve(address spender, uint256 amount) external returns (bool);
}
