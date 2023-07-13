// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "src/Kernel.sol";
import "src/launch_contracts/MasterChef.sol";
import {esRADT} from "src/policies/esRADT.sol";

contract DeployTresasury is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        // address deployer = vm.addr(deployerPrivateKey);
        rdLPstaking staking = new rdLPstaking(
            3306878310000,
            3306878310000,
            3306878310000
        );
        esRADT esradt = esRADT(0xDee7ED1e10F1956E23EE2df2908101B39bB6808f);
        console2.log("New rdLP staking address: ", address(staking));
        esradt.whitelistAddress(address(staking), true); //wl staking

        vm.stopBroadcast();
    }
}
