// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// OpenZeppelin
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";

contract TokenizedAsset is ERC721, ERC721URIStorage, ERC721Burnable {
    ///////////////////
    // Type declarations
    ///////////////////

    struct TokenizedWork {
        string customerSubmissionIPFSHash;
        string appraiserReportIPFSHash;
        string certificateIPFSHash;
        address owner;
        string ownerName;
        uint256 lastWorkPriceUsd;
        uint256 workTokenId;
        uint256 sharesTokenId;
        uint256 listingPriceUsd;
        bool isMinted;
        bool isFractionalized;
        bool isPaused;
        bool isListed;
        uint256 lastVerifiedAt;
        VerificationStep verificationStep;
        WorkCertificate certificate;
    }

    enum VerificationStep {
        PendingCertificateAnalysis,
        CertificateAnalysisDone,
        PendingWorkVerification,
        WorkVerificationDone,
        Tokenized
    }

    struct WorkCertificate {
        string artist;
        string work;
    }

    ///////////////////
    // State variables
    ///////////////////

    /**
     * @dev The tokenizationRequestId is a unique identifier for each tokenization request.
     * As a request could fail or not be fulfilled, the tokenizationRequestId is different from the tokenId
     * which is the unique identifier for each minted work.
     */
    uint256 s_tokenizationRequestId;
    uint256 s_tokenId;

    uint256 constant MIN_VERIFICATION_INTERVAL = 30 days;
    mapping(uint256 tokenizationRequestId => TokenizedWork tokenizedWork) s_tokenizationRequests;
    mapping(uint256 workTokenId => TokenizedWork tokenizedWork) s_tokenizedWorkByTokenId;

    ///////////////////
    // Events
    ///////////////////

    event WorkTokenized(uint256 tokenizationRequestId);

    //////////////////
    // Errors
    //////////////////

    error dWork__TokenPaused();
    error dWork__NotZeroAddress();
    error dWork__ProcessOrderError();
    error dWork__NotEnoughTimePassedSinceLastVerification();
    error dWork__NotWorkOwner();

    //////////////////
    // Modifiers
    //////////////////

    modifier tokenNotPaused(uint256 _tokenId) {
        _ensureTokenNotPaused(_tokenId);
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor() ERC721("TokenizedAsset", "TKA") {}

    ////////////////////
    // External / Public
    ////////////////////

    function approve(
        address to,
        uint256 tokenId
    ) public override(ERC721, IERC721) tokenNotPaused(tokenId) {
        super.approve(to, tokenId);
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721, IERC721) tokenNotPaused(tokenId) {
        super.transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override(ERC721, IERC721) tokenNotPaused(tokenId) {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    ////////////////////
    // Internal
    ////////////////////

    function _registerTokenizationRequest(
        string memory _customerSubmissionIPFSHash,
        string memory _appraiserReportIPFSHash,
        string memory _certificateIPFSHash,
        address _customer,
        uint256 _tokenizationRequestId
    ) internal {
        s_tokenizationRequests[_tokenizationRequestId] = TokenizedWork({
            customerSubmissionIPFSHash: _customerSubmissionIPFSHash,
            appraiserReportIPFSHash: _appraiserReportIPFSHash,
            certificateIPFSHash: _certificateIPFSHash,
            owner: _customer,
            ownerName: "",
            lastWorkPriceUsd: 0,
            workTokenId: 0,
            sharesTokenId: 0,
            lastVerifiedAt: 0,
            listingPriceUsd: 0,
            isMinted: false,
            isFractionalized: false,
            isPaused: false,
            isListed: false,
            verificationStep: VerificationStep.PendingCertificateAnalysis,
            certificate: WorkCertificate({artist: "", work: ""})
        });
    }

    function _createTokenizedWork(
        IDWorkConfig.xChainWorkTokenTransferData memory data
    ) internal {
        _registerTokenizationRequest(
            "",
            "",
            "",
            data.to,
            data.tokenizationRequestId
        );

        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            data.tokenizationRequestId
        ];

        tokenizedWork.workTokenId = data.workTokenId;
        tokenizedWork.ownerName = data.ownerName;
        tokenizedWork.lastWorkPriceUsd = data.lastWorkPriceUsd;
        tokenizedWork.verificationStep = VerificationStep.Tokenized;
        tokenizedWork.isMinted = true;
        tokenizedWork.certificate = WorkCertificate({
            artist: data.artist,
            work: data.work
        });

        if (data.sharesTokenId != 0) {
            tokenizedWork.sharesTokenId = data.sharesTokenId;
            tokenizedWork.isFractionalized = true;
        }
    }

    function _tokenizeWork(
        uint256 _tokenizationRequestId,
        string memory _verifiedOwnerName,
        uint256 _verifiedPriceUsd
    ) internal {
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];

        _mintWork(_tokenizationRequestId);

        tokenizedWork.isMinted = true;
        tokenizedWork.ownerName = _verifiedOwnerName;
        tokenizedWork.lastWorkPriceUsd = _verifiedPriceUsd;
        tokenizedWork.verificationStep = VerificationStep.Tokenized;

        emit WorkTokenized(_tokenizationRequestId);
    }

    function _mintWork(uint256 _tokenizationRequestId) internal {
        ++s_tokenId;
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];
        tokenizedWork.isMinted = true;
        tokenizedWork.workTokenId = s_tokenId;
        s_tokenizedWorkByTokenId[s_tokenId] = tokenizedWork;

        _safeMint(
            s_tokenizationRequests[_tokenizationRequestId].owner,
            s_tokenId
        );
    }

    function _updateTokenizedWorkOnSale(
        TokenizedWork memory tokenizedWork
    ) internal {
        TokenizedWork memory updatedWork = TokenizedWork({
            customerSubmissionIPFSHash: tokenizedWork
                .customerSubmissionIPFSHash,
            appraiserReportIPFSHash: tokenizedWork.appraiserReportIPFSHash,
            certificateIPFSHash: tokenizedWork.certificateIPFSHash,
            owner: msg.sender,
            ownerName: tokenizedWork.ownerName,
            lastWorkPriceUsd: tokenizedWork.listingPriceUsd,
            workTokenId: tokenizedWork.workTokenId,
            sharesTokenId: 0,
            listingPriceUsd: 0,
            isMinted: true,
            isFractionalized: false,
            isPaused: false,
            isListed: false,
            lastVerifiedAt: block.timestamp,
            verificationStep: VerificationStep.Tokenized,
            certificate: tokenizedWork.certificate
        });

        s_tokenizedWorkByTokenId[tokenizedWork.workTokenId] = updatedWork;
    }

    function _pauseWorkToken(uint256 _tokenizationRequestId) internal {
        s_tokenizationRequests[_tokenizationRequestId].isPaused = true;
    }

    function _unpauseWorkToken(uint256 _tokenizationRequestId) internal {
        s_tokenizationRequests[_tokenizationRequestId].isPaused = false;
    }

    function _ensureNotZeroAddress(address _address) internal pure {
        if (_address == address(0)) {
            revert dWork__NotZeroAddress();
        }
    }

    function _ensureProcessOrder(
        uint256 _tokenizationRequestId,
        VerificationStep _requiredStep
    ) internal view {
        if (
            s_tokenizationRequests[_tokenizationRequestId].verificationStep <
            _requiredStep
        ) {
            revert dWork__ProcessOrderError();
        }
    }

    function _ensureEnoughTimePassedSinceLastVerification(
        uint256 _tokenizationRequestId
    ) internal view {
        uint256 lastVerifiedAt = s_tokenizationRequests[_tokenizationRequestId]
            .lastVerifiedAt;
        if (
            lastVerifiedAt != 0 &&
            block.timestamp - lastVerifiedAt < MIN_VERIFICATION_INTERVAL
        ) {
            revert dWork__NotEnoughTimePassedSinceLastVerification();
        }
    }

    function _ensureWorkOwner(address _owner) internal view {
        if (msg.sender != _owner) {
            revert dWork__NotWorkOwner();
        }
    }

    function _ensureTokenNotPaused(uint256 _tokenId) internal view {
        if (s_tokenizedWorkByTokenId[_tokenId].isPaused) {
            revert dWork__TokenPaused();
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return
            super.supportsInterface(interfaceId) ||
            interfaceId == type(ERC721Burnable).interfaceId;
    }
}
