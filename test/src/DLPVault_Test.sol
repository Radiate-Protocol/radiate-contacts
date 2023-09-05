// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {DLPVault, IERC20} from "../../src/policies/DLPVault_Audit.sol";

contract DLPVault_Test is DLPVault {
    function swapToWETH() external {
        uint256 length = rewards.length;

        for (uint256 i = 0; i < length; ) {
            RewardInfo storage reward = rewards[i];
            uint256 harvested = IERC20(reward.token).balanceOf(address(this));
            reward.pending = harvested;

            _swapToWETH(reward);

            unchecked {
                ++i;
            }
        }
    }

    function joinPool() external {
        _joinPool();
    }

    function stakeDLP() external {
        _stakeDLP();
    }
}
