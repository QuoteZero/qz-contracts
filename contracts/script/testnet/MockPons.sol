// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {IPonsFactory} from "../../src/fee/IPons.sol";

/// @title MOCK_PonsFactory (TESTNET ONLY)
/// @notice ############################ MOCK. NOT PONS. TESTNET AND TESTS ONLY. ############################
///         Robinhood Chain testnet (46630) has no Pons. This file stands in for the slice of Pons v2 that
///         `QZFeeSplitter` calls, with the same function signatures and the same fee semantics, so the fee path
///         (token trade -> creator tax -> escrow -> `QZFeeSplitter.harvest` -> converter) can be proven end to end on
///         testnet. It lives under `script/testnet` and is never imported from `src/`; it is not deployed on mainnet.
///
///         `new MOCK_PonsFactory(creatorFeeRecipient, protocolFeeRecipient, sweepOperator)` deploys in one go:
///           - `MOCK_PonsFeeEscrow`    same `credit(recipient)` payable / `claim()` / `balanceOf` as `PonsV2FeeEscrow`
///                                     (native ETH ledger, `claim` pays the caller its whole balance, `NoBalance` at 0);
///           - `MOCK_QZTestToken`      "Test QZ" ("tQZ"), 18 decimals, the launched token;
///           - `MOCK_PonsCurve`        a constant-product curve with the real fee model (1% base fee, 2% creator tax,
///                                     both on the ETH side; creator share = 70% of the base fee + 100% of the tax,
///                                     protocol share = 30% of the base fee) whose `sweepFees(uint256)` credits the
///                                     escrow, callable by the creator fee recipient or the sweep operator;
///           - `MOCK_PonsHook`         post-graduation `sweepPoolFees(bytes32,uint256,uint256)` with the same caller rule.
///         and answers `getLaunchedToken(token)` with the Pons `LaunchedToken` record (phase 0 until `graduate()`).
///
///         Differences from real Pons (all irrelevant to the splitter): no graduation threshold, no Uniswap v4 pool,
///         no buyback, no slippage guards beyond `minTokensOut`/`minQuoteOut`, anyone may call `graduate()`.
contract MOCK_PonsFactory is IPonsFactory {
    MOCK_PonsFeeEscrow public immutable escrow;
    MOCK_QZTestToken public immutable token;
    MOCK_PonsCurve public immutable curve;
    MOCK_PonsHook public immutable hook;
    address public immutable creatorFeeRecipient;
    uint8 public phase;
    /// @notice Test $QZ minted once to the factory's deployer, on top of the curve's supply (fixed forever: `lock`).
    uint256 public constant TESTNET_RESERVE = 10_000_000_000 ether;

    constructor(address creatorFeeRecipient_, address protocolFeeRecipient_, address sweepOperator_) {
        creatorFeeRecipient = creatorFeeRecipient_;
        escrow = new MOCK_PonsFeeEscrow();
        token = new MOCK_QZTestToken();
        curve = new MOCK_PonsCurve(token, escrow, creatorFeeRecipient_, protocolFeeRecipient_, sweepOperator_);
        hook = new MOCK_PonsHook(escrow, creatorFeeRecipient_, protocolFeeRecipient_, sweepOperator_);
        token.mint(address(curve), curve.INITIAL_TOKEN_RESERVE());
        // The testnet dapp hands this token out through `QZTestFaucet`, which needs far more than the curve's 1B supply
        // would let anyone buy with testnet ETH: a fixed reserve goes to whoever deploys the factory, then no more is ever minted.
        token.mint(msg.sender, TESTNET_RESERVE);
        token.lock();
    }

    /// @notice Move the launch to the post-graduation phase and register the pool in the mock hook.
    function graduate() external {
        require(phase == 0, "graduated");
        phase = 2;
        curve.markGraduated();
        hook.register(poolId());
    }

    function poolId() public view returns (bytes32) {
        return keccak256(abi.encode(address(0), address(token), uint24(0), int24(200), address(hook)));
    }

    function getLaunchedToken(address token_) external view returns (LaunchedToken memory t) {
        if (token_ != address(token)) return t;
        t = LaunchedToken({
            token: address(token),
            curve: address(curve),
            deployer: address(this),
            creatorFeeRecipient: creatorFeeRecipient,
            pairToken: address(0),
            graduationThreshold: 4.2 ether,
            poolFee: 0,
            tickSpacing: 200,
            creatorTaxBps: uint16(curve.creatorTaxBps()),
            buybackEnabled: false,
            phase: phase,
            sweptQuote: 0,
            sweptTokens: 0,
            sweptAt: 0,
            exists: true
        });
    }
}

