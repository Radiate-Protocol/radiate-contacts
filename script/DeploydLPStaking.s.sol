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
        // address deployer = vm.addr(deployerPrivateKey);
        rdLPstaking staking = new rdLPstaking(
            350000000000000, // 30 tokens a day
            350000000000000,
            block.timestamp
        );
        esRADT esradt = esRADT(0xDee7ED1e10F1956E23EE2df2908101B39bB6808f);
        console2.log("New rdLP staking address: ", address(staking));
        esradt.whitelistAddress(address(staking), true); //wl staking
        staking.add(4000, IERC20(0xC6dC7749781F7Ba1e9424704B2904f2F94D3eb63)); //add rdLP
        // enable rewards later
        vm.stopBroadcast();
    }
}
