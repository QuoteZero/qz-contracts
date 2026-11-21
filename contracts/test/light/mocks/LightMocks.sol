// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {QZForge} from "../../../src/light/QZForge.sol";

/// @dev Plain 18 decimals token with a public mint: the stand-in for the Pons launch token.
contract MockQZ is ERC20 {
    constructor() ERC20("QuoteZero", "QZ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Takes `feeBps` of every transfer and burns it (a deflationary or fee-on-transfer token).
contract FeeToken is ERC20 {
    uint256 public feeBps;

    constructor(uint256 feeBps_) ERC20("Fee", "FEE") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        super._update(address(0), to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = amount * feeBps / 10_000;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

/// @dev Credits the receiver `bonus` extra units on every transfer (a rebasing or bonus token).
contract BonusToken is ERC20 {
    uint256 public bonus;

    constructor(uint256 bonus_) ERC20("Bonus", "BNS") {
        bonus = bonus_;
    }

    function mint(address to, uint256 amount) external {
        super._update(address(0), to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && to != address(0) && bonus != 0) super._update(address(0), to, bonus);
    }
}

/// @dev Calls back into `QZForge.light(reenterId)` once, in the middle of `transferFrom`. The re-entering caller is this
///      token, and `reenterId` is owned by this token, so only the forge's reentrancy lock stands in the way.
contract ReentrantToken is ERC20 {
    QZForge public target;
    uint256 public reenterId;
    bool public armed;
    bool public bubble;
    bool public reentered;
    bytes4 public lastRevert;

    constructor() ERC20("Reenter", "RNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(QZForge target_, uint256 reenterId_, bool bubble_) external {
        target = target_;
        reenterId = reenterId_;
        bubble = bubble_;
        armed = true;
        _approve(address(this), address(target_), type(uint256).max);
        _mint(address(this), 1_000_000e18);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            try target.light(reenterId) {
                reentered = true;
            } catch (bytes memory reason) {
                lastRevert = bytes4(reason);
                if (bubble) {
                    assembly {
                        revert(add(reason, 32), mload(reason))
                    }
                }
            }
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev The part of QZMachine the forge reads: `ownerOf` and `revealed`.
contract MockMachine is ERC721 {
    bool public revealed;

    constructor() ERC721("Machine", "QZM") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setRevealed(bool value) external {
        revealed = value;
    }
}

/// @dev The part of QZRewardVault the forge calls. `register` only accepts the forge, once per id.
contract MockVault {
    error NotForge(address caller);
    error AlreadyEnrolled(uint256 id);
    error Boom();

    address public immutable forge;
    mapping(uint256 => bool) public isEnrolled;
    uint256 public registered;
    bool public failNext;
    uint256 public reenterId;
    bytes4 public lastRevert;

    constructor(address forge_) {
        forge = forge_;
    }

    function setFailNext(bool value) external {
        failNext = value;
    }

    function setReenter(uint256 id) external {
        reenterId = id;
    }

    function register(uint256 id) external {
        if (msg.sender != forge) revert NotForge(msg.sender);
        if (failNext) revert Boom();
        if (isEnrolled[id]) revert AlreadyEnrolled(id);
        if (reenterId != 0) {
            try QZForge(forge).light(reenterId) {}
            catch (bytes memory reason) {
                lastRevert = bytes4(reason);
            }
        }
        isEnrolled[id] = true;
        ++registered;
    }
}
