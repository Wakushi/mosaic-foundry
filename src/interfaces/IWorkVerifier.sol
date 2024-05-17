// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

import {IDWorkConfig} from "./IDWorkConfig.sol";

interface IWorkVerifier {
    function sendCertificateExtractionRequest(string[] calldata _args) external;

    function sendWorkVerificationRequest(string[] calldata _args) external;

    function getLastWorkVerificationResponse()
        external
        view
        returns (IDWorkConfig.WorkVerificationResponse memory);
}
