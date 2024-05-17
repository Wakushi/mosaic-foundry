// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWork {
    function isMinted() external view returns (bool);

    function isFractionalized() external view returns (bool);

    function setWorkSharesTokenId(uint256 _sharesTokenId) external;

    function getWorkPriceUsd() external view returns (uint256);

    function getWorkOwner() external view returns (address);

    function fulfillCertificateExtractionRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err,
        string memory certificateImageHash
    ) external;

    function fulfillWorkVerificationRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) external;
}