/// @title MOCK_PonsFeeEscrow (TESTNET ONLY)
/// @notice MOCK of `PonsV2FeeEscrow` (native ETH ledger only). `credit` is permissionless like the real one.
contract MOCK_PonsFeeEscrow {
    mapping(address => uint256) public balanceOf;
    /// @notice Mock-only: cumulative ETH ever credited per recipient (for tests).
    mapping(address => uint256) public totalCredited;
    bool private _locked;

    event Credited(address indexed recipient, address indexed depositor, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);

    error NoBalance();
    error TransferFailed();
    error ZeroAddress();
    error Reentrancy();

    function credit(address recipient) external payable {
        if (recipient == address(0)) revert ZeroAddress();
        balanceOf[recipient] += msg.value;
        totalCredited[recipient] += msg.value;
        emit Credited(recipient, msg.sender, msg.value);
    }

    /// @notice Pay the caller its whole balance.
    function claim() external returns (uint256 amount) {
        if (_locked) revert Reentrancy();
        _locked = true;
        amount = balanceOf[msg.sender];
        if (amount == 0) revert NoBalance();
        balanceOf[msg.sender] = 0;
        emit Claimed(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        _locked = false;
    }
}

/// @title MOCK_QZTestToken (TESTNET ONLY)
/// @notice MOCK ERC-20 standing in for the Pons-launched QZ token. Minted once to the curve, then locked.
contract MOCK_QZTestToken is ERC20 {
    address private immutable _factory = msg.sender;
    bool public locked;

    function name() public pure override returns (string memory) {
        return "Test QZ";
    }

    function symbol() public pure override returns (string memory) {
        return "tQZ";
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == _factory && !locked, "locked");
        _mint(to, amount);
    }

    function lock() external {
        require(msg.sender == _factory, "factory");
        locked = true;
    }
}

/// @title MOCK_PonsCurve (TESTNET ONLY)
/// @notice MOCK of a Pons v2 per-launch bonding curve for an ETH pair: constant product on virtual reserves.
///         Buy: fee and creator tax come off the ETH input. Sell: they come off the ETH output.
///         Fees accrue in `quoteFeeBalance` (base fee) and `creatorTaxBalance` (tax) until `sweepFees`.
contract MOCK_PonsCurve {
    uint256 public constant INITIAL_TOKEN_RESERVE = 1_000_000_000 ether;
    uint256 public constant VIRTUAL_QUOTE = 1 ether;
    uint256 public constant BPS = 10_000;
    uint256 public constant feeBps = 100;
    uint256 public constant creatorTaxBps = 200;
    uint256 public constant PROTOCOL_FEE_SHARE_BPS = 3000;

    MOCK_QZTestToken public immutable token;
    MOCK_PonsFeeEscrow public immutable escrow;
    address public immutable factory;
    address public immutable protocolFeeRecipient;
    address public immutable sweepOperator;
    address public creatorFeeRecipient;

    uint256 public quoteReserve = VIRTUAL_QUOTE;
    uint256 public tokenReserve = INITIAL_TOKEN_RESERVE;
    uint256 public quoteFeeBalance;
    uint256 public creatorTaxBalance;
    bool public graduated;
    bool private _locked;

    event Buy(address indexed buyer, uint256 quoteIn, uint256 tokensOut);
    event Sell(address indexed seller, uint256 tokensIn, uint256 quoteOut);
    event FeesSwept(uint256 protocolAmount, uint256 creatorAmount);

    error NotFeeSweepOperator();
    error Graduated();
    error ZeroAmount();
    error Slippage(uint256 min, uint256 actual);
    error Reentrancy();
    error TransferFailed();

    constructor(
        MOCK_QZTestToken token_,
        MOCK_PonsFeeEscrow escrow_,
        address creatorFeeRecipient_,
        address protocolFeeRecipient_,
        address sweepOperator_
    ) {
        token = token_;
        escrow = escrow_;
        factory = msg.sender;
        creatorFeeRecipient = creatorFeeRecipient_;
        protocolFeeRecipient = protocolFeeRecipient_;
        sweepOperator = sweepOperator_;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    function markGraduated() external {
        require(msg.sender == factory, "factory");
        graduated = true;
    }

    // ───────────── trading ─────────────

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (graduated) revert Graduated();
        if (quoteIn == 0 || msg.value != quoteIn) revert ZeroAmount();
        uint256 fee = quoteIn * feeBps / BPS;
        uint256 tax = quoteIn * creatorTaxBps / BPS;
        uint256 net = quoteIn - fee - tax;
        tokensOut = net * tokenReserve / (quoteReserve + net);
        if (tokensOut < minTokensOut) revert Slippage(minTokensOut, tokensOut);
        quoteReserve += net;
        tokenReserve -= tokensOut;
        quoteFeeBalance += fee;
        creatorTaxBalance += tax;
        token.transfer(recipient, tokensOut);
        emit Buy(msg.sender, quoteIn, tokensOut);
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (graduated) revert Graduated();
        if (tokensIn == 0) revert ZeroAmount();
        uint256 gross = tokensIn * quoteReserve / (tokenReserve + tokensIn);
        uint256 fee = gross * feeBps / BPS;
        uint256 tax = gross * creatorTaxBps / BPS;
        quoteOut = gross - fee - tax;
        if (quoteOut < minQuoteOut) revert Slippage(minQuoteOut, quoteOut);
        token.transferFrom(msg.sender, address(this), tokensIn);
        quoteReserve -= gross;
        tokenReserve += tokensIn;
        quoteFeeBalance += fee;
        creatorTaxBalance += tax;
        (bool ok,) = recipient.call{value: quoteOut}("");
        if (!ok) revert TransferFailed();
        emit Sell(msg.sender, tokensIn, quoteOut);
    }

    // ───────────── fee sweep (same signature and caller rule as Pons) ─────────────

    /// @notice Credit the accrued fee to the escrow: protocol 30% of the base fee, creator 70% of the base fee plus the
    ///         whole creator tax. A no-op when nothing accrued. The mock has no buyback, so `minBuybackTokensOut` is ignored.
    function sweepFees(uint256) external nonReentrant {
        if (msg.sender != sweepOperator && msg.sender != creatorFeeRecipient) revert NotFeeSweepOperator();
        uint256 fee = quoteFeeBalance;
        uint256 tax = creatorTaxBalance;
        if (fee == 0 && tax == 0) return;
        quoteFeeBalance = 0;
        creatorTaxBalance = 0;
        uint256 protocolAmount = fee * PROTOCOL_FEE_SHARE_BPS / BPS;
        uint256 creatorAmount = fee - protocolAmount + tax;
        if (protocolAmount != 0) escrow.credit{value: protocolAmount}(protocolFeeRecipient);
        if (creatorAmount != 0) escrow.credit{value: creatorAmount}(creatorFeeRecipient);
        emit FeesSwept(protocolAmount, creatorAmount);
    }

    /// @notice ETH of a quote of `tokensIn` sold now, net of fees (view helper for tests).
    function quoteSell(uint256 tokensIn) external view returns (uint256) {
        uint256 gross = tokensIn * quoteReserve / (tokenReserve + tokensIn);
        return gross - gross * feeBps / BPS - gross * creatorTaxBps / BPS;
    }
}

