// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../src/policies/MasterChef.sol";
import "../src/policies/Leverager_Audit.sol";
import "../test/src/AddressProvider.sol";

// forge script DeployMasterChef.s --rpc-url $ARBITRUM_RPC_URL --broadcast --verify -slow -vv
// forge script DeployMasterChef.s --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --skip-simulation --slow -vvvv
contract DeployMasterChef is Script, AddressProvider {
    // Deploy config
    address constant proxyAdmin = 0xEA871D39057E94691FA7323042CC015601eA4AF2;
    address constant kernel = 0xD85317aA40c4258318Dc7EdE5491B38e92F41ddb;
    address constant dlpVault = 0x03d2401A93B32eF74C5c2cf7764391003a28229c;
    address constant leverager = 0x9473BED72F387Ee6f342996F970b27285283464f;

    // MasterChef config
    uint256 public dlpAllocPoint = 1000;

    function run() public {
        console2.log("Broadcast sender", msg.sender);
        console2.log("Proxy Admin", proxyAdmin);

        vm.startBroadcast();

        // MasterChef
        address impl = address(new MasterChef());
        address proxy = address(
            new TransparentUpgradeableProxy(
                impl,
                proxyAdmin,
                abi.encodeWithSignature(
                    "initialize(address,address)",
                    kernel,
                    RDNT
                )
            )
        );

        // MasterChef & Leverager Config
        {
            MasterChef masterChef = MasterChef(proxy);

            masterChef.configureDependencies();
            masterChef.add(dlpAllocPoint, IERC20(dlpVault));

            Leverager(payable(leverager)).setRewardDistributor(
                IRewardDistributor(proxy)
            );
        }

        vm.stopBroadcast();

        console2.log("Impl", impl);
        console2.log("Proxy", proxy);

        console2.log("\n");

        {
            string memory objName = "deploy";
            string memory json;
            json = vm.serializeAddress(objName, "admin", proxyAdmin);
            json = vm.serializeAddress(objName, "impl", impl);
            json = vm.serializeAddress(objName, "proxy", proxy);

            string memory filename = "./json/masterchef.json";
            vm.writeJson(json, filename);
        }
    }
}
