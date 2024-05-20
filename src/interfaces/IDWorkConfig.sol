// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWorkConfig {
    struct dWorkConfig {
        address workSharesManagerAddress;
        address workVerifierAddress;
    }

    struct VerifiedWorkData {
        string artist;
        string work;
        string ownerName;
        uint256 priceUsd;
    }
}
