// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../src/policies/DLPVault.sol";
import "../src/modules/ROLES/OlympusRoles.sol";
import "../src/policies/RolesAdmin.sol";

// kernel: 0x6d37F6eeDc9ED384E56C67827001901F9Af2EA5F
// roles admin: 0xFE90B26da4F7ac65a4687f2E7c8fd10FB23b0623

// forge script RunDLPVault --rpc-url $ARBITRUM_RPC_URL --broadcast --verify -slow -vv
// forge script RunDLPVault --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --skip-simulation --slow -vvvv
contract RunDLPVault is Script {
    // Deploy config
    function run() public {
        console2.log("Broadcast sender", msg.sender);

        // Kernel kernel = Kernel(0xD85317aA40c4258318Dc7EdE5491B38e92F41ddb);
        DLPVault vault = DLPVault(0x09E1C5d000C9E12db9b349662aAc6c9E2ACfa7f6);

        vm.startBroadcast();

        // RolesAdmin admin = new RolesAdmin(kernel);
        // kernel.executeAction(Actions.ActivatePolicy, address(admin));

        // admin.grantRole("admin", msg.sender);
        // vault.setVaultCap(100000000000000000000000000000);
        vault.setDepositFee(100);

        vm.stopBroadcast();
        // console2.log("admin", address(admin));
    }
}
