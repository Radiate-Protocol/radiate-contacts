// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Treasury} from "../src/modules/TRSRY/TRSRY.sol";
import {OlympusRoles} from "../src/modules/ROLES/OlympusRoles.sol";
import {RolesAdmin} from "../src/policies/RolesAdmin.sol";
import {Kernel, Actions} from "../src/Kernel.sol";
import {DLPVault} from "../src/policies/DLPVault_Audit.sol";

import {ILendingPool} from "../src/interfaces/radiant-interfaces/ILendingPool.sol";
import {IFeeDistribution} from "../src/interfaces/radiant-interfaces/IFeeDistribution.sol";
import {IMultiFeeDistribution, LockedBalance} from "../src/interfaces/radiant-interfaces/IMultiFeeDistribution.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {UserFactory} from "./lib/UserFactory.sol";
import {AddressProvider} from "./src/AddressProvider.sol";
import {DLPVault_Test} from "./src/DLPVault_Test.sol";

contract DLPVaultTest is Test, AddressProvider {
    Kernel public kernel;
    OlympusRoles public roles;
    RolesAdmin public admin;
    Treasury public treasury;
    DLPVault_Test public dlpVault;

    ILendingPool public lendingPool;
    IMultiFeeDistribution public mfd;

    uint256 public depositFee = 100;
    uint256 public withdrawFee = 200;
    uint256 public compoundFee = 300;
    uint256 public multiplier = 1e6;

    uint256 public vaultCap = 100000 ether;

    address public alice;
    address public bob;
    address public carol;

    function setUp() public {
        // Proxy Admin
        address proxyAdmin = address(new ProxyAdmin());

        // Kernel
        kernel = new Kernel();
        roles = new OlympusRoles(kernel);
        admin = new RolesAdmin(kernel);
        treasury = new Treasury(kernel);

        kernel.executeAction(Actions.InstallModule, address(roles));
        kernel.executeAction(Actions.InstallModule, address(treasury));
        kernel.executeAction(Actions.ActivatePolicy, address(admin));

        admin.grantRole("admin", address(this));

        // DLPVault
        address impl = address(new DLPVault_Test());
        address proxy = address(
            new TransparentUpgradeableProxy(
                impl,
                proxyAdmin,
                abi.encodeWithSignature("initialize(address)", kernel)
            )
        );
        dlpVault = DLPVault_Test(payable(proxy));
        dlpVault.configureDependencies();

        {
            lendingPool = ILendingPool(dlpVault.LENDING_POOL());
            mfd = IMultiFeeDistribution(dlpVault.MFD());
        }
        {
            dlpVault.setFee(depositFee, withdrawFee, compoundFee);
            dlpVault.setVaultCap(vaultCap);
        }
        {
            address[] memory rewardBaseTokens = new address[](5);
            rewardBaseTokens[0] = rWBTC;
            rewardBaseTokens[1] = rUSDT;
            rewardBaseTokens[2] = rUSDC;
            rewardBaseTokens[3] = rDAI;
            rewardBaseTokens[4] = rWETH;

            bool[] memory isATokens = new bool[](5);
            isATokens[0] = true;
            isATokens[1] = true;
            isATokens[2] = true;
            isATokens[3] = true;
            isATokens[4] = true;

            uint24[] memory poolFees = new uint24[](5);
            poolFees[0] = WBTC_POOL_FEE;
            poolFees[1] = USDT_POOL_FEE;
            poolFees[2] = USDC_POOL_FEE;
            poolFees[3] = DAI_POOL_FEE;
            poolFees[4] = 0;

            dlpVault.addRewardBaseTokens(rewardBaseTokens, isATokens, poolFees);
        }

        // User
        UserFactory userCreator = new UserFactory();
        {
            address[] memory users = userCreator.create(3);
            alice = users[0];
            bob = users[1];
            carol = users[2];
        }
        {
            vm.startPrank(DLP_HOLDER);
            ERC20(DLP).transfer(alice, 1000 ether);
            ERC20(DLP).transfer(bob, 1000 ether);
            vm.stopPrank();

            vm.startPrank(USDC_HOLDER);
            ERC20(USDC).transfer(alice, 1000 gwei);
            vm.stopPrank();

            vm.startPrank(USDT_HOLDER);
            ERC20(USDT).transfer(alice, 1000 gwei);
            vm.stopPrank();

            vm.startPrank(WBTC_HOLDER);
            ERC20(WBTC).transfer(alice, 300 gwei);
            vm.stopPrank();

            vm.startPrank(DAI_HOLDER);
            ERC20(DAI).transfer(alice, 1000 ether);
            vm.stopPrank();

            vm.startPrank(WETH_HOLDER);
            ERC20(WETH).transfer(alice, 2000 ether);
            vm.stopPrank();

            vm.startPrank(alice);
            ERC20(WETH).approve(address(lendingPool), type(uint256).max);
            lendingPool.deposit(WETH, 2000 ether, alice, 0);
            ERC20(WBTC).approve(address(lendingPool), type(uint256).max);
            lendingPool.deposit(WBTC, 15 gwei, alice, 0);
            ERC20(USDT).approve(address(lendingPool), type(uint256).max);
            lendingPool.deposit(USDT, 500 gwei, alice, 0);
            vm.stopPrank();
        }
    }

    function _borrowAndRepay() internal {
        vm.startPrank(alice);
        lendingPool.borrow(WETH, 100 ether, 2, 0, alice);
        lendingPool.borrow(USDC, 100 gwei, 2, 0, alice);
        lendingPool.borrow(USDT, 100 gwei, 2, 0, alice);
        lendingPool.borrow(DAI, 100 ether, 2, 0, alice);
        lendingPool.borrow(WBTC, 10 gwei, 2, 0, alice);

        lendingPool.repay(WETH, 101 ether, 2, alice);
        ERC20(USDC).approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(USDC, 110 gwei, 2, alice);
        ERC20(USDT).approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(USDT, 110 gwei, 2, alice);
        ERC20(DAI).approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(DAI, 110 ether, 2, alice);
        ERC20(WBTC).approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(WBTC, 11 gwei, 2, alice);
        vm.stopPrank();
    }

    function testName() public {
        assertEq(dlpVault.name(), "Radiate DLP Vault");
    }

    function testSymbol() public {
        assertEq(dlpVault.symbol(), "RADT-DLP");
    }

    function testTreasury() public {
        assertEq(dlpVault.treasury(), address(treasury));
    }

    function testFee() public {
        (
            uint256 depositFee_,
            uint256 withdrawFee_,
            uint256 compoundFee_
        ) = dlpVault.fee();

        assertEq(depositFee_, depositFee);
        assertEq(withdrawFee_, withdrawFee);
        assertEq(compoundFee_, compoundFee);
    }

    function testRewardBaseTokens() public {
        address[] memory rewardBaseTokens = dlpVault.getRewardBaseTokens();
        assertEq(rewardBaseTokens[0], rWBTC);
        assertEq(rewardBaseTokens[1], rUSDT);
        assertEq(rewardBaseTokens[2], rUSDC);
        assertEq(rewardBaseTokens[3], rDAI);
        assertEq(rewardBaseTokens[4], rWETH);

        dlpVault.removeRewardBaseTokens(rewardBaseTokens);
        assertEq(dlpVault.getRewardBaseTokens().length, 0);
    }

    function testVaultCap() public {
        assertEq(dlpVault.vaultCap(), vaultCap);
    }

    function testFirstDeposit() public {
        uint256 assets = 100 ether;

        {
            vm.startPrank(alice);
            ERC20(DLP).approve(address(dlpVault), type(uint256).max);
            dlpVault.deposit(assets, alice);
            vm.stopPrank();
        }
        {
            uint256 fee = (assets * depositFee) / multiplier;
            assertEq(ERC20(DLP).balanceOf(address(treasury)), fee);
            assertEq(ERC20(DLP).balanceOf(address(dlpVault)), 0);
            assertEq(dlpVault.totalAssets(), assets - fee);
        }
        {
            uint256 shares = assets - (assets * depositFee) / multiplier;
            assertEq(dlpVault.balanceOf(alice), shares);
            assertEq(dlpVault.totalSupply(), shares);
        }
    }

    function testFirstMint() public {
        uint256 shares = 100 ether;

        {
            vm.startPrank(alice);
            ERC20(DLP).approve(address(dlpVault), type(uint256).max);
            dlpVault.mint(shares, alice);
            vm.stopPrank();
        }
        {
            uint256 fee = (shares * depositFee) / multiplier;
            assertEq(ERC20(DLP).balanceOf(address(treasury)), fee);
            assertEq(ERC20(DLP).balanceOf(address(dlpVault)), 0);
            assertEq(dlpVault.totalAssets(), shares - fee);
        }
        {
            shares -= (shares * depositFee) / multiplier;
            assertEq(dlpVault.balanceOf(alice), shares);
            assertEq(dlpVault.totalSupply(), shares);
        }
    }

    function testSwapToWETH() public {
        console2.log("Before WETH: ", ERC20(WETH).balanceOf(address(dlpVault)));

        vm.startPrank(rUSDC_HOLDER);
        ERC20(rUSDC).transfer(address(dlpVault), 1 gwei);
        vm.stopPrank();

        vm.startPrank(rUSDT_HOLDER);
        ERC20(rUSDT).transfer(address(dlpVault), 1 gwei);
        vm.stopPrank();

        vm.startPrank(rWBTC_HOLDER);
        ERC20(rWBTC).transfer(address(dlpVault), 1 gwei);
        vm.stopPrank();

        vm.startPrank(rDAI_HOLDER);
        ERC20(rDAI).transfer(address(dlpVault), 1 ether);
        vm.stopPrank();

        vm.startPrank(rWETH_HOLDER);
        ERC20(rWETH).transfer(address(dlpVault), 1 ether);
        vm.stopPrank();

        dlpVault.swapToWETH();

        console2.log("After WETH: ", ERC20(WETH).balanceOf(address(dlpVault)));
    }

    function testJoinPool() public {
        console2.log("Before DLP: ", ERC20(DLP).balanceOf(address(dlpVault)));

        vm.startPrank(WETH_HOLDER);
        ERC20(WETH).transfer(address(dlpVault), 1 ether);
        vm.stopPrank();

        dlpVault.joinPool();

        console2.log("After DLP: ", ERC20(DLP).balanceOf(address(dlpVault)));
    }

    function testStakeDLP() public {
        console2.log("Before TotalAssets: ", dlpVault.totalAssets());

        uint256 assets = 1 ether;
        vm.startPrank(DLP_HOLDER);
        ERC20(DLP).transfer(address(dlpVault), assets);
        vm.stopPrank();

        dlpVault.stakeDLP();

        console2.log("After TotalAssets: ", dlpVault.totalAssets());
        assertEq(dlpVault.totalAssets(), assets);
    }

    function testCompoundAfterFirstDeposit() public {
        uint256 assets = 100 ether;

        {
            vm.startPrank(alice);
            ERC20(DLP).approve(address(dlpVault), type(uint256).max);
            dlpVault.deposit(assets, alice);
            vm.stopPrank();
        }
        {
            dlpVault.compound();
        }
    }

    function testCompound() public {
        {
            uint256 assets = 100 ether;

            vm.startPrank(alice);
            ERC20(DLP).approve(address(dlpVault), type(uint256).max);
            dlpVault.deposit(assets, alice);
            vm.stopPrank();

            console2.log("Alice shares: ", dlpVault.balanceOf(alice));
            console2.log("Total shares: ", dlpVault.totalSupply());
            console2.log("Total assets: ", dlpVault.totalAssets());
        }
        {
            _borrowAndRepay();
            vm.warp(block.timestamp + 365 * 86400);
            vm.startPrank(WETH_HOLDER);
            ERC20(WETH).transfer(address(dlpVault), 0.01 ether);
            vm.stopPrank();
        }
        {
            uint256 assets = 100 ether;

            vm.startPrank(bob);
            ERC20(DLP).approve(address(dlpVault), type(uint256).max);
            dlpVault.deposit(assets, bob);
            vm.stopPrank();

            console2.log("Bob shares: ", dlpVault.balanceOf(bob));
            console2.log("Total shares: ", dlpVault.totalSupply());
            console2.log("Total assets: ", dlpVault.totalAssets());
        }
        {
            assert(dlpVault.balanceOf(bob) < dlpVault.balanceOf(alice));
            assert(dlpVault.totalAssets() > 200 ether);
            assertEq(ERC20(DLP).balanceOf(address(dlpVault)), 0);
        }
    }

    function testRedeem() public {
        testCompound();

        {
            uint256 shares = dlpVault.balanceOf(alice);
            uint256 totalAssets = dlpVault.totalAssets();
            uint256 totalShares = dlpVault.totalSupply();
            uint256 assets = ((shares - (shares * withdrawFee) / multiplier) *
                totalAssets) / totalShares;

            vm.startPrank(alice);
            dlpVault.redeem(shares, carol, alice);
            vm.stopPrank();

            assertEq(dlpVault.balanceOf(alice), 0);
            assertEq(dlpVault.totalAssets(), totalAssets - assets);
            assertEq(dlpVault.queuedDLP(), assets);
            assertEq(dlpVault.claimableDLP(), 0);

            (
                address caller,
                uint256 assets_,
                address receiver,
                uint32 createdAt
            ) = dlpVault.withdrawalQueues(0);
            assertEq(caller, alice);
            assertEq(assets_, assets);
            assertEq(receiver, carol);
            assertEq(createdAt, uint32(block.timestamp));

            assertEq(dlpVault.withdrawalsOf(alice).length, 1);
        }
    }

    function testWithdraw() public {
        testCompound();

        {
            uint256 shares = dlpVault.balanceOf(alice);
            uint256 totalAssets = dlpVault.totalAssets();
            uint256 totalShares = dlpVault.totalSupply();
            uint256 assets = (shares * totalAssets) / totalShares;
            uint256 assetsExceptFee = (assets -
                (shares *
                    withdrawFee *
                    totalAssets +
                    multiplier *
                    totalShares -
                    1) /
                (multiplier * totalShares));

            vm.startPrank(alice);
            dlpVault.withdraw(assets, alice, alice);
            vm.stopPrank();

            assertEq(dlpVault.balanceOf(alice), 0);
            assertEq(dlpVault.totalAssets(), totalAssets - assetsExceptFee);
            assertEq(dlpVault.queuedDLP(), assetsExceptFee);
            assertEq(dlpVault.claimableDLP(), 0);

            (
                address caller,
                uint256 assets_,
                address receiver,
                uint32 createdAt
            ) = dlpVault.withdrawalQueues(0);
            assertEq(caller, alice);
            assertEq(assets_, assetsExceptFee);
            assertEq(receiver, alice);
            assertEq(createdAt, uint32(block.timestamp));

            assertEq(dlpVault.withdrawalsOf(alice).length, 1);
        }
    }

    function testClaim() public {
        testRedeem();

        {
            assertEq(dlpVault.withdrawalQueueIndex(), 0);

            vm.warp(block.timestamp + 31 * 86400);
            dlpVault.compound();

            console2.log(
                "Before Vault's DLP: ",
                ERC20(DLP).balanceOf(address(dlpVault))
            );
            console2.log("Before Queued DLP: ", dlpVault.queuedDLP());
            console2.log("Before Claimable DLP: ", dlpVault.claimableDLP());
            console2.log("Before Total Assets: ", dlpVault.totalAssets());
            console2.log("Before Carol's DLP: ", ERC20(DLP).balanceOf(carol));

            (address caller, uint256 assets, address receiver, ) = dlpVault
                .withdrawalQueues(0);
            assertEq(caller, alice);
            assertEq(receiver, carol);
            assertEq(ERC20(DLP).balanceOf(carol), 0);
            assertEq(dlpVault.queuedDLP(), assets);
            assertEq(dlpVault.claimableDLP(), assets);

            assertEq(dlpVault.withdrawalsOf(alice).length, 1);
        }
        {
            assertEq(dlpVault.withdrawalQueueIndex(), 1);

            dlpVault.claim(0);

            console2.log(
                "After Vault's DLP: ",
                ERC20(DLP).balanceOf(address(dlpVault))
            );
            console2.log("After Queued DLP: ", dlpVault.queuedDLP());
            console2.log("After Claimable DLP: ", dlpVault.claimableDLP());
            console2.log("After Total Assets: ", dlpVault.totalAssets());
            console2.log("After Carol's DLP: ", ERC20(DLP).balanceOf(carol));

            (address caller, uint256 assets, address receiver, ) = dlpVault
                .withdrawalQueues(0);
            assertEq(caller, alice);
            assertEq(receiver, carol);
            assertEq(assets, ERC20(DLP).balanceOf(carol));
            assertEq(dlpVault.queuedDLP(), 0);
            assertEq(dlpVault.claimableDLP(), 0);

            assertEq(dlpVault.withdrawalsOf(alice).length, 0);
        }
    }
}
