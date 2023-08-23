// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../src/policies/DLPVault_Audit.sol";
import "../src/policies/Leverager_Audit.sol";
import "../src/interfaces/radiant-interfaces/ICreditDelegationToken.sol";
import "../test/mocks/MockRewardDistributor.sol";
import "../test/src/AddressProvider.sol";

// forge script DeployLeverager --rpc-url $ARBITRUM_RPC_URL --broadcast --verify -slow -vv
// forge script DeployLeverager --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --skip-simulation --slow -vvvv
contract DeployLeverager is Script, AddressProvider {
    // Deploy config
    address constant proxyAdmin = 0xEA871D39057E94691FA7323042CC015601eA4AF2;
    address constant kernel = 0xD85317aA40c4258318Dc7EdE5491B38e92F41ddb;
    address constant dlpVault = 0x03d2401A93B32eF74C5c2cf7764391003a28229c;

    // Leverager config
    uint256 public fee = 5e5;
    uint256 public borrowRatio = 6e5;

    function run() public {
        console2.log("Broadcast sender", msg.sender);
        console2.log("Proxy Admin", proxyAdmin);

        vm.startBroadcast();

        // Reward Distributor
        MockRewardDistributor distributor = new MockRewardDistributor();
        console2.log("Reward Distributor", address(distributor));

        // USDC Leverager
        address impl = address(new Leverager());
        address proxy = address(
            new TransparentUpgradeableProxy(
                impl,
                proxyAdmin,
                abi.encodeWithSignature(
                    "initialize(address,address,address,address,uint256,uint256)",
                    kernel,
                    dlpVault,
                    USDC,
                    address(distributor),
                    fee,
                    borrowRatio
                )
            )
        );

        // DLPVault & Leverager Config
        {
            Leverager leverager = Leverager(payable(proxy));

            leverager.configureDependencies();

            DLPVault(payable(dlpVault)).enableCreditDelegation(
                ICreditDelegationToken(leverager.getVDebtToken()),
                address(leverager)
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

            string memory filename = "./json/leverager_usdc.json";
            vm.writeJson(json, filename);
        }
    }
}
