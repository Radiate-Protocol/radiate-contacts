// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";

import {Kernel, Keycode, Permissions, toKeycode, Policy} from "../Kernel.sol";
import {RolesConsumer, ROLESv1} from "../modules/ROLES/OlympusRoles.sol";

import {IRewardDistributor} from "../interfaces/radiate/IRewardDistributor.sol";

contract MasterChef is
    ReentrancyGuardUpgradeable,
    RolesConsumer,
    IRewardDistributor
{
    using SafeERC20 for IERC20;

    //============================================================================================//
    //                                         CONSTANT                                           //
    //============================================================================================//

    /// @notice Multiplier
    uint256 public constant MULTIPLIER = 1e20;

    //============================================================================================//
    //                                          STORAGE                                           //
    //============================================================================================//

    /// @notice kernel
    Kernel public kernel;

    /// @notice reward token
    IERC20 public rewardToken;

    /// @notice total allocation points
    uint256 public totalAllocPoint;

    /// @notice info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 pending;
        uint256 rewardDebt;
    }
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    /// @notice info of each pool.
    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 accTokenPerShare;
    }
    PoolInfo[] public poolInfo;

    //============================================================================================//
    //                                           EVENT                                            //
    //============================================================================================//

    event KernelChanged(address kernel);
    event Staked(address indexed user, uint256 indexed pid, uint256 amount);
    event Unstaked(address indexed user, uint256 indexed pid, uint256 amount);
    event Claimed(address indexed user, uint256 indexed pid, uint256 amount);

    //============================================================================================//
    //                                           ERROR                                            //
    //============================================================================================//

    error CALLER_NOT_KERNEL();
    error ZERO_AMOUNT();
    error EXCEED_AMOUNT();

    //============================================================================================//
    //                                         INITIALIZE                                         //
    //============================================================================================//

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        Kernel _kernel,
        IERC20 _rewardToken
    ) external initializer {
        kernel = _kernel;
        rewardToken = _rewardToken;

        __ReentrancyGuard_init();
    }

    //============================================================================================//
    //                                          MODIFIER                                          //
    //============================================================================================//

    modifier onlyKernel() {
        if (msg.sender != address(kernel)) revert CALLER_NOT_KERNEL();

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

    function add(uint256 _allocPoint, IERC20 _lpToken) external onlyAdmin {
        totalAllocPoint += _allocPoint;

        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                accTokenPerShare: 0
            })
        );
    }

    function set(uint256 _pid, uint256 _allocPoint) external onlyAdmin {
        PoolInfo storage pool = poolInfo[_pid];

        totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;

        pool.allocPoint = _allocPoint;
    }

    function recoverToken(address _asset, uint256 _amount) external onlyAdmin {
        IERC20(_asset).safeTransfer(msg.sender, _amount);
    }

    //============================================================================================//
    //                                         STAKE LOGIC                                        //
    //============================================================================================//

    function pendingReward(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        return
            (user.amount * pool.accTokenPerShare) /
            MULTIPLIER -
            user.rewardDebt;
    }

    function receiveReward(address _asset, uint256 _amount) external override {
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

        if (_asset == address(rewardToken)) {
            uint256 length = poolInfo.length;

            for (uint256 i = 0; i < length; ) {
                PoolInfo storage pool = poolInfo[i];

                pool.accTokenPerShare +=
                    (_amount * pool.allocPoint * MULTIPLIER) /
                    (totalAllocPoint * pool.lpToken.balanceOf(address(this)));

                unchecked {
                    ++i;
                }
            }
        }
    }

    function _update(uint256 _pid, address _user) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        user.pending +=
            (user.amount * pool.accTokenPerShare) /
            MULTIPLIER -
            user.rewardDebt;
    }

    function stake(uint256 _pid, uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZERO_AMOUNT();

        _update(_pid, msg.sender);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);

        user.amount += _amount;
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / MULTIPLIER;

        emit Staked(msg.sender, _pid, _amount);
    }

    function unstake(uint256 _pid, uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZERO_AMOUNT();

        _update(_pid, msg.sender);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount < _amount) revert EXCEED_AMOUNT();

        user.amount -= _amount;
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / MULTIPLIER;

        pool.lpToken.safeTransfer(msg.sender, _amount);

        emit Unstaked(msg.sender, _pid, _amount);
    }

    function claim(uint256 _pid) external nonReentrant {
        _update(_pid, msg.sender);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        user.rewardDebt = (user.amount * pool.accTokenPerShare) / MULTIPLIER;

        uint256 pending = user.pending;
        if (pending > 0) {
            user.pending = 0;

            rewardToken.safeTransfer(msg.sender, pending);

            emit Claimed(msg.sender, _pid, pending);
        }
    }
}
