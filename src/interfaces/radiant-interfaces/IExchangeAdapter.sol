// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IExchangeAdapter {
    event Exchange(
        address indexed from, address indexed to, address indexed platform, uint256 fromAmount, uint256 toAmount
    );

    function approveExchange(IERC20[] calldata tokens) external;

    function exchange(address from, address to, uint256 amount, uint256 maxSlippage) external returns (uint256);
}
