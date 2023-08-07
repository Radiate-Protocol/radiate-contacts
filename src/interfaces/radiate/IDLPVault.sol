// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

interface IDLPVault {
    function getFee()
        external
        view
        returns (uint256 depositFee, uint256 withdrawFee, uint256 compoundFee);
}
