// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;
pragma abicoder v2;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {Kernel, Keycode, Permissions, toKeycode, Policy} from "../Kernel.sol";
import {RolesConsumer, ROLESv1} from "../modules/ROLES/OlympusRoles.sol";

import {IDLPVault} from "../interfaces/radiate/IDLPVault.sol";
import {IAToken} from "../interfaces/radiant-interfaces/IAToken.sol";
import {ILendingPool, DataTypes} from "../interfaces/radiant-interfaces/ILendingPool.sol";
import {IVariableDebtToken} from "../interfaces/radiant-interfaces/IVariableDebtToken.sol";
import {IPool} from "../interfaces/aave/IPool.sol";

contract Leverager is RolesConsumer, Policy, ERC4626 {
    using SafeERC20 for IERC20;

    //============================================================================================//
    //                                         CONSTANT                                           //
    //============================================================================================//

    /// @notice Lending Pool address
    ILendingPool public constant LENDING_POOL =
        ILendingPool(0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1);

    /// @notice Aave lending pool address (for flashloans)
    IPool public constant AAVE_LENDING_POOL =
        IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    /// @notice Multiplier 100%
    uint256 public constant MULTIPLIER = 1e6;

    //============================================================================================//
    //                                          STORAGE                                           //
    //============================================================================================//

    /// @notice treasury wallet
    address public treasury;

    /// @notice `True` when emergency unlooping
    bool public emergencyUnlooping;

    /// @notice Minimum invest amount
    uint256 public immutable minAmountToInvest;

    /// @notice vault cap
    uint256 public vaultCap;

    /// @notice Loop count
    uint256 public loopCount;

    /// @notice Borrow ratio
    uint256 public borrowRatio;

    /// @notice Dlp vault contract
    IDLPVault public immutable dlpVault;

    //============================================================================================//
    //                                           EVENT                                            //
    //============================================================================================//

    event VaultCapUpdated(uint256 vaultCap);
    event LoopCountUpdated(uint256 loopCount);
    event BorrowRatioUpdated(uint256 borrowRatio);
    event Unloop(uint256 amount);
    event EmergencyUnloop(uint256 amount);

    //============================================================================================//
    //                                           ERROR                                            //
    //============================================================================================//

    error INVALID_AMOUNT();
    error EXCEED_VAULT_CAP(uint256 vaultCap);
    error ERROR_BORROW_RATIO(uint256 borrowRatio);
    error CANNOT_WITHDRAW_AFTER_EMERGENCY_UNLOOP();
    error TOO_LOW_DEPOSIT();
    error EXCEED_MAX_WITHDRAW();
    error LOOP_COUNT_TOO_BIG();

    //============================================================================================//
    //                                         INITIALIZE                                         //
    //============================================================================================//

    constructor(
        uint256 _minAmountToInvest,
        uint256 _vaultCap,
        uint256 _loopCount,
        uint256 _borrowRatio,
        IDLPVault _dlpVault,
        IERC20Metadata _asset,
        Kernel _kernel
    )
        Policy(_kernel)
        ERC4626(_asset)
        ERC20(
            string(abi.encodePacked("Radiate ", _asset.name())),
            string(abi.encodePacked("rd-", _asset.symbol()))
        )
    {
        if (_minAmountToInvest == 0) revert INVALID_AMOUNT();
        if (_borrowRatio > MULTIPLIER) revert ERROR_BORROW_RATIO(_borrowRatio);

        minAmountToInvest = _minAmountToInvest;
        vaultCap = _vaultCap;
        loopCount = _loopCount;
        borrowRatio = _borrowRatio;
        dlpVault = _dlpVault;
    }

    //============================================================================================//
    //                                          MODIFIER                                          //
    //============================================================================================//

    modifier onlyAdmin() {
        ROLES.requireRole("admin", msg.sender);

        _;
    }

    //============================================================================================//
    //                                     DEFAULT OVERRIDES                                      //
    //============================================================================================//

    function configureDependencies()
        external
        override
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](2);
        dependencies[0] = toKeycode("ROLES");
        dependencies[1] = toKeycode("TRSRY");
        ROLES = ROLESv1(getModuleAddress(dependencies[0]));
        treasury = getModuleAddress(dependencies[1]);
    }

    function requestPermissions()
        external
        pure
        override
        returns (Permissions[] memory requests)
    {
        requests = new Permissions[](0);
    }

    //============================================================================================//
    //                                         ADMIN                                              //
    //============================================================================================//

    /// @dev set vault cap (scaled by asset.decimals)
    function setVaultCap(uint256 _vaultCap) external onlyAdmin {
        vaultCap = _vaultCap;

        emit VaultCapUpdated(_vaultCap);
    }

    /// @dev Set loop count for any new deposits
    function setLoopCount(uint256 _loopCount) external onlyAdmin {
        if (loopCount > 20) revert LOOP_COUNT_TOO_BIG();
        loopCount = _loopCount;

        emit LoopCountUpdated(_loopCount);
    }

    /// @dev Set borrow ratio for any new deposits
    function setBorrowRatio(uint256 _borrowRatio) external onlyAdmin {
        if (_borrowRatio > MULTIPLIER) revert ERROR_BORROW_RATIO(_borrowRatio);

        borrowRatio = _borrowRatio;

        emit BorrowRatioUpdated(_borrowRatio);
    }

    /// @dev Emergency Unloop – withdraws all funds from Radiant to vault
    /// For migrations, or in case of emergency
    function emergencyUnloop(uint256 _amount) external onlyAdmin {
        _unloop(_amount);
        emergencyUnlooping = true;

        emit EmergencyUnloop(_amount);
    }

    function recoverERC20(
        IERC20 _token,
        uint256 _tokenAmount
    ) external onlyAdmin {
        if (address(_token) == asset() && emergencyUnlooping) {
            revert CANNOT_WITHDRAW_AFTER_EMERGENCY_UNLOOP();
        }
        _token.safeTransfer(msg.sender, _tokenAmount);
    }

    //============================================================================================//
    //                                     LOOPING LOGIC                                          //
    //============================================================================================//

    /**
     * @dev Returns the configuration of the reserve
     * @param _asset The address of the underlying asset of the reserve
     * @return The configuration of the reserve
     *
     */
    function getConfiguration(
        address _asset
    ) public view returns (DataTypes.ReserveConfigurationMap memory) {
        return LENDING_POOL.getConfiguration(_asset);
    }

    /**
     * @dev Returns variable debt token address of asset
     * @param _asset The address of the underlying asset of the reserve
     * @return varaiableDebtToken address of the asset
     *
     */
    function getVDebtToken(address _asset) public view returns (address) {
        DataTypes.ReserveData memory reserveData = LENDING_POOL.getReserveData(
            _asset
        );
        return reserveData.variableDebtTokenAddress;
    }

    /**
     * @dev Returns atoken address of asset
     * @param _asset The address of the underlying asset of the reserve
     * @return varaiableDebtToken address of the asset
     *
     */
    function getAToken(address _asset) public view returns (address) {
        DataTypes.ReserveData memory reserveData = LENDING_POOL.getReserveData(
            _asset
        );
        return reserveData.aTokenAddress;
    }

    /**
     * @dev Returns loan to value
     * @param asset_ The address of the underlying asset of the reserve
     * @return ltv of the asset
     *
     */
    function ltv(address asset_) public view returns (uint256) {
        DataTypes.ReserveConfigurationMap memory conf = LENDING_POOL
            .getConfiguration(asset_);
        return conf.data % (2 ** 16);
    }

    /**
     * @dev Loop the deposit and borrow of an asset (removed eth loop, deposit WETH directly)
     *
     */
    function _loop() internal {
        uint16 referralCode = 0;
        IERC20 baseAsset = IERC20(asset());
        uint256 amount = baseAsset.balanceOf(address(this));
        uint256 interestRateMode = 2; // variable

        if (baseAsset.allowance(address(this), address(LENDING_POOL)) == 0) {
            baseAsset.safeApprove(address(LENDING_POOL), type(uint256).max);
        }

        LENDING_POOL.deposit(
            address(baseAsset),
            amount,
            address(dlpVault),
            referralCode
        );

        for (uint256 i = 0; i < loopCount; ) {
            amount = (amount * borrowRatio) / MULTIPLIER;

            LENDING_POOL.borrow(
                address(baseAsset),
                amount,
                interestRateMode,
                referralCode,
                address(dlpVault)
            );

            LENDING_POOL.deposit(
                address(baseAsset),
                amount,
                address(dlpVault),
                referralCode
            );

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Loop the withdraw and repay of an asset
     * @param _amount of tokens to free from loop
     */
    function _unloop(uint256 _amount) internal {
        bytes memory params = "";
        AAVE_LENDING_POOL.flashLoanSimple(
            address(dlpVault),
            asset(),
            _amount * 2,
            params,
            0
        );

        emit Unloop(_amount);
    }

    /**
     * @dev Unloop if needed
     */
    function _unloopIfNeeded(
        uint256 _amount
    ) internal returns (uint256 flashLoanFee) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));

        if (_amount > balance) {
            uint256 amountToWithdraw = _amount - balance;
            flashLoanFee =
                (amountToWithdraw *
                    2 *
                    AAVE_LENDING_POOL.FLASHLOAN_PREMIUM_TOTAL()) /
                1e4;

            _unloop(amountToWithdraw);
        }
    }

    //============================================================================================//
    //                                       FEE LOGIC                                            //
    //============================================================================================//

    function _sendDepositFee(uint256 _assets) internal returns (uint256) {
        (uint256 depositFee, , ) = dlpVault.getFee();
        if (depositFee == 0) return _assets;

        uint256 feeAmount = (_assets * depositFee) / MULTIPLIER;

        IERC20(asset()).safeTransferFrom(msg.sender, treasury, feeAmount);

        return _assets - feeAmount;
    }

    function _sendMintFee(uint256 _shares) internal returns (uint256) {
        (uint256 depositFee, , ) = dlpVault.getFee();
        if (depositFee == 0) return _shares;

        uint256 feeShares = (_shares * depositFee) / MULTIPLIER;
        uint256 feeAmount = super.previewMint(feeShares);

        IERC20(asset()).safeTransferFrom(msg.sender, treasury, feeAmount);

        return _shares - feeShares;
    }

    function _sendWithdrawFee(
        uint256 _assets,
        address _owner
    ) internal returns (uint256) {
        (, uint256 withdrawFee, ) = dlpVault.getFee();
        if (withdrawFee == 0) return _assets;

        uint256 feeAssets = (_assets * withdrawFee) / MULTIPLIER;
        uint256 feeAmount = super.previewWithdraw(feeAssets);

        super._transfer(_owner, treasury, feeAmount);

        return _assets - feeAssets;
    }

    function _sendRedeemFee(
        uint256 _shares,
        address _owner
    ) internal returns (uint256) {
        (, uint256 withdrawFee, ) = dlpVault.getFee();
        if (withdrawFee == 0) return _shares;

        uint256 feeAmount = (_shares * withdrawFee) / MULTIPLIER;

        super._transfer(_owner, treasury, feeAmount);

        return _shares - feeAmount;
    }

    function _sendFlashLoanFee(
        uint256 _assets,
        address _owner
    ) internal returns (uint256) {
        uint256 feeAmount = super.previewWithdraw(_assets);

        super._transfer(_owner, treasury, feeAmount);

        return feeAmount;
    }

    //============================================================================================//
    //                                      ERC4626 OVERRIDES                                     //
    //============================================================================================//

    function totalAssets() public view override returns (uint256) {
        IERC20 baseAsset = IERC20(asset());
        DataTypes.ReserveData memory reserveData = LENDING_POOL.getReserveData(
            address(baseAsset)
        );
        IAToken aToken = IAToken(reserveData.aTokenAddress);
        IVariableDebtToken vdToken = IVariableDebtToken(
            reserveData.variableDebtTokenAddress
        );
        uint256 amount = aToken.scaledBalanceOf(address(dlpVault));
        uint256 debt = vdToken.scaledBalanceOf(address(dlpVault));

        return baseAsset.balanceOf(address(this)) + amount - debt;
    }

    function deposit(
        uint256 _assets,
        address _receiver
    ) public virtual override returns (uint256) {
        _assets = _sendDepositFee(_assets);
        if (totalAssets() + _assets > vaultCap) {
            revert EXCEED_VAULT_CAP(totalAssets() + _assets);
        }

        uint256 shares = super.deposit(_assets, _receiver);
        if (shares == 0) revert TOO_LOW_DEPOSIT();

        _loop();

        return shares;
    }

    function mint(
        uint256 _shares,
        address _receiver
    ) public virtual override returns (uint256) {
        _shares = _sendMintFee(_shares);
        if (_shares == 0) revert TOO_LOW_DEPOSIT();

        uint256 assets = super.mint(_shares, _receiver);
        if (totalAssets() > vaultCap) revert EXCEED_VAULT_CAP(totalAssets());

        _loop();

        return assets;
    }

    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    ) public virtual override returns (uint256) {
        _assets = _sendWithdrawFee(_assets, _owner);

        uint256 flashLoanFee = _unloopIfNeeded(_assets);
        _sendFlashLoanFee(flashLoanFee, _owner);

        uint256 shares = super.withdraw(
            _assets - flashLoanFee,
            _receiver,
            _owner
        );

        return shares;
    }

    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    ) public virtual override returns (uint256) {
        _shares = _sendRedeemFee(_shares, _owner);

        uint256 assets = super.previewRedeem(_shares);
        uint256 flashLoanFee = _unloopIfNeeded(assets);
        _shares -= _sendFlashLoanFee(flashLoanFee, _owner);

        assets = super.redeem(_shares, _receiver, _owner);

        return assets;
    }
}
