// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWorkConfig {
    struct dWorkConfig {
        address owner;
        bytes32 donId;
        address functionsRouter;
        uint64 functionsSubId;
        uint32 gasLimit;
        bytes secretReference;
        string workVerificationSource;
        string certificateExtractionSource;
        string customerSubmissionIPFSHash;
        string appraiserReportIPFSHash;
        address customer;
        string workName;
        string workSymbol;
        address factoryAddress;
        address workSharesManagerAddress;
    }
}
