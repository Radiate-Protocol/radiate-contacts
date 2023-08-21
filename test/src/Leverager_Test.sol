// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Leverager, IERC20} from "../../src/policies/Leverager_Audit.sol";

contract Leverager_Test is Leverager {
    function loop(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        _loop(amount);
    }
}
