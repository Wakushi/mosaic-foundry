// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWorkConfig {
    struct dWorkConfig {
        address initialOwner;
        bytes32 donId;
        address functionsRouter;
        uint64 functionsSubId;
        uint32 gasLimit;
        bytes secretReference;
        string workVerificationSource;
        string certificateExtractionSource;
        address customer;
        string workName;
        string workSymbol;
        address factoryAddress;
    }
}