/// @title MOCK_PonsHook (TESTNET ONLY)
/// @notice MOCK of the Pons `MemeHook` post-graduation sweep. `accrue` stands in for a swap fee in ETH reaching the
///         hook. `setNeedsOperator(true)` models pending memecoin-denominated fees: then only the operator may sweep
///         (the creator gets `InternalSwapRequiresOperator`, as on Pons).
contract MOCK_PonsHook {
    MOCK_PonsFeeEscrow public immutable escrow;
    address public immutable creator;
    address public immutable protocolFeeRecipient;
    address public immutable feeSweepOperator;
    address public immutable factory;

    mapping(bytes32 => bool) public registered;
    mapping(bytes32 => uint256) public pendingFees;
    mapping(bytes32 => uint256) public pendingCreatorTax;
    bool public needsOperator;

    error UnknownPool();
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();

    constructor(MOCK_PonsFeeEscrow escrow_, address creator_, address protocolFeeRecipient_, address operator_) {
        escrow = escrow_;
        creator = creator_;
        protocolFeeRecipient = protocolFeeRecipient_;
        feeSweepOperator = operator_;
        factory = msg.sender;
    }

    function register(bytes32 poolId) external {
        require(msg.sender == factory, "factory");
        registered[poolId] = true;
    }

    /// @notice Test helper: a swap fee (`fee`) and creator tax (`tax`) in ETH arrive for `poolId`.
    function accrue(bytes32 poolId, uint256 tax) external payable {
        require(registered[poolId] && tax <= msg.value, "bad");
        pendingFees[poolId] += msg.value - tax;
        pendingCreatorTax[poolId] += tax;
    }

    function setNeedsOperator(bool v) external {
        needsOperator = v;
    }

    function sweepPoolFees(bytes32 poolId, uint256, uint256) external {
        if (!registered[poolId]) revert UnknownPool();
        bool isOperator = msg.sender == feeSweepOperator;
        if (!isOperator && msg.sender != creator) revert NotFeeSweepOperator();
        if (!isOperator && needsOperator) revert InternalSwapRequiresOperator();
        uint256 fee = pendingFees[poolId];
        uint256 tax = pendingCreatorTax[poolId];
        if (fee == 0 && tax == 0) return;
        pendingFees[poolId] = 0;
        pendingCreatorTax[poolId] = 0;
        uint256 protocolAmount = fee * 3000 / 10_000;
        uint256 creatorAmount = fee - protocolAmount + tax;
        if (protocolAmount != 0) escrow.credit{value: protocolAmount}(protocolFeeRecipient);
        if (creatorAmount != 0) escrow.credit{value: creatorAmount}(creator);
    }
}
