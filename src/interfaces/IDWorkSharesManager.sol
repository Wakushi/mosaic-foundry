// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWorkSharesManager {
    function createShares(
        address _workContract,
        address _workOwner,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external returns (uint256);

    function pauseShares() external;

    function unpauseShares() external;
}
