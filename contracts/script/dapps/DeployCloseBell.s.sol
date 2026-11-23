// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {QZConstants as C} from "../../src/lib/QZConstants.sol";
import {QZBoardSource} from "../../src/dapps/QZBoardSource.sol";
import {QZCloseBell} from "../../src/dapps/QZCloseBell.sol";
import {Profile} from "../../src/interfaces/IQZCloseBell.sol";

/// @title DeployCloseBell
/// @notice Deploys the Closing Bell dapp on the Robinhood testnet (chain 46630 only): a keeper-fed `QZBoardSource`
///         price board and the `QZCloseBell` that reads it. Nothing of the six deployed contracts is touched; the Bell
///         only reads `QZMachine.traitsOf` / `ownerOf` and `QZForge.isLit`. Prints one `QZ_BELL_JSON:{...}` line.
///
///         Environment (the key is passed by `secret env-file`, never as an argument):
///           - `DEPLOYER_PRIVATE_KEY`  deployer EOA key. Required.
///           - `QZ_MACHINE`, `QZ_FORGE`, `QZ_TOKEN`, `QZ_USDG`  addresses; default to the live testnet deployment.
///           - `BELL_CALENDAR`, `BELL_TREASURY`, `BELL_POSTER`  default to the deployer.
///           - `BELL_SPONSOR`  default none (address zero).
///           - `BELL_VOID_AFTER` (1200), `BELL_CLAIM_DELAY` (1200; must be >= void after), `BELL_MIN_LEAD` (120),
///             `BELL_SNAPSHOT_DELAY` (60), `BELL_BOARD_MAX_AGE` (120): seconds.
///           - `BELL_BOARD_MASK` supported tracks bitmask; default 0x33F (every track except NFLX and RDDT, whose
///             testnet pools are dry).
contract DeployCloseBell is Script {
    address internal constant TESTNET_MACHINE = 0xdC0913Ac1d7fc7a8c4768EcE7b6164b24266bb86;
    address internal constant TESTNET_FORGE = 0xec93A81d5851eF77409531E722e23a1d7997C69c;
    address internal constant TESTNET_QZ = 0x46475dB303B7556C8659Ae6990D135b48a6c393e;
    address internal constant TESTNET_USDG = 0x3867543A02f8E9B5DDF49dDd10D6B57e94F6D23E;

    function run() external {
        require(block.chainid == C.CHAIN_ID_ROBINHOOD_TESTNET, "DeployCloseBell: not the Robinhood testnet");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address machine = vm.envOr("QZ_MACHINE", TESTNET_MACHINE);
        address forge = vm.envOr("QZ_FORGE", TESTNET_FORGE);
        address qz = vm.envOr("QZ_TOKEN", TESTNET_QZ);
        address usdg = vm.envOr("QZ_USDG", TESTNET_USDG);
        require(
            machine.code.length != 0 && forge.code.length != 0 && qz.code.length != 0 && usdg.code.length != 0,
            "DeployCloseBell: a dependency has no code"
        );

        Profile memory p = Profile({
            voidAfter: uint64(vm.envOr("BELL_VOID_AFTER", uint256(1200))),
            claimDelay: uint64(vm.envOr("BELL_CLAIM_DELAY", uint256(1200))),
            minLead: uint64(vm.envOr("BELL_MIN_LEAD", uint256(120))),
            snapshotDelay: uint64(vm.envOr("BELL_SNAPSHOT_DELAY", uint256(60)))
        });

        vm.startBroadcast(pk);
        QZBoardSource board = new QZBoardSource(
            deployer,
            vm.envOr("BELL_POSTER", deployer),
            uint64(vm.envOr("BELL_BOARD_MAX_AGE", uint256(120))),
            uint16(vm.envOr("BELL_BOARD_MASK", uint256(0x33F)))
        );
        QZCloseBell bell = new QZCloseBell(
            machine,
            forge,
            qz,
            usdg,
            address(board),
            vm.envOr("BELL_CALENDAR", deployer),
            vm.envOr("BELL_TREASURY", deployer),
            vm.envOr("BELL_SPONSOR", address(0)),
            p
        );
        vm.stopBroadcast();

        console2.log(
            string.concat(
                "QZ_BELL_JSON:{\"chainId\":",
                vm.toString(block.chainid),
                ",\"bell\":\"",
                vm.toString(address(bell)),
                "\",\"board\":\"",
                vm.toString(address(board)),
                "\"}"
            )
        );
    }
}
