// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IScaledUIAmount {
    function uiMultiplier() external view returns (uint256);
}

interface IPendingUIAmount {
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}
