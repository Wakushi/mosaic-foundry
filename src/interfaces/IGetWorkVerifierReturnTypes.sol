// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IGetWorkVerifierReturnTypes {
    struct GetWorkVerifierReturnType {
        address functionsRouter;
        bytes32 donId;
        bytes secretReference;
        uint64 functionsSubId;
        string workVerificationSource;
        string certificateExtractionSource;
    }
}
