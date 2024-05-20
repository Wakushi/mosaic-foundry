// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

import {IDWorkConfig} from "./IDWorkConfig.sol";

interface IWorkVerifier {
    function sendCertificateExtractionRequest(
        uint256 _tokenizationRequestId,
        string[] calldata _args
    ) external;

    function sendWorkVerificationRequest(
        uint256 _tokenizationRequestId,
        string[] calldata _args
    ) external;

    function getLastVerifiedData(
        uint256 _tokenizationRequestId
    ) external view returns (IDWorkConfig.VerifiedWorkData memory);
}
