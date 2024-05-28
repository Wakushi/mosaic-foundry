// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWorkSharesManager {
    struct WorkShares {
        uint256 maxShareSupply;
        uint256 sharePriceUsd;
        uint256 workTokenId;
        uint256 totalShareBought;
        uint256 totalSellValueUsd;
        address workOwner;
        uint256 redeemableValuePerShare;
        bool isPaused;
        bool isRedeemable;
    }

    function createShares(
        uint256 _workTokenId,
        address _workOwner,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external returns (uint256);

    function onWorkSold(
        uint256 _sharesTokenId,
        uint256 _sellValueUSDC
    ) external;

    function pauseShares(uint256 _tokenizationRequestId) external;

    function unpauseShares(uint256 _tokenizationRequestId) external;
}
