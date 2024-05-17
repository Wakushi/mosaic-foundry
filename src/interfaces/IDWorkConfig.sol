// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWorkConfig {
    struct dWorkConfig {
        address owner;
        string customerSubmissionIPFSHash;
        string appraiserReportIPFSHash;
        address customer;
        string workName;
        string workSymbol;
        address factoryAddress;
        address workSharesManagerAddress;
        address workVerifierAddress;
    }

    struct WorkVerificationResponse {
        bytes32 requestId;
        bytes response;
        bytes err;
    }
}
