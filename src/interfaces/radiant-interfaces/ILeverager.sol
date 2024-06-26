// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.15;
pragma experimental ABIEncoderV2;

interface ILeverager {
    function wethToZap(address user) external view returns (uint256);

    function zapWETHWithBorrow(uint256 amount, address borrower) external returns (uint256 liquidity);

    function zapWETHWithBorrow(uint256 amount, address borrower, address onBehalfOf)
        external
        returns (uint256 liquidity);
}
