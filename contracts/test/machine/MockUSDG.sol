// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice USDG stand-in: 6 decimals, a global pause, a blocklist, and two misbehaviours a hostile or odd token could
///         show (a transfer that returns false, a transfer that burns a fee).
contract MockUSDG is ERC20 {
    bool public paused;
    bool public returnFalse;
    bool public returnFalseAfterMove;
    uint256 public feeBps;
    mapping(address => bool) public blocked;

    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool v) external {
        paused = v;
    }

    function setBlocked(address a, bool v) external {
        blocked[a] = v;
    }

    function setReturnFalse(bool v) external {
        returnFalse = v;
    }

    /// @dev The transfer happens, then `transferFrom` answers `false` (a token that moves funds and lies).
    function setReturnFalseAfterMove(bool v) external {
        returnFalseAfterMove = v;
    }

    function setFeeBps(uint256 v) external {
        feeBps = v;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        bool ok = super.transferFrom(from, to, value);
        return ok && !returnFalseAfterMove;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "USDG: paused");
        require(!blocked[from] && !blocked[to], "USDG: blocked");
        uint256 fee = from != address(0) && to != address(0) ? value * feeBps / 10_000 : 0;
        super._update(from, to, value - fee);
        if (fee != 0) super._update(from, address(0), fee);
    }
}
