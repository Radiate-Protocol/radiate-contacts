// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../src/policies/DLPVault_Audit.sol";
import "../test/src/AddressProvider.sol";

// forge script UpgradeBetaDLPVault --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --skip-simulation --slow -vvvv
contract UpgradeBetaDLPVault is Script, AddressProvider {
    // Deploy config
    address constant proxyAdmin = 0xEA871D39057E94691FA7323042CC015601eA4AF2;
    address constant proxy = 0x03d2401A93B32eF74C5c2cf7764391003a28229c;

    function run() public {
        console2.log("Broadcast sender", msg.sender);
        console2.log("Proxy Admin", proxyAdmin);

        vm.startBroadcast();

        // Beta DLPVault
        address impl = address(new DLPVault());
        ProxyAdmin(proxyAdmin).upgrade(
            ITransparentUpgradeableProxy(proxy),
            impl
        );

        vm.stopBroadcast();

        console2.log("Impl", impl);
        console2.log("Proxy", proxy);

        console2.log("\n");

        {
            string memory objName = "upgrade";
            string memory json;
            json = vm.serializeAddress(objName, "admin", proxyAdmin);
            json = vm.serializeAddress(objName, "impl", impl);
            json = vm.serializeAddress(objName, "proxy", proxy);

            string memory filename = "./json/beta_dlpVault.json";
            vm.writeJson(json, filename);
        }
    }
}
