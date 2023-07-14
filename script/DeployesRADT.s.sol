// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "src/Kernel.sol";
import "src/launch_contracts/MasterChef.sol";
import {esRADT} from "src/policies/esRADT.sol";

contract DeployStaking is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        esRADT esradt = new esRADT();
        console2.log("New esradt address: ", address(esradt));
        esradt.whitelistAddress(0x94b23c2233BC7c9Fe75B22950335d7F792b00E8e, true); //wl msig
        esradt.whitelistAddress(0xa50FC8Fc0b7845b07DCD00ef6bdE46E5160E3835, true); //wl deployer

        // address deployer = vm.addr(deployerPrivateKey);
        rdLPstaking staking = new rdLPstaking(
            350000000000000, // 30 tokens a day
            350000000000000,
            block.timestamp,
            IERC20(address(esradt))
        );
        console2.log("New rdLP staking address: ", address(staking));
        esradt.whitelistAddress(address(staking), true); //wl staking
        staking.add(4000, IERC20(0xC6dC7749781F7Ba1e9424704B2904f2F94D3eb63)); //add rdLP
        // enable rewards later
        vm.stopBroadcast();
    }
}
