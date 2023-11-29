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
import {Leverager} from "../src/policies/Leverager_Audit.sol";

import {IAaveOracle} from "../src/interfaces/radiant-interfaces/IAaveOracle.sol";
import {IPriceProvider} from "../src/interfaces/radiant-interfaces/IPriceProvider.sol";
import {IAToken} from "../src/interfaces/radiant-interfaces/IAToken.sol";
import {IVariableDebtToken} from "../src/interfaces/radiant-interfaces/IVariableDebtToken.sol";
import {ICreditDelegationToken} from "../src/interfaces/radiant-interfaces/ICreditDelegationToken.sol";
import {ILendingPool} from "../src/interfaces/radiant-interfaces/ILendingPool.sol";
import {IFeeDistribution} from "../src/interfaces/radiant-interfaces/IFeeDistribution.sol";
import {IMultiFeeDistribution, LockedBalance} from "../src/interfaces/radiant-interfaces/IMultiFeeDistribution.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRewardDistributor} from "./mocks/MockRewardDistributor.sol";
import {UserFactory} from "./lib/UserFactory.sol";
import {AddressProvider} from "./src/AddressProvider.sol";
import {DLPVault_Test} from "./src/DLPVault_Test.sol";
import {Leverager_Test} from "./src/Leverager_Test.sol";
import {UnvalidatedChainlinkAdapter} from "./src/UnvalidatedChainlinkAdapter.sol";

