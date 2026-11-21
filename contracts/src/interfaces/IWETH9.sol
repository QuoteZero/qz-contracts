// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IWETH9
/// @notice The wrapped-ether functions the protocol calls: wrap, unwrap, and the ERC-20 transfer surface.
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}
