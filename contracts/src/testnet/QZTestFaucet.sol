// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title QZTestFaucet (TESTNET ONLY)
/// @notice Hands out the test $QZ of the Robinhood Chain testnet (46630). It is never deployed to, and refuses to be
///         created on, Robinhood Chain mainnet (4663). Nothing in `src/` outside `src/testnet/` references it.
///
///         One relayer (the worker's wallet, fixed at deploy) calls `claim(to)` after the website has checked a Turnstile
///         challenge for the visitor. The contract itself enforces the rules, so a leaked relayer key is bounded:
///           - `AMOUNT` (200,000 test $QZ) per claim, sent from this contract's own balance;
///           - one claim per recipient per `COOLDOWN` (24 h), `Cooldown(nextClaimAt)` otherwise;
///           - at most `DAILY_CAP` claims per UTC day over all recipients, `DailyCapReached()` otherwise.
///         The owner can pause claims and take leftover test $QZ back; there is no other admin power.
contract QZTestFaucet {
    using SafeERC20 for IERC20;

    uint256 internal constant MAINNET_CHAIN_ID = 4663;

    /// @notice Test $QZ sent per claim: enough for one machine's price (at most 100,000) plus the 100,000 the forge locks.
    uint256 public constant AMOUNT = 200_000e18;
    /// @notice Seconds a recipient waits between two claims.
    uint256 public constant COOLDOWN = 1 days;
    /// @notice Claims over all recipients per UTC day.
    uint256 public constant DAILY_CAP = 500;

    IERC20 public immutable token;
    /// @notice The only address that may call `claim`.
    address public immutable relayer;
    /// @notice May pause, unpause and withdraw leftover test $QZ. Nothing else.
    address public immutable owner;

    bool public paused;
    mapping(address => uint256) private _lastClaimAt;
    mapping(uint256 => uint256) private _claimsOnDay;

    /// @param nextClaimAt the earliest time `to` can claim again
    event Claimed(address indexed to, uint256 amount, uint256 nextClaimAt);
    event Paused(bool paused);
    event Withdrawn(address indexed to, uint256 amount);

    error NotRelayer();
    error NotOwner();
    error ClaimsPaused();
    error ZeroAddress();
    error WrongChain();
    /// @param nextClaimAt when `to` may claim again (unix seconds)
    error Cooldown(uint256 nextClaimAt);
    error DailyCapReached();

    constructor(IERC20 token_, address relayer_, address owner_) {
        if (block.chainid == MAINNET_CHAIN_ID) revert WrongChain();
        if (address(token_) == address(0) || relayer_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        token = token_;
        relayer = relayer_;
        owner = owner_;
    }

    /// @notice Send `AMOUNT` test $QZ to `to`. Relayer only.
    function claim(address to) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (paused) revert ClaimsPaused();
        if (to == address(0)) revert ZeroAddress();
        uint256 nextAt = nextClaimAt(to);
        if (nextAt != 0) revert Cooldown(nextAt);
        uint256 day = block.timestamp / 1 days;
        if (_claimsOnDay[day] >= DAILY_CAP) revert DailyCapReached();
        _claimsOnDay[day] += 1;
        _lastClaimAt[to] = block.timestamp;
        emit Claimed(to, AMOUNT, block.timestamp + COOLDOWN);
        token.safeTransfer(to, AMOUNT);
    }

    /// @notice 0 when `who` can claim now, else the unix time the cooldown ends.
    function nextClaimAt(address who) public view returns (uint256) {
        uint256 last = _lastClaimAt[who];
        if (last == 0) return 0;
        uint256 end = last + COOLDOWN;
        return block.timestamp < end ? end : 0;
    }

    /// @notice Claims paid so far in the current UTC day.
    function claimedToday() public view returns (uint256) {
        return _claimsOnDay[block.timestamp / 1 days];
    }

    /// @notice Claims left today before `DailyCapReached`.
    function dailyCapRemaining() external view returns (uint256) {
        uint256 used = claimedToday();
        return used >= DAILY_CAP ? 0 : DAILY_CAP - used;
    }

    /// @notice The unix time of the next UTC midnight, when the daily count restarts.
    function nextResetAt() external view returns (uint256) {
        return (block.timestamp / 1 days + 1) * 1 days;
    }

    // ───────────── owner ─────────────

    function setPaused(bool value) external {
        if (msg.sender != owner) revert NotOwner();
        paused = value;
        emit Paused(value);
    }

    /// @notice Take `amount` of the faucet's test $QZ back to the owner.
    function withdraw(uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        emit Withdrawn(owner, amount);
        token.safeTransfer(owner, amount);
    }
}