contract LeveragerTest is Test, AddressProvider {
    Kernel public kernel;
    OlympusRoles public roles;
    RolesAdmin public admin;
    Treasury public treasury;
    MockRewardDistributor public distributor;
    DLPVault_Test public dlpVault;
    Leverager_Test public leverager;

    ILendingPool public lendingPool;
    IAToken public aToken;
    IVariableDebtToken public debtToken;

    uint256 public depositFee = 100;
    uint256 public withdrawFee = 200;
    uint256 public compoundFee = 300;
    uint256 public fee = 5e5;
    uint256 public borrowRatio = 6e5;
    uint256 public multiplier = 1e6;
    uint256 public aHardCap = 5000000000; // 5000 USDC
    uint256 public minStakeAmount = 100000000; // 100 USDC
    uint256 public liquidateThreshold = 75e4; // 75%
    uint256 public liquidateReward = 20000000; // 20 USDC

    uint256 public vaultCap = 100000 ether;

    address public alice;
    address public bob;
    address public carol;

    function setUp() public {
        _setupOracle();

        // Proxy Admin
        address proxyAdmin = address(new ProxyAdmin());

        // Kernel
        {
            kernel = new Kernel();
            roles = new OlympusRoles(kernel);
            admin = new RolesAdmin(kernel);
            treasury = new Treasury(kernel);

            kernel.executeAction(Actions.InstallModule, address(roles));
            kernel.executeAction(Actions.InstallModule, address(treasury));
            kernel.executeAction(Actions.ActivatePolicy, address(admin));

            admin.grantRole("admin", address(this));
        }

        // DLPVault
        {
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

            dlpVault.setFee(depositFee, withdrawFee, compoundFee);
            dlpVault.setVaultCap(vaultCap);
        }
        {
            address[] memory rewardBaseTokens = new address[](1);
            rewardBaseTokens[0] = rUSDC;
            bool[] memory isATokens = new bool[](1);
            isATokens[0] = true;
            uint24[] memory poolFees = new uint24[](1);
            poolFees[0] = USDC_POOL_FEE;
            uint256[] memory swapThresholds = new uint256[](1);
            swapThresholds[0] = USDC_SWAP_THRESHOLD;

            dlpVault.addRewardBaseTokens(
                rewardBaseTokens,
                isATokens,
                poolFees,
                swapThresholds
            );
        }
        {
            lendingPool = ILendingPool(dlpVault.LENDING_POOL());
        }

        // Reward Distributor
        {
            distributor = new MockRewardDistributor();
        }

        // Leverager
        {
            address impl = address(new Leverager_Test());
            address proxy = address(
                new TransparentUpgradeableProxy(
                    impl,
                    proxyAdmin,
                    abi.encodeWithSignature(
                        "initialize(address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256)",
                        address(kernel),
                        address(dlpVault),
                        USDC,
                        address(distributor),
                        fee,
                        borrowRatio,
                        aHardCap,
                        minStakeAmount,
                        liquidateThreshold,
                        liquidateReward
                    )
                )
            );
            leverager = Leverager_Test(payable(proxy));
            leverager.configureDependencies();

            admin.grantRole("leverager", address(leverager));
        }
        {
            aToken = IAToken(leverager.getAToken());
            debtToken = IVariableDebtToken(leverager.getVDebtToken());
        }
        {
            dlpVault.enableCreditDelegation(
                ICreditDelegationToken(address(debtToken)),
                address(leverager)
            );
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
            vm.startPrank(USDC_HOLDER);
            ERC20(USDC).transfer(alice, 1000 gwei);
            vm.stopPrank();

            vm.startPrank(WETH_HOLDER);
            ERC20(WETH).transfer(alice, 2000 ether);
            vm.stopPrank();

            vm.startPrank(DLP_HOLDER);
            ERC20(DLP).transfer(alice, 1000 ether);
            vm.stopPrank();

            vm.startPrank(alice);
            ERC20(WETH).approve(address(lendingPool), type(uint256).max);
            lendingPool.deposit(WETH, 2000 ether, alice, 0);
            ERC20(USDC).approve(address(lendingPool), type(uint256).max);
            vm.stopPrank();

            vm.startPrank(alice);
            ERC20(DLP).approve(address(dlpVault), type(uint256).max);
            dlpVault.deposit(1000 ether, alice);
            vm.stopPrank();
        }
    }

    function _setupOracle() internal {
        IAaveOracle aaveOracle = IAaveOracle(AAVE_ORACLE);
        IPriceProvider priceProvider = IPriceProvider(PRICE_PROVIDER);

        // CONFIGURE CHAINLINK ADAPTERS
        {
            uint256 heartbeat = 86400;
            address owner = aaveOracle.owner();
            address[] memory assets = new address[](7);
            address[] memory sources = new address[](7);

            vm.startPrank(owner);
            {
                UnvalidatedChainlinkAdapter adapter = new UnvalidatedChainlinkAdapter(
                        WBTC_CHAINLINK_AGGREGATOR,
                        heartbeat
                    );
                assets[0] = WBTC;
                sources[0] = address(adapter);
            }
            {
                UnvalidatedChainlinkAdapter adapter = new UnvalidatedChainlinkAdapter(
                        USDC_CHAINLINK_AGGREGATOR,
                        heartbeat
                    );
                assets[1] = USDC;
                sources[1] = address(adapter);
            }
            {
                UnvalidatedChainlinkAdapter adapter = new UnvalidatedChainlinkAdapter(
                        USDT_CHAINLINK_AGGREGATOR,
                        heartbeat
                    );
                assets[2] = USDT;
                sources[2] = address(adapter);
            }
            {
                UnvalidatedChainlinkAdapter adapter = new UnvalidatedChainlinkAdapter(
                        DAI_CHAINLINK_AGGREGATOR,
                        heartbeat
                    );
                assets[3] = DAI;
                sources[3] = address(adapter);
            }
            {
                UnvalidatedChainlinkAdapter adapter = new UnvalidatedChainlinkAdapter(
                        WETH_CHAINLINK_AGGREGATOR,
                        heartbeat
                    );
                assets[4] = WETH;
                sources[4] = address(adapter);
            }
            {
                UnvalidatedChainlinkAdapter adapter = new UnvalidatedChainlinkAdapter(
                        WSTETH_CHAINLINK_AGGREGATOR,
                        heartbeat
                    );
                assets[5] = WSTETH;
                sources[5] = address(adapter);
            }
            {
                UnvalidatedChainlinkAdapter adapter = new UnvalidatedChainlinkAdapter(
                        ARB_CHAINLINK_AGGREGATOR,
                        heartbeat
                    );
                assets[6] = ARB;
                sources[6] = address(adapter);
            }

            aaveOracle.setAssetSources(assets, sources);
            vm.stopPrank();
        }

        // CONFIGURE PRICE PROVIDER
        {
            address owner = aaveOracle.owner();

            vm.startPrank(owner);
            priceProvider.setUsePool(true);
            priceProvider.setAggregator(aaveOracle.getSourceOfAsset(WETH));
            vm.stopPrank();
        }
    }

    function _borrowAndRepay() internal {
        vm.startPrank(alice);
        lendingPool.borrow(USDC, 900 gwei, 2, 0, alice);
        lendingPool.repay(USDC, 1000 gwei, 2, alice);
        vm.stopPrank();
    }

    function testConfiguration() public {
        assertEq(address(leverager.dlpVault()), address(dlpVault));
        assertEq(address(leverager.asset()), USDC);
        assertEq(address(leverager.distributor()), address(distributor));
        assertEq(leverager.fee(), fee);
        assertEq(leverager.borrowRatio(), borrowRatio);
    }

    function testLoop() public {
        console2.log("Before ATotalSB: ", leverager.aTotalSB());
        console2.log("Before DTotalSB: ", leverager.dTotalSB());
        console2.log(
            "Before Balance: ",
            ERC20(USDC).balanceOf(address(leverager))
        );
        console2.log("Before AToken: ", aToken.balanceOf(address(dlpVault)));
        console2.log(
            "Before DebtToken: ",
            debtToken.balanceOf(address(dlpVault))
        );

        vm.startPrank(USDC_HOLDER);
        ERC20(USDC).approve(address(leverager), type(uint256).max);
        leverager.loop(100 gwei);
        vm.stopPrank();

        console2.log("After ATotalSB: ", leverager.aTotalSB());
        console2.log("After DTotalSB: ", leverager.dTotalSB());
        console2.log(
            "After Balance: ",
            ERC20(USDC).balanceOf(address(leverager))
        );
        console2.log("After AToken: ", aToken.balanceOf(address(dlpVault)));
        console2.log(
            "After DebtToken: ",
            debtToken.balanceOf(address(dlpVault))
        );
    }

    function testStake() public {
        uint256 assets = 100000000;

        {
            console2.log("Alice staking: ", assets);

            vm.startPrank(alice);
            ERC20(USDC).approve(address(leverager), type(uint256).max);
            leverager.stake(assets);
            vm.stopPrank();
        }
        {
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
        {
            _borrowAndRepay();
        }
        {
            vm.warp(block.timestamp + 30 * 86400);
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
    }

    function testUpdatePendingAndDebt() public {
        uint256 assets = 100000000;

        {
            console2.log("Alice staking: ", assets);

            vm.startPrank(alice);
            ERC20(USDC).approve(address(leverager), type(uint256).max);
            leverager.stake(assets);
            vm.stopPrank();
        }
        {
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
        {
            _borrowAndRepay();
        }
        {
            vm.warp(block.timestamp + 30 * 86400);

            vm.startPrank(alice);
            leverager.stake(assets);
            vm.stopPrank();

            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);

            assertEq(amount + feeAmount, pending);
        }
    }

    function testUnstakeAll() public {
        uint256 assets = 100000000;

        {
            console2.log("Alice staking: ", assets);

            vm.startPrank(alice);
            ERC20(USDC).approve(address(leverager), type(uint256).max);
            leverager.stake(assets);
            vm.stopPrank();
        }
        {
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);
        }
        {
            _borrowAndRepay();
        }
        {
            vm.warp(block.timestamp + 30 * 86400);
            console2.log("===== At: ", block.timestamp);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            uint256 unstakeable = leverager.unstakeable(alice);
            console2.log("Alice unstakeable: ", unstakeable);
            assertEq(aTokenAmount - debtTokenAmount, unstakeable);
        }
        {
            console2.log("Alice unstaking all: ");

            vm.startPrank(alice);
            leverager.unstake(0);
            vm.stopPrank();

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
    }

    function testUnstakeHalf() public {
        uint256 assets = 100000000;

        {
            console2.log("Alice staking: ", assets);

            vm.startPrank(alice);
            ERC20(USDC).approve(address(leverager), type(uint256).max);
            leverager.stake(assets);
            vm.stopPrank();
        }
        {
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);
        }
        {
            _borrowAndRepay();
        }
        {
            vm.warp(block.timestamp + 30 * 86400);
            console2.log("===== At: ", block.timestamp);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            uint256 unstakeable = leverager.unstakeable(alice);
            console2.log("Alice unstakeable: ", unstakeable);
            assertEq(aTokenAmount - debtTokenAmount, unstakeable);
        }
        {
            uint256 unstakeable = leverager.unstakeable(alice);

            console2.log("Alice unstaking half: ", unstakeable / 2);

            vm.startPrank(alice);
            leverager.unstake(unstakeable / 2);
            vm.stopPrank();

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
        {
            uint256 unstakeable = leverager.unstakeable(alice);

            console2.log("Alice unstaking rest half: ", unstakeable);

            vm.startPrank(alice);
            leverager.unstake(unstakeable);
            vm.stopPrank();

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
    }

    function testClaim() public {
        uint256 assets = 100000000;

        {
            console2.log("Alice staking: ", assets);

            vm.startPrank(alice);
            ERC20(USDC).approve(address(leverager), type(uint256).max);
            leverager.stake(assets);
            vm.stopPrank();
        }
        {
            _borrowAndRepay();
        }
        {
            vm.warp(block.timestamp + 30 * 86400);
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
        {
            vm.startPrank(alice);
            leverager.claim();
            vm.stopPrank();

            (
                uint256 amount,
                uint256 feeAmount,
                address receiver,
                bool isClaimed,
                uint32 expireAt
            ) = leverager.claimInfo(1);
            console2.log("Alice claimed: ", amount, feeAmount, expireAt);

            assertEq(receiver, alice);
            assertEq(isClaimed, false);

            Leverager.Claim[] memory info = leverager.claimed(alice);
            console2.log(
                "Alice claimed array: ",
                info[0].amount,
                info[0].feeAmount,
                info[0].expireAt
            );

            assertEq(info.length, 1);
            assertEq(info[0].receiver, alice);
            assertEq(info[0].isClaimed, false);
        }
        {
            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
    }

    function testClaimVested() public {
        uint256 assets = 100000000;

        {
            console2.log("Alice staking: ", assets);

            vm.startPrank(alice);
            ERC20(USDC).approve(address(leverager), type(uint256).max);
            leverager.stake(assets);
            vm.stopPrank();
        }
        {
            _borrowAndRepay();
        }
        {
            vm.warp(block.timestamp + 30 * 86400);
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
        {
            vm.startPrank(alice);
            leverager.claim();
            vm.stopPrank();

            (
                uint256 amount,
                uint256 feeAmount,
                address receiver,
                bool isClaimed,
                uint32 expireAt
            ) = leverager.claimInfo(1);
            console2.log("Alice claimed: ", amount, feeAmount, expireAt);

            assertEq(receiver, alice);
            assertEq(isClaimed, false);

            Leverager.Claim[] memory info = leverager.claimed(alice);
            console2.log(
                "Alice claimed array: ",
                info[0].amount,
                info[0].feeAmount,
                info[0].expireAt
            );

            assertEq(info.length, 1);
            assertEq(info[0].receiver, alice);
            assertEq(info[0].isClaimed, false);
        }
        {
            (uint256 amount, uint256 feeAmount, , , uint32 expireAt) = leverager
                .claimInfo(1);
            vm.warp(expireAt + 1);
            console2.log("===== At: ", block.timestamp);

            leverager.claimVested(1);

            console2.log(
                "Alice reward balance: ",
                ERC20(RDNT).balanceOf(alice)
            );
            console2.log(
                "Distributor reward balance: ",
                ERC20(RDNT).balanceOf(address(distributor))
            );
            assertEq(amount, ERC20(RDNT).balanceOf(alice));
            assertEq(feeAmount, ERC20(RDNT).balanceOf(address(distributor)));

            (, , , bool isClaimed, ) = leverager.claimInfo(1);
            assertEq(isClaimed, true);

            Leverager.Claim[] memory info = leverager.claimed(alice);
            assertEq(info.length, 0);
        }
    }

    function testClaimAgain() public {
        uint256 assets = 100000000;

        {
            console2.log("Alice staking: ", assets);

            vm.startPrank(alice);
            ERC20(USDC).approve(address(leverager), type(uint256).max);
            leverager.stake(assets);
            vm.stopPrank();
        }
        {
            _borrowAndRepay();
        }
        {
            vm.warp(block.timestamp + 5 * 86400);
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
        {
            vm.startPrank(alice);
            leverager.claim();
            vm.stopPrank();

            (
                uint256 amount,
                uint256 feeAmount,
                address receiver,
                bool isClaimed,
                uint32 expireAt
            ) = leverager.claimInfo(1);
            console2.log("Alice claimed: ", amount, feeAmount, expireAt);

            assertEq(receiver, alice);
            assertEq(isClaimed, false);

            Leverager.Claim[] memory info = leverager.claimed(alice);
            console2.log(
                "Alice claimed array: ",
                info[0].amount,
                info[0].feeAmount,
                info[0].expireAt
            );

            assertEq(info.length, 1);
            assertEq(info[0].receiver, alice);
            assertEq(info[0].isClaimed, false);
        }
        {
            vm.warp(block.timestamp + 10 * 86400);
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice unstakeable: ", leverager.unstakeable(alice));

            (uint256 amount, uint256 feeAmount, uint256 expireAt) = leverager
                .claimable(alice);
            console2.log("Alice claimable: ", amount, feeAmount, expireAt);
        }
        {
            vm.startPrank(alice);
            leverager.claim();
            vm.stopPrank();

            (
                uint256 amount,
                uint256 feeAmount,
                address receiver,
                bool isClaimed,
                uint32 expireAt
            ) = leverager.claimInfo(2);
            console2.log("Alice claimed: ", amount, feeAmount, expireAt);

            assertEq(receiver, alice);
            assertEq(isClaimed, false);
        }
        {
            (uint256 amount, uint256 feeAmount, , , uint32 expireAt) = leverager
                .claimInfo(1);
            vm.warp(expireAt + 1);
            console2.log("===== At: ", block.timestamp);

            leverager.claimVested(1);

            console2.log(
                "Alice reward balance: ",
                ERC20(RDNT).balanceOf(alice)
            );
            console2.log(
                "Distributor reward balance: ",
                ERC20(RDNT).balanceOf(address(distributor))
            );
            assertEq(amount, ERC20(RDNT).balanceOf(alice));
            assertEq(feeAmount, ERC20(RDNT).balanceOf(address(distributor)));

            (, , , bool isClaimed, ) = leverager.claimInfo(1);
            assertEq(isClaimed, true);

            Leverager.Claim[] memory info = leverager.claimed(alice);
            assertEq(info.length, 1);
        }
        {
            (, , , , uint32 expireAt) = leverager.claimInfo(2);
            vm.warp(expireAt + 100);
            console2.log("===== At: ", block.timestamp);

            leverager.claimVested(2);

            console2.log(
                "Alice reward balance: ",
                ERC20(RDNT).balanceOf(alice)
            );
            console2.log(
                "Distributor reward balance: ",
                ERC20(RDNT).balanceOf(address(distributor))
            );

            (, , , bool isClaimed, ) = leverager.claimInfo(2);
            assertEq(isClaimed, true);

            Leverager.Claim[] memory info = leverager.claimed(alice);
            assertEq(info.length, 0);
        }
    }

    function testLiquidate() public {
        uint256 assets = 100000000;

        {
            console2.log("Alice staking: ", assets);

            vm.startPrank(alice);
            ERC20(USDC).approve(address(leverager), type(uint256).max);
            leverager.stake(assets);
            vm.stopPrank();
        }
        {
            _borrowAndRepay();
        }
        {
            vm.warp(block.timestamp + 10 * 86400);
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice liquidatable: ", leverager.liquidatable(alice));
        }
        {
            vm.warp(block.timestamp + 3 * 365 * 86400);
            console2.log("===== At: ", block.timestamp);

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice liquidatable: ", leverager.liquidatable(alice));
        }
        {
            console2.log("===== Liquidate: ");

            vm.startPrank(bob);
            leverager.liquidate(alice);
            vm.stopPrank();

            (
                uint256 aTSB,
                uint256 dTSB,
                uint256 pending,
                uint256 debt
            ) = leverager.stakeInfo(alice);
            console2.log("Alice stake info: ", aTSB, dTSB);
            console2.log(pending, debt);

            (uint256 aTokenAmount, uint256 debtTokenAmount) = leverager.staked(
                alice
            );
            console2.log("Alice staked: ", aTokenAmount, debtTokenAmount);

            console2.log("Alice liquidatable: ", leverager.liquidatable(alice));
        }
    }
}
