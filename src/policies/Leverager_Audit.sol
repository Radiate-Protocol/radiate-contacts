// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";

import {Kernel, Keycode, Permissions, toKeycode, Policy} from "../Kernel.sol";
import {RolesConsumer, ROLESv1} from "../modules/ROLES/OlympusRoles.sol";

import {IDLPVault} from "../interfaces/radiate/IDLPVault.sol";
import {ILeverager} from "../interfaces/radiate/ILeverager.sol";
import {IRewardDistributor} from "../interfaces/radiate/IRewardDistributor.sol";
import {IAToken} from "../interfaces/radiant-interfaces/IAToken.sol";
import {ILendingPool, DataTypes} from "../interfaces/radiant-interfaces/ILendingPool.sol";
import {IVariableDebtToken} from "../interfaces/radiant-interfaces/IVariableDebtToken.sol";
import {IChefIncentivesController} from "../interfaces/radiant-interfaces/IChefIncentivesController.sol";
import {IMultiFeeDistribution} from "../interfaces/radiant-interfaces/IMultiFeeDistribution.sol";
import {IPool} from "../interfaces/aave/IPool.sol";
import {IFlashLoanSimpleReceiver} from "../interfaces/aave/IFlashLoanSimpleReceiver.sol";

contract Leverager is
    ReentrancyGuardUpgradeable,
    RolesConsumer,
    IFlashLoanSimpleReceiver,
    ILeverager
{
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    //============================================================================================//
    //                                         CONSTANT                                           //
    //============================================================================================//

    /// @notice Radiant Token
    IERC20 public constant RDNT =
        IERC20(0x3082CC23568eA640225c2467653dB90e9250AaA0);

    /// @notice Lending Pool address
    ILendingPool public constant LENDING_POOL =
        ILendingPool(0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1);

    /// @notice Chef Incentives Controller
    IChefIncentivesController public constant CHEF_INCENTIVES_CONTROLLER =
        IChefIncentivesController(0xebC85d44cefb1293707b11f707bd3CEc34B4D5fA);

    /// @notice Multi Fee Distributor
    IMultiFeeDistribution public constant MFD =
        IMultiFeeDistribution(0x76ba3eC5f5adBf1C58c91e86502232317EeA72dE);

    /// @notice Aave lending pool address (for flashloans)
    IPool public constant AAVE_LENDING_POOL =
        IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    /// @notice Multiplier 100%
    uint256 public constant MULTIPLIER = 1e6;

    /// @notice Precision
    uint256 public constant PRECISION = 1e20;

    uint256 internal constant _RAY = 1e27;
    uint256 internal constant _HALF_RAY = _RAY / 2;

    //============================================================================================//
    //                                          STORAGE                                           //
    //============================================================================================//

    /// @notice kernel
    Kernel public kernel;

    /// @notice Dlp vault contract
    IDLPVault public dlpVault;

    /// @notice Staking token
    IERC20 public asset;

    /// @notice Reward distributor
    IRewardDistributor public distributor;

    /// @notice Fee
    uint256 public fee;

    /// @notice Borrow ratio
    uint256 public borrowRatio;

    /// @notice Acc token per share for aToken
    uint256 public aAccTokenPerShare;

    /// @notice Acc token per share for debtToken
    uint256 public dAccTokenPerShare;

    /// @notice Total scaled balance of aToken
    uint256 public aTotalSB;

    /// @notice Total scaled balance of debtToken
    uint256 public dTotalSB;

    /// @notice Hard cap of aToken
    uint256 public aHardCap;

    /// @notice Minimum of stake amount
    uint256 public minStakeAmount;

    /// @notice Stake info
    struct Stake {
        uint256 aTSB; // aToken's scaled balance
        uint256 dTSB; // debtToken's scaled balance
        uint256 pending;
        uint256 debt;
    }
    mapping(address => Stake) public stakeInfo;

    /// @notice Claim info
    struct Claim {
        uint256 amount;
        uint256 feeAmount;
        address receiver;
        bool isClaimed;
        uint32 expireAt;
    }
    uint256 public claimIndex;
    mapping(uint256 => Claim) public claimInfo;
    mapping(address => EnumerableSet.UintSet) private _userClaims;

    //============================================================================================//
    //                                           EVENT                                            //
    //============================================================================================//

    event KernelChanged(address kernel);
    event DistributorChanged(address distributor);
    event HardCapChanged(uint256 aHardCap);
    event MinStakeAmountChanged(uint256 minStakeAmount);
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(
        address indexed account,
        uint256 indexed index,
        uint256 amount,
        uint32 expireAt
    );
    event ClaimedVested(
        address indexed account,
        uint256 indexed index,
        uint256 amount
    );

    //============================================================================================//
    //                                           ERROR                                            //
    //============================================================================================//

    error CALLER_NOT_KERNEL();
    error CALLER_NOT_AAVE();
    error MATH_MULTIPLICATION_OVERFLOW();
    error INVALID_AMOUNT();
    error INVALID_UNSTAKE();
    error INVALID_CLAIM();
    error ERROR_BORROW_RATIO(uint256 borrowRatio);
    error ERROR_FEE(uint256 fee);
    error EXCEED_HARD_CAP();
    error LESS_THAN_MIN_AMOUNT();

    //============================================================================================//
    //                                         INITIALIZE                                         //
    //============================================================================================//

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        Kernel _kernel,
        IDLPVault _dlpVault,
        IERC20 _asset,
        IRewardDistributor _distributor,
        uint256 _fee,
        uint256 _borrowRatio,
        uint256 _aHardCap,
        uint256 _minStakeAmount
    ) external initializer {
        if (_fee >= MULTIPLIER) revert ERROR_FEE(_fee);
        if (_borrowRatio >= MULTIPLIER) revert ERROR_BORROW_RATIO(_borrowRatio);

        kernel = _kernel;
        dlpVault = _dlpVault;
        asset = _asset;
        distributor = _distributor;
        fee = _fee;
        borrowRatio = _borrowRatio;
        aHardCap = _aHardCap;
        minStakeAmount = _minStakeAmount;

        _asset.safeApprove(address(LENDING_POOL), type(uint256).max);
        _asset.safeApprove(address(AAVE_LENDING_POOL), type(uint256).max);

        __ReentrancyGuard_init();
    }

    //============================================================================================//
    //                                          MODIFIER                                          //
    //============================================================================================//

    modifier onlyKernel() {
        if (msg.sender != address(kernel)) revert CALLER_NOT_KERNEL();

        _;
    }

    modifier onlyAaveLendingPool() {
        if (msg.sender != address(AAVE_LENDING_POOL)) revert CALLER_NOT_AAVE();

        _;
    }

    modifier onlyAdmin() {
        ROLES.requireRole("admin", msg.sender);

        _;
    }

    //============================================================================================//
    //                                     DEFAULT OVERRIDES                                      //
    //============================================================================================//

    function changeKernel(Kernel _kernel) external onlyKernel {
        kernel = _kernel;

        emit KernelChanged(address(_kernel));
    }

    function isActive() external view returns (bool) {
        return kernel.isPolicyActive(Policy(address(this)));
    }

    function configureDependencies()
        external
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](1);
        dependencies[0] = toKeycode("ROLES");
        ROLES = ROLESv1(address(kernel.getModuleForKeycode(dependencies[0])));
    }

    function requestPermissions()
        external
        pure
        returns (Permissions[] memory requests)
    {
        requests = new Permissions[](0);
    }

    //============================================================================================//
    //                                         ADMIN                                              //
    //============================================================================================//

    function setRewardDistributor(
        IRewardDistributor _distributor
    ) external onlyAdmin {
        distributor = _distributor;

        emit DistributorChanged(address(_distributor));
    }

    function setHardCap(uint256 _aHardCap) external onlyAdmin {
        aHardCap = _aHardCap;

        emit HardCapChanged(_aHardCap);
    }

    function setMinStakeAmount(uint256 _minStakeAmount) external onlyAdmin {
        minStakeAmount = _minStakeAmount;

        emit MinStakeAmountChanged(_minStakeAmount);
    }

    function recoverERC20(
        IERC20 _token,
        uint256 _tokenAmount
    ) external onlyAdmin {
        _token.safeTransfer(msg.sender, _tokenAmount);
    }

    //============================================================================================//
    //                                     LENDING LOGIC                                          //
    //============================================================================================//

    /**
     * @dev Returns the configuration of the reserve
     * @return The configuration of the reserve
     *
     */
    function getConfiguration()
        public
        view
        returns (DataTypes.ReserveConfigurationMap memory)
    {
        return LENDING_POOL.getConfiguration(address(asset));
    }

    /**
     * @dev Returns variable debt token address of asset
     * @return varaiableDebtToken address of the asset
     *
     */
    function getVDebtToken() public view override returns (address) {
        DataTypes.ReserveData memory reserveData = LENDING_POOL.getReserveData(
            address(asset)
        );
        return reserveData.variableDebtTokenAddress;
    }

    /**
     * @dev Returns atoken address of asset
     * @return varaiableDebtToken address of the asset
     *
     */
    function getAToken() public view override returns (address) {
        DataTypes.ReserveData memory reserveData = LENDING_POOL.getReserveData(
            address(asset)
        );
        return reserveData.aTokenAddress;
    }

    /**
     * @dev Returns loan to value
     * @return ltv of the asset
     *
     */
    function ltv() public view returns (uint256) {
        DataTypes.ReserveConfigurationMap memory conf = LENDING_POOL
            .getConfiguration(address(asset));
        return conf.data % (2 ** 16);
    }

    /**
     * @dev Divides two ray, rounding half up to the nearest ray
     * @param a Ray
     * @param b Ray
     * @return The result of a/b, in ray
     **/
    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) {
            return 0;
        }

        if (a > (type(uint256).max - _HALF_RAY) / b)
            revert MATH_MULTIPLICATION_OVERFLOW();

        return (a * b + _HALF_RAY) / _RAY;
    }

    //============================================================================================//
    //                                     REWARDS LOGIC                                          //
    //============================================================================================//

    function _update(address _account) internal {
        address[] memory tokens = new address[](1);

        // claim reward for aToken
        if (aTotalSB > 0) {
            tokens[0] = getAToken();
            (uint256 balanceBefore, , ) = MFD.earnedBalances(address(dlpVault));

            CHEF_INCENTIVES_CONTROLLER.claim(address(dlpVault), tokens);

            (uint256 balanceAfter, , ) = MFD.earnedBalances(address(dlpVault));
            uint256 reward = balanceAfter - balanceBefore;
            // update rate
            if (reward > 0) {
                aAccTokenPerShare += (reward * PRECISION) / aTotalSB;
            }
        }

        // claim reward for debtToken
        if (dTotalSB > 0) {
            tokens[0] = getVDebtToken();
            (uint256 balanceBefore, , ) = MFD.earnedBalances(address(dlpVault));

            CHEF_INCENTIVES_CONTROLLER.claim(address(dlpVault), tokens);

            (uint256 balanceAfter, , ) = MFD.earnedBalances(address(dlpVault));
            uint256 reward = balanceAfter - balanceBefore;
            // update rate
            if (reward > 0) {
                dAccTokenPerShare += (reward * PRECISION) / dTotalSB;
            }
        }

        // update pending
        Stake storage info = stakeInfo[_account];

        info.pending +=
            (aAccTokenPerShare * info.aTSB + dAccTokenPerShare * info.dTSB) /
            PRECISION -
            info.debt;
    }

    function _updateDebt(address _account) internal {
        Stake storage info = stakeInfo[_account];

        info.debt =
            (aAccTokenPerShare * info.aTSB + dAccTokenPerShare * info.dTSB) /
            PRECISION;
    }

    //============================================================================================//
    //                                     LOOPING LOGIC                                          //
    //============================================================================================//

    /**
     * @dev Loop the deposit and borrow of an asset (removed eth loop, deposit WETH directly)
     *
     */
    function _loop(uint256 amount) internal {
        if (amount == 0) return;

        IAToken aToken = IAToken(getAToken());
        IVariableDebtToken debtToken = IVariableDebtToken(getVDebtToken());

        uint256 aTSBBefore = aToken.scaledBalanceOf(address(dlpVault));
        uint256 dTSBBefore = debtToken.scaledBalanceOf(address(dlpVault));

        // deposit
        LENDING_POOL.deposit(address(asset), amount, address(dlpVault), 0);

        // flashloan for loop
        uint256 loanAmount = (amount * borrowRatio) /
            (MULTIPLIER - borrowRatio);
        if (loanAmount > 0) {
            AAVE_LENDING_POOL.flashLoanSimple(
                address(this),
                address(asset),
                loanAmount,
                "",
                0
            );
        }

        uint256 aTSBAmount = aToken.scaledBalanceOf(address(dlpVault)) -
            aTSBBefore;
        uint256 dTSBAmount = debtToken.scaledBalanceOf(address(dlpVault)) -
            dTSBBefore;

        // stake info
        Stake storage info = stakeInfo[msg.sender];
        info.aTSB += aTSBAmount;
        info.dTSB += dTSBAmount;

        aTotalSB += aTSBAmount;
        dTotalSB += dTSBAmount;
    }

    /**
     * @dev Loop the deposit and borrow of an asset to repay flashloan
     *
     */
    function executeOperation(
        address _asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata
    ) external override onlyAaveLendingPool returns (bool) {
        require(initiator == address(this));

        // deposit
        LENDING_POOL.deposit(_asset, amount, address(dlpVault), 0);

        // borrow for repay
        uint256 borrowAmount = amount + premium; // repay
        uint256 interestRateMode = 2; // variable
        LENDING_POOL.borrow(
            _asset,
            borrowAmount,
            interestRateMode,
            0,
            address(dlpVault)
        );

        return true;
    }

    function _unloop(uint256 amount) internal {
        if (amount == 0) return;

        IAToken aToken = IAToken(getAToken());
        IVariableDebtToken debtToken = IVariableDebtToken(getVDebtToken());

        uint256 aTSBBefore = aToken.scaledBalanceOf(address(dlpVault));
        uint256 dTSBBefore = debtToken.scaledBalanceOf(address(dlpVault));

        {
            (uint256 aTokenAmount, uint256 debtTokenAmount) = staked(
                msg.sender
            );
            uint256 repayAmount = debtTokenAmount.mulDiv(
                amount,
                aTokenAmount - debtTokenAmount,
                Math.Rounding.Up
            );

            // flashloan for unloop
            AAVE_LENDING_POOL.flashLoanSimple(
                address(dlpVault),
                address(asset),
                repayAmount,
                abi.encode(amount, msg.sender),
                0
            );
        }

        uint256 aTSBAmount = aTSBBefore -
            aToken.scaledBalanceOf(address(dlpVault));
        uint256 dTSBAmount = dTSBBefore -
            debtToken.scaledBalanceOf(address(dlpVault));

        // stake info
        Stake storage info = stakeInfo[msg.sender];
        info.aTSB -= aTSBAmount;
        info.dTSB -= dTSBAmount;

        aTotalSB -= aTSBAmount;
        dTotalSB -= dTSBAmount;
    }

    //============================================================================================//
    //                                         STAKE LOGIC                                        //
    //============================================================================================//

    function totalAssets()
        external
        view
        returns (uint256 aTokenAmount, uint256 debtTokenAmount)
    {
        aTokenAmount = IERC20(getAToken()).balanceOf(address(dlpVault));
        debtTokenAmount = IERC20(getVDebtToken()).balanceOf(address(dlpVault));
    }

    function staked(
        address _account
    ) public view returns (uint256 aTokenAmount, uint256 debtTokenAmount) {
        Stake storage info = stakeInfo[_account];

        aTokenAmount = _rayMul(
            info.aTSB,
            LENDING_POOL.getReserveNormalizedIncome(address(asset))
        );
        debtTokenAmount = _rayMul(
            info.dTSB,
            LENDING_POOL.getReserveNormalizedVariableDebt(address(asset))
        );
    }

    function stake(uint256 _amount) external nonReentrant {
        if (_amount < minStakeAmount) revert LESS_THAN_MIN_AMOUNT();

        _update(msg.sender);

        asset.safeTransferFrom(msg.sender, address(this), _amount);
        _loop(_amount);

        if (
            _rayMul(
                aTotalSB,
                LENDING_POOL.getReserveNormalizedIncome(address(asset))
            ) > aHardCap
        ) revert EXCEED_HARD_CAP();

        _updateDebt(msg.sender);

        emit Staked(msg.sender, _amount);
    }

    function unstakeable(address _account) public view returns (uint256) {
        (uint256 aTokenAmount, uint256 debtTokenAmount) = staked(_account);

        if (aTokenAmount < debtTokenAmount) return 0;

        return aTokenAmount - debtTokenAmount;
    }

    function unstake(uint256 _amount) external nonReentrant {
        if (_amount == 0) {
            _amount = unstakeable(msg.sender);
        }

        uint256 unstakeableAmount = unstakeable(msg.sender);
        if (_amount > unstakeableAmount) revert INVALID_UNSTAKE();

        _update(msg.sender);

        _unloop(_amount);

        _updateDebt(msg.sender);

        emit Unstaked(msg.sender, _amount);
    }

    function claimable(
        address _account
    )
        external
        view
        returns (uint256 amount, uint256 feeAmount, uint256 expireAt)
    {
        address[] memory tokens = new address[](1);

        // claimable reward for aToken
        uint256 _aAccTokenPerShare = aAccTokenPerShare;
        if (aTotalSB > 0) {
            tokens[0] = getAToken();
            uint256[] memory rewards = CHEF_INCENTIVES_CONTROLLER
                .pendingRewards(address(dlpVault), tokens);

            if (rewards[0] > 0) {
                _aAccTokenPerShare += (rewards[0] * PRECISION) / aTotalSB;
            }
        }

        // claimable reward for debtToken
        uint256 _dAccTokenPerShare = dAccTokenPerShare;
        if (dTotalSB > 0) {
            tokens[0] = getVDebtToken();
            uint256[] memory rewards = CHEF_INCENTIVES_CONTROLLER
                .pendingRewards(address(dlpVault), tokens);

            if (rewards[0] > 0) {
                _dAccTokenPerShare += (rewards[0] * PRECISION) / dTotalSB;
            }
        }

        // update pending
        Stake memory info = stakeInfo[_account];
        uint256 pending = info.pending +
            (_aAccTokenPerShare * info.aTSB + dAccTokenPerShare * info.dTSB) /
            PRECISION -
            info.debt;

        feeAmount = (pending * fee) / MULTIPLIER;
        amount = pending - feeAmount;
        expireAt = block.timestamp + MFD.vestDuration();
    }

    function claim() external nonReentrant {
        _update(msg.sender);
        _updateDebt(msg.sender);

        Stake storage info = stakeInfo[msg.sender];
        uint256 pending = info.pending;

        if (pending > 0) {
            info.pending = 0;

            uint256 index = ++claimIndex;
            uint32 expireAt = uint32(block.timestamp + MFD.vestDuration());

            Claim storage _info = claimInfo[index];
            _info.feeAmount = (pending * fee) / MULTIPLIER;
            _info.amount = pending - _info.feeAmount;
            _info.receiver = msg.sender;
            _info.expireAt = expireAt;

            _userClaims[msg.sender].add(index);

            emit Claimed(msg.sender, index, pending, expireAt);
        }
    }

    function claimed(
        address _account
    ) external view returns (Claim[] memory info) {
        EnumerableSet.UintSet storage claims = _userClaims[_account];
        uint256 length = claims.length();

        info = new Claim[](length);

        for (uint256 i = 0; i < length; ) {
            info[i] = claimInfo[claims.at(i)];
            unchecked {
                ++i;
            }
        }
    }

    function claimVested(uint256 _index) external nonReentrant {
        Claim storage info = claimInfo[_index];
        if (
            info.amount == 0 ||
            info.isClaimed ||
            info.expireAt >= block.timestamp ||
            !_userClaims[info.receiver].remove(_index)
        ) revert INVALID_CLAIM();

        info.isClaimed = true;

        // reward
        dlpVault.withdrawForLeverager(info.receiver, info.amount);

        // fee
        dlpVault.withdrawForLeverager(address(this), info.feeAmount);
        RDNT.safeApprove(address(distributor), info.feeAmount);
        distributor.receiveReward(address(RDNT), info.feeAmount);

        emit ClaimedVested(info.receiver, _index, info.amount);
    }
}
