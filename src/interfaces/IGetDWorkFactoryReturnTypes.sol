// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IGetDWorkFactoryReturnTypes {
    struct GetDWorkFactoryReturnType {
        address functionsRouter;
        bytes32 donId;
        string workVerificationSource;
        string certificateExtractionSource;
        address priceFeed;
    }
}
