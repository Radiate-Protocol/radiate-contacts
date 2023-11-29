// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.15;

/**
 * @title IAaveOracle interface
 * @notice Interface for the Aave oracle.
 *
 */

interface IAaveOracle {
    function BASE_CURRENCY() external view returns (address); // if usd returns 0x0, if eth returns weth address

    function BASE_CURRENCY_UNIT() external view returns (uint256);

    function owner() external view returns (address);
    
    /**
     *
     * @dev returns the asset price in ETH
     */
    function getAssetPrice(address asset) external view returns (uint256);

    function getSourceOfAsset(address asset) external view returns (address);

    function setAssetSources(
        address[] calldata assets,
        address[] calldata sources
    ) external;
}
