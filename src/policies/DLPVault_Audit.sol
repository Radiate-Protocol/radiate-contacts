// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable, IERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {Kernel, Keycode, Permissions, toKeycode, Policy} from "../Kernel.sol";
import {RolesConsumer, ROLESv1} from "../modules/ROLES/OlympusRoles.sol";

import {IDLPVault} from "../interfaces/radiate/IDLPVault.sol";
import {IAToken} from "../interfaces/radiant-interfaces/IAToken.sol";
import {IMultiFeeDistribution, LockedBalance} from "../interfaces/radiant-interfaces/IMultiFeeDistribution.sol";
import {ILendingPool} from "../interfaces/radiant-interfaces/ILendingPool.sol";
import {ICreditDelegationToken} from "../interfaces/radiant-interfaces/ICreditDelegationToken.sol";
import {IPool} from "../interfaces/aave/IPool.sol";
import {IFlashLoanSimpleReceiver} from "../interfaces/aave/IFlashLoanSimpleReceiver.sol";
import {IVault, IAsset, IWETH} from "../interfaces/balancer/IVault.sol";

contract DLPVault is
    ERC4626Upgradeable,
    RolesConsumer,
    IFlashLoanSimpleReceiver,
    IDLPVault
{
    using SafeERC20 for IERC20;

    //============================================================================================//
    //                                         CONSTANT                                           //
    //============================================================================================//

    string private constant _NAME = "Radiate DLP Vault";
    string private constant _SYMBOL = "RADT-DLP";

    IERC20 public constant DLP =
        IERC20(0x32dF62dc3aEd2cD6224193052Ce665DC18165841);
    IWETH public constant WETH =
        IWETH(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IPool public constant AAVE_LENDING_POOL =
        IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    ILendingPool public constant LENDING_POOL =
        ILendingPool(0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1);
    IMultiFeeDistribution public constant MFD =
        IMultiFeeDistribution(0x76ba3eC5f5adBf1C58c91e86502232317EeA72dE);
    IVault public constant VAULT =
        IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    bytes32 public constant RDNT_WETH_POOL_ID =
        0x32df62dc3aed2cd6224193052ce665dc181658410002000000000000000003bd;

    uint256 public constant MAX_QUEUE_PROCESS_LIMIT = 30;
    uint256 public constant MULTIPLIER = 1e6; // 100%

    //============================================================================================//
    //                                          STORAGE                                           //
    //============================================================================================//

    /// @notice kernel
    Kernel public kernel;

    /// @notice treasury wallet
    address public treasury;

    /// @notice cap amount of DLP
    uint256 public vaultCap;

    /// @notice MFD lock index
    uint256 public defaultLockIndex;

    /// @notice DLP from treasury to boost the APY
    uint256 public boostedDLP;

    /// @notice rewards from MFD
    struct RewardInfo {
        address token;
        bool isAToken;
        bytes32 poolId; // Balancer pool id
        uint256 pending;
    }
    RewardInfo[] public rewards;

    /// @notice fee percent
    struct FeeInfo {
        uint256 depositFee;
        uint256 withdrawFee;
        uint256 compoundFee;
    }
    FeeInfo public fee;

    /// @notice withdrawal queue
    struct WithdrawalQueue {
        address receiver;
        uint256 assets;
        bool isClaimed;
    }
    WithdrawalQueue[] public withdrawalQueues;
    uint256 public withdrawalQueueIndex;
    uint256 public queuedDLP;
    uint256 public claimableDLP;

    //============================================================================================//
    //                                           EVENT                                            //
    //============================================================================================//

    event KernelChanged(address kernel);
    event FeeUpdated(
        uint256 depositFee,
        uint256 withdrawFee,
        uint256 compoundFee
    );
    event DefaultLockIndexUpdated(uint256 defaultLockIndex);
    event RewardBaseTokensAdded(address[] rewardBaseTokens);
    event RewardBaseTokensRemoved(address[] rewardBaseTokens);
    event VaultCapUpdated(uint256 vaultCap);
    event CreditDelegationEnabled(
        address indexed token,
        address indexed leverager
    );
    event CreditDelegationDisabled(
        address indexed token,
        address indexed leverager
    );
    event WithdrawQueued(
        uint256 index,
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event Claimed(uint256 index, address indexed receiver, uint256 assets);

    //============================================================================================//
    //                                           ERROR                                            //
    //============================================================================================//

    error CALLER_NOT_KERNEL();
    error CALLER_NOT_AAVE();
    error FEE_PERCENT_TOO_HIGH(uint256 fee);
    error INVALID_PARAM();
    error EXCEED_BOOSTED_AMOUNT();
    error EXCEED_VAULT_CAP(uint256 vaultCap);
    error TOO_LOW_DEPOSIT();
    error EXCEED_MAX_WITHDRAW();
    error EXCEED_MAX_REDEEM();
    error NOT_CLAIMABLE();
    error ALREADY_CALIMED();

    //============================================================================================//
    //                                         INITIALIZE                                         //
    //============================================================================================//

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(Kernel _kernel) external initializer {
        kernel = _kernel;
        defaultLockIndex = 0;

        DLP.safeApprove(address(MFD), type(uint256).max);

        __ERC20_init(_NAME, _SYMBOL);
        __ERC4626_init(IERC20Upgradeable(address(DLP)));
    }

    receive() external payable {}

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

    modifier onlyLeverager(address initiator) {
        ROLES.requireRole("leverager", initiator);

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
        dependencies = new Keycode[](2);
        dependencies[0] = toKeycode("ROLES");
        dependencies[1] = toKeycode("TRSRY");
        ROLES = ROLESv1(address(kernel.getModuleForKeycode(dependencies[0])));
        treasury = address(kernel.getModuleForKeycode(dependencies[1]));
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

    function setFee(
        uint256 _depositFee,
        uint256 _withdrawFee,
        uint256 _compoundFee
    ) external onlyAdmin {
        if (_depositFee >= MULTIPLIER / 2)
            revert FEE_PERCENT_TOO_HIGH(_depositFee);
        if (_withdrawFee >= MULTIPLIER / 2)
            revert FEE_PERCENT_TOO_HIGH(_withdrawFee);
        if (_compoundFee >= MULTIPLIER / 2)
            revert FEE_PERCENT_TOO_HIGH(_compoundFee);

        fee.depositFee = _depositFee;
        fee.withdrawFee = _withdrawFee;
        fee.compoundFee = _compoundFee;

        emit FeeUpdated(_depositFee, _withdrawFee, _compoundFee);
    }

    function setDefaultLockIndex(uint256 _defaultLockIndex) external onlyAdmin {
        defaultLockIndex = _defaultLockIndex;
        MFD.setDefaultRelockTypeIndex(_defaultLockIndex);

        emit DefaultLockIndexUpdated(_defaultLockIndex);
    }

    function addRewardBaseTokens(
        address[] calldata _rewardBaseTokens,
        bool[] calldata _isATokens,
        bytes32[] calldata _poolIds
    ) external onlyAdmin {
        uint256 length = _rewardBaseTokens.length;
        if (length != _isATokens.length) revert INVALID_PARAM();
        if (length != _poolIds.length) revert INVALID_PARAM();

        for (uint256 i = 0; i < length; ) {
            rewards.push(
                RewardInfo({
                    token: _rewardBaseTokens[i],
                    isAToken: _isATokens[i],
                    poolId: _poolIds[i],
                    pending: 0
                })
            );
            unchecked {
                ++i;
            }
        }

        emit RewardBaseTokensAdded(_rewardBaseTokens);
    }

    function removeRewardBaseTokens(
        address[] calldata _rewardBaseTokens
    ) external onlyAdmin {
        uint256 length = _rewardBaseTokens.length;

        for (uint256 i = 0; i < length; ) {
            uint256 count = rewards.length;

            for (uint256 j = 0; j < count; ) {
                if (rewards[j].token == _rewardBaseTokens[i]) {
                    rewards[j] = rewards[count - 1];
                    delete rewards[count - 1];
                    rewards.pop();
                    break;
                }

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }

        emit RewardBaseTokensRemoved(_rewardBaseTokens);
    }

    function setVaultCap(uint256 _vaultCap) external onlyAdmin {
        vaultCap = _vaultCap;

        emit VaultCapUpdated(_vaultCap);
    }

    function enableCreditDelegation(
        ICreditDelegationToken _token,
        address _leverager
    ) external onlyAdmin {
        _token.approveDelegation(_leverager, type(uint256).max);

        emit CreditDelegationEnabled(address(_token), _leverager);
    }

    function disableCreditDelegation(
        ICreditDelegationToken _token,
        address _leverager
    ) external onlyAdmin {
        _token.approveDelegation(_leverager, 0);

        emit CreditDelegationDisabled(address(_token), _leverager);
    }

    function withdrawTokens(IERC20 _token) external onlyAdmin {
        uint256 amount = _token.balanceOf(address(this));

        if (_token == DLP) {
            _processWithdrawalQueue();
            amount -= claimableDLP;
        }

        if (amount > 0) {
            _token.safeTransfer(msg.sender, amount);
        }
    }

    function boostDLP(uint256 _amount) external onlyAdmin {
        DLP.safeTransferFrom(msg.sender, address(this), _amount);

        boostedDLP += _amount;

        _stakeTokens(_amount);
    }

    function unboostDLP(uint256 _amount) external onlyAdmin {
        if (_amount > boostedDLP) revert EXCEED_BOOSTED_AMOUNT();

        boostedDLP -= _amount;
        queuedDLP += _amount;

        withdrawalQueues.push(
            WithdrawalQueue({
                receiver: msg.sender,
                assets: _amount,
                isClaimed: false
            })
        );
    }

    function getRewardBaseTokens() external view returns (address[] memory) {
        uint256 length = rewards.length;
        address[] memory rewardBaseTokens = new address[](length);

        for (uint256 i = 0; i < length; ) {
            rewardBaseTokens[i] = rewards[i].token;
            unchecked {
                ++i;
            }
        }

        return rewardBaseTokens;
    }

    //============================================================================================//
    //                                       FEE LOGIC                                            //
    //============================================================================================//

    function _sendCompoundFee(uint256 _index, uint256 _harvested) internal {
        if (fee.compoundFee == 0) return;

        RewardInfo storage reward = rewards[_index];
        uint256 feeAmount = (_harvested * fee.compoundFee) / MULTIPLIER;

        IERC20(reward.token).safeTransfer(treasury, feeAmount);

        reward.pending -= feeAmount;
    }

    function _sendDepositFee(uint256 _assets) internal returns (uint256) {
        if (fee.depositFee == 0) return _assets;

        uint256 feeAmount = (_assets * fee.depositFee) / MULTIPLIER;

        DLP.safeTransferFrom(msg.sender, treasury, feeAmount);

        return _assets - feeAmount;
    }

    function _sendMintFee(uint256 _shares) internal returns (uint256) {
        if (fee.depositFee == 0) return _shares;

        uint256 feeShares = (_shares * fee.depositFee) / MULTIPLIER;
        uint256 feeAmount = super.previewMint(feeShares);

        DLP.safeTransferFrom(msg.sender, treasury, feeAmount);

        return _shares - feeShares;
    }

    function _sendWithdrawFee(
        uint256 _assets,
        address _owner
    ) internal returns (uint256) {
        if (fee.withdrawFee == 0) return _assets;

        uint256 feeAssets = (_assets * fee.withdrawFee) / MULTIPLIER;
        uint256 feeAmount = super.previewWithdraw(feeAssets);

        super._transfer(_owner, treasury, feeAmount);

        return _assets - feeAssets;
    }

    function _sendRedeemFee(
        uint256 _shares,
        address _owner
    ) internal returns (uint256) {
        if (fee.withdrawFee == 0) return _shares;

        uint256 feeAmount = (_shares * fee.withdrawFee) / MULTIPLIER;

        super._transfer(_owner, treasury, feeAmount);

        return _shares - feeAmount;
    }

    function getFee()
        external
        view
        override
        returns (uint256 depositFee, uint256 withdrawFee, uint256 compoundFee)
    {
        depositFee = fee.depositFee;
        withdrawFee = fee.withdrawFee;
        compoundFee = fee.compoundFee;
    }

    //============================================================================================//
    //                                     REWARDS LOGIC                                          //
    //============================================================================================//

    function executeOperation(
        address _asset,
        uint256 amount,
        uint256,
        address initiator,
        bytes calldata
    )
        external
        override
        onlyAaveLendingPool
        onlyLeverager(initiator)
        returns (bool success)
    {
        // Repay approval
        if (
            IERC20(_asset).allowance(
                address(this),
                address(AAVE_LENDING_POOL)
            ) == 0
        ) {
            IERC20(_asset).safeApprove(
                address(AAVE_LENDING_POOL),
                type(uint256).max
            );
        }

        uint256 withdrawAmount = amount / 2;
        uint256 amountPlusPremium = withdrawAmount +
            (withdrawAmount * AAVE_LENDING_POOL.FLASHLOAN_PREMIUM_TOTAL()) /
            1e4;

        LENDING_POOL.repay(_asset, amount, 2, address(this));
        LENDING_POOL.withdraw(_asset, amount / 2, initiator);
        LENDING_POOL.withdraw(_asset, amountPlusPremium, address(this));

        return true;
    }

    function compound() public {
        // reward balance before
        uint256 length = rewards.length;
        uint256[] memory balanceBefore = new uint256[](length);

        for (uint256 i = 0; i < length; ) {
            balanceBefore[i] = IERC20(rewards[i].token).balanceOf(
                address(this)
            );
            unchecked {
                ++i;
            }
        }

        // get reward
        MFD.getAllRewards();

        // reward harvested
        uint256 amountWETH;

        for (uint256 i = 0; i < length; ) {
            RewardInfo storage reward = rewards[i];
            uint256 harvested = IERC20(reward.token).balanceOf(address(this)) -
                balanceBefore[i];

            reward.pending += harvested;
            _sendCompoundFee(i, harvested);
            amountWETH += _swapToWETH(i);

            unchecked {
                ++i;
            }
        }

        // add liquidity
        _joinPool(amountWETH);

        // withdraw expired lock
        MFD.withdrawExpiredLocksFor(address(this));

        // process withdrawal queue
        _processWithdrawalQueue();

        // stake
        _stakeDLP();
    }

    function _swapToWETH(uint256 _index) internal returns (uint256) {
        RewardInfo storage reward = rewards[_index];

        if (
            reward.pending <
            (10 ** (IERC20Metadata(reward.token).decimals() - 2))
        ) return 0;
        if (totalSupply() == 0) return 0;

        address swapToken;
        uint256 swapAmount;

        // AToken (withdraw underlying token)
        if (reward.isAToken) {
            IERC20(reward.token).safeApprove(
                address(LENDING_POOL),
                reward.pending
            );

            swapToken = IAToken(reward.token).UNDERLYING_ASSET_ADDRESS();
            swapAmount = LENDING_POOL.withdraw(
                swapToken,
                type(uint256).max,
                address(this)
            );
        }
        // ERC20
        else {
            swapToken = reward.token;
            swapAmount = reward.pending;
        }

        reward.pending = 0;

        // Balancer Swap (REWARD -> WETH)
        IERC20(swapToken).safeApprove(address(VAULT), swapAmount);

        IVault.SingleSwap memory singleSwap;
        singleSwap.poolId = reward.poolId;
        singleSwap.kind = IVault.SwapKind.GIVEN_IN;
        singleSwap.assetIn = IAsset(swapToken);
        singleSwap.assetOut = IAsset(address(VAULT.WETH()));
        singleSwap.amount = swapAmount;

        IVault.FundManagement memory funds;
        funds.sender = address(this);
        funds.recipient = payable(this);

        return VAULT.swap(singleSwap, funds, 0, block.timestamp);
    }

    function _joinPool(uint256 _amountWETH) internal {
        if (_amountWETH == 0) return;

        // Balancer Join Pool (WETH <> RDNT)
        WETH.approve(address(VAULT), _amountWETH);

        IAsset[] memory assets = new IAsset[](1);
        assets[0] = IAsset(address(WETH));

        uint256[] memory maxAmountsIn = new uint256[](1);
        maxAmountsIn[0] = _amountWETH;

        IVault.JoinPoolRequest memory request;
        request.assets = assets;
        request.maxAmountsIn = maxAmountsIn;

        VAULT.joinPool(
            RDNT_WETH_POOL_ID,
            address(this),
            address(this),
            request
        );
    }

    function _stakeDLP() internal {
        uint256 balance = DLP.balanceOf(address(this));

        if (balance > queuedDLP) {
            _stakeTokens(balance - queuedDLP);
        }
    }

    function _stakeTokens(uint256 _amount) internal {
        if (_amount == 0) return;

        MFD.stake(_amount, address(this), defaultLockIndex);
    }

    function _processWithdrawalQueue() internal {
        uint256 balance = DLP.balanceOf(address(this)) - claimableDLP;
        uint256 length = withdrawalQueues.length;

        for (
            uint256 i = 0;
            i < MAX_QUEUE_PROCESS_LIMIT && withdrawalQueueIndex < length;

        ) {
            WithdrawalQueue memory queue = withdrawalQueues[
                withdrawalQueueIndex
            ];

            if (balance < queue.assets) {
                break;
            }

            unchecked {
                balance -= queue.assets;
                claimableDLP += queue.assets;
                ++withdrawalQueueIndex;
                ++i;
            }
        }
    }

    //============================================================================================//
    //                                      ERC4626 OVERRIDES                                     //
    //============================================================================================//

    function deposit(
        uint256 _assets,
        address _receiver
    ) public virtual override returns (uint256) {
        compound();

        _assets = _sendDepositFee(_assets);
        if (totalAssets() + _assets > vaultCap)
            revert EXCEED_VAULT_CAP(totalAssets() + _assets);

        uint256 shares = super.deposit(_assets, _receiver);
        if (shares == 0) revert TOO_LOW_DEPOSIT();

        _stakeDLP();

        return shares;
    }

    function mint(
        uint256 _shares,
        address _receiver
    ) public virtual override returns (uint256) {
        compound();

        _shares = _sendMintFee(_shares);
        if (_shares == 0) revert TOO_LOW_DEPOSIT();

        uint256 assets = super.mint(_shares, _receiver);
        if (totalAssets() > vaultCap) revert EXCEED_VAULT_CAP(totalAssets());

        _stakeDLP();

        return assets;
    }

    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    ) public virtual override returns (uint256) {
        compound();

        _assets = _sendWithdrawFee(_assets, _owner);
        if (_assets > maxWithdraw(_owner)) revert EXCEED_MAX_WITHDRAW();

        uint256 shares = super.previewWithdraw(_assets);
        _withdraw(msg.sender, _receiver, _owner, _assets, shares);

        return shares;
    }

    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    ) public virtual override returns (uint256) {
        compound();

        _shares = _sendRedeemFee(_shares, _owner);
        if (_shares > maxRedeem(_owner)) revert EXCEED_MAX_REDEEM();

        uint256 assets = super.previewRedeem(_shares);
        _withdraw(msg.sender, _receiver, _owner, assets, _shares);

        return assets;
    }

    function claim(uint256 _index) external {
        if (_index >= withdrawalQueueIndex) revert NOT_CLAIMABLE();

        WithdrawalQueue storage queue = withdrawalQueues[_index];
        if (queue.isClaimed) revert ALREADY_CALIMED();

        queue.isClaimed = true;
        queuedDLP -= queue.assets;
        claimableDLP -= queue.assets;

        DLP.safeTransfer(queue.receiver, queue.assets);

        emit Claimed(_index, queue.receiver, queue.assets);
    }

    function _withdraw(
        address _caller,
        address _receiver,
        address _owner,
        uint256 _assets,
        uint256 _shares
    ) internal virtual override {
        if (_caller != _owner) {
            super._spendAllowance(_owner, _caller, _shares);
        }

        super._burn(_owner, _shares);

        queuedDLP += _assets;

        uint256 index = withdrawalQueues.length;
        withdrawalQueues.push(
            WithdrawalQueue({
                receiver: _receiver,
                assets: _assets,
                isClaimed: false
            })
        );

        emit WithdrawQueued(
            index,
            _caller,
            _receiver,
            _owner,
            _assets,
            _shares
        );
    }

    function totalAssets() public view virtual override returns (uint256) {
        return
            (MFD.totalBalance(address(this)) + DLP.balanceOf(address(this))) -
            (queuedDLP + boostedDLP);
    }
}
