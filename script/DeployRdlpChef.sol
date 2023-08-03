// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import "../src/policies/rdLPChef.sol";

contract DeployRdlpChef is Script {
    function run() public {
        console2.log("Broadcast sender", msg.sender);

        // address rdlp = 0x3361d69366B35e8E432182b70612761b709B3378;
        address rdlp = 0xC6dC7749781F7Ba1e9424704B2904f2F94D3eb63;

        vm.startBroadcast();

        address chef = address(new rdLPstaking(1000000000000000, 10000000000000, block.timestamp + 1));

        rdLPstaking(chef).add(100, IERC20(rdlp));

        vm.stopBroadcast();

        console2.log("chef", chef);
        console2.log("\n");
    }
}
