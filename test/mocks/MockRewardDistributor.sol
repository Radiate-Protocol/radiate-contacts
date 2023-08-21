// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRewardDistributor} from "../../src/interfaces/radiate/IRewardDistributor.sol";

contract MockRewardDistributor is IRewardDistributor {
    function receiveReward(address _asset, uint256 _amount) external override {
        IERC20(_asset).transferFrom(msg.sender, address(this), _amount);
    }
}
