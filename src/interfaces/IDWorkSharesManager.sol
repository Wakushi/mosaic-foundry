// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWorkSharesManager {
    function createShares(
        uint256 _workTokenId,
        address _workOwner,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external returns (uint256);

    function onWorkSold(uint256 _sharesTokenId) external payable;

    function pauseShares(uint256 _tokenizationRequestId) external;

    function unpauseShares(uint256 _tokenizationRequestId) external;
}
