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

    struct xChainWorkTokenTransferData {
        address to;
        uint256 workTokenId;
        string ownerName;
        uint256 lastWorkPriceUsd;
        string artist;
        string work;
        uint256 sharesTokenId;
        uint256 tokenizationRequestId;
    }
}
