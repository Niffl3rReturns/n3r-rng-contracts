// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.6;

interface RNGInterface {
  event RandomNumberRequested(uint256 indexed id, address indexed sender, address token, uint256 budget);
  event RandomNumberCompleted(uint256 indexed id, uint256 randomNumber);

  function requestRandomNumber(uint256 seed, address token, uint256 budget) external returns (uint256);
  function isRequestComplete(uint256 id) external view returns (bool);
  function randomNumber(uint256 id) external view returns (uint256);
}