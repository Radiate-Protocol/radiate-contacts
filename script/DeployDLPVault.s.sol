// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../src/policies/DLPVault_Audit.sol";
import "../test/src/AddressProvider.sol";

// forge script DeployDLPVault --rpc-url $ARBITRUM_RPC_URL --broadcast --verify -slow -vv
// forge script DeployDLPVault --rpc-url $ARBITRUM_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --skip-simulation --slow -vvvv
contract DeployDLPVault is Script, AddressProvider {
    // Deploy config
    address constant proxyAdmin = 0xEA871D39057E94691FA7323042CC015601eA4AF2;
    address constant kernel = 0x6d37F6eeDc9ED384E56C67827001901F9Af2EA5F;

    // DLP vault config
    uint256 public depositFee = 0;
    uint256 public withdrawFee = 0;
    uint256 public compoundFee = 300;
    uint256 public vaultCap = 100000 ether;

    function run() public {
        console2.log("Broadcast sender", msg.sender);
        console2.log("Proxy Admin", proxyAdmin);

        vm.startBroadcast();

        address impl = address(new DLPVault());
        address proxy = address(
            new TransparentUpgradeableProxy(
                impl,
                proxyAdmin,
                abi.encodeWithSignature("initialize(address)", kernel)
            )
        );

        {
            DLPVault dlpVault = DLPVault(payable(proxy));

            dlpVault.configureDependencies();
            dlpVault.setFee(depositFee, withdrawFee, compoundFee);
            dlpVault.setVaultCap(vaultCap);

            address[] memory rewardBaseTokens = new address[](7);
            rewardBaseTokens[0] = rWBTC;
            rewardBaseTokens[1] = rUSDT;
            rewardBaseTokens[2] = rUSDC;
            rewardBaseTokens[3] = rDAI;
            rewardBaseTokens[4] = rARB;
            rewardBaseTokens[5] = rwstETH;
            rewardBaseTokens[6] = rWETH;

            bool[] memory isATokens = new bool[](7);
            isATokens[0] = true;
            isATokens[1] = true;
            isATokens[2] = true;
            isATokens[3] = true;
            isATokens[4] = true;
            isATokens[5] = true;
            isATokens[6] = true;

            uint24[] memory poolFees = new uint24[](7);
            poolFees[0] = WBTC_POOL_FEE;
            poolFees[1] = USDT_POOL_FEE;
            poolFees[2] = USDC_POOL_FEE;
            poolFees[3] = DAI_POOL_FEE;
            poolFees[4] = ARB_POOL_FEE;
            poolFees[5] = WSTETH_POOL_FEE;
            poolFees[6] = 0;

            uint256[] memory swapThresholds = new uint256[](7);
            swapThresholds[0] = WBTC_SWAP_THRESHOLD;
            swapThresholds[1] = USDT_SWAP_THRESHOLD;
            swapThresholds[2] = USDC_SWAP_THRESHOLD;
            swapThresholds[3] = DAI_SWAP_THRESHOLD;
            swapThresholds[4] = ARB_SWAP_THRESHOLD;
            swapThresholds[5] = WSTETH_SWAP_THRESHOLD;
            swapThresholds[6] = WETH_SWAP_THRESHOLD;

            dlpVault.addRewardBaseTokens(
                rewardBaseTokens,
                isATokens,
                poolFees,
                swapThresholds
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

            string memory filename = "./json/dlpVault.json";
            vm.writeJson(json, filename);
        }
    }
}
