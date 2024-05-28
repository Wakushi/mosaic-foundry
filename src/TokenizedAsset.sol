// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// OpenZeppelin
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";
import {IWorkVerifier} from "./interfaces/IWorkVerifier.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TokenizedAsset is ERC721, ERC721Burnable, Ownable {
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

    /**
     * @dev The tokenizationRequestId is a unique identifier for each tokenization request.
     * As a request could fail or not be fulfilled, the tokenizationRequestId is different from the tokenId
     * which is the unique identifier for each minted work.
     */
    uint256 s_tokenizationRequestId;
    uint256 s_tokenId;

    address s_workVerifier;
    address s_workSharesManager;

    uint256 constant POLYGON_AMOY_CHAIN_ID = 80002;
    uint256 constant OPTIMISM_SEPOLIA_CHAIN_ID = 11155420;
    uint256 constant MIN_VERIFICATION_INTERVAL = 30 days;
    mapping(uint256 tokenizationRequestId => TokenizedWork tokenizedWork) s_tokenizationRequests;
    mapping(uint256 workTokenId => uint256 tokenizationRequestId) s_tokenizationRequestIdByTokenId;

    event WorkSharesCreated(
        uint256 sharesTokenId,
        uint256 workTokenId,
        uint256 shareSupply
    );
    event VerificationProcess(
        uint256 tokenizationRequestId,
        VerificationStep step
    );
    event CertificateExtractionError(uint256 indexed tokenizationRequestId);
    event WorkVerificationError(uint256 tokenizationRequestId);
    event LastVerificationFailed(
        string previousOwner,
        uint256 previousPrice,
        string newOwner,
        uint256 newPrice
    );

    error dWork__TokenPaused();
    error dWork__NotZeroAddress();
    error dWork__ProcessOrderError();
    error dWork__NotEnoughTimePassedSinceLastVerification();
    error dWork__NotWorkOwner();
    error dWork__OnlyOnPolygonAmoy();
    error dWork__AlreadyFractionalized();
    error dWork__TokenizationNotCompleted();

    modifier tokenNotPaused(uint256 _tokenId) {
        _ensureTokenNotPaused(_tokenId);
        _;
    }

    modifier onlyOnPolygonAmoy() {
        if (block.chainid != POLYGON_AMOY_CHAIN_ID) {
            revert dWork__OnlyOnPolygonAmoy();
        }
        _;
    }

    constructor(
        address _workVerifier,
        address _workSharesManager
    ) ERC721("xArtwork", "xART") Ownable(msg.sender) {
        s_workVerifier = _workVerifier;
        s_workSharesManager = _workSharesManager;
    }

    /**
     * @notice Fractionalize a tokenized work of art into shares tokens.
     * @dev Tasks the WorkSharesManager contract to create ERC1155 shares tokens for the work.
     * This function can only be called after the work has been minted as an ERC721 token.
     */
    function createWorkShares(
        uint256 _tokenizationRequestId,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external onlyOwner onlyOnPolygonAmoy {
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];

        if (!tokenizedWork.isMinted) {
            revert dWork__TokenizationNotCompleted();
        }

        if (tokenizedWork.isFractionalized) {
            revert dWork__AlreadyFractionalized();
        }

        tokenizedWork.isFractionalized = true;

        address workOwner = ownerOf(tokenizedWork.workTokenId);

        uint256 sharesTokenId = IDWorkSharesManager(s_workSharesManager)
            .createShares(
                tokenizedWork.workTokenId,
                workOwner,
                _shareSupply,
                _sharePriceUsd
            );

        tokenizedWork.sharesTokenId = sharesTokenId;

        emit WorkSharesCreated(
            sharesTokenId,
            tokenizedWork.workTokenId,
            _shareSupply
        );
    }

    function approve(
        address to,
        uint256 tokenId
    ) public override(ERC721) tokenNotPaused(tokenId) {
        super.approve(to, tokenId);
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721) tokenNotPaused(tokenId) {
        super.transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override(ERC721) tokenNotPaused(tokenId) {
        super.safeTransferFrom(from, to, tokenId, data);
    }

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
        IDWorkConfig.xChainWorkTokenTransferData memory _workData
    ) internal {
        _registerTokenizationRequest(
            "",
            "",
            "",
            _workData.to,
            _workData.tokenizationRequestId
        );

        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            _workData.tokenizationRequestId
        ];

        tokenizedWork.workTokenId = _workData.workTokenId;
        tokenizedWork.ownerName = _workData.ownerName;
        tokenizedWork.lastWorkPriceUsd = _workData.lastWorkPriceUsd;
        tokenizedWork.verificationStep = VerificationStep.Tokenized;
        tokenizedWork.isMinted = true;
        tokenizedWork.certificate = WorkCertificate({
            artist: _workData.artist,
            work: _workData.work
        });

        if (_workData.sharesTokenId != 0) {
            tokenizedWork.sharesTokenId = _workData.sharesTokenId;
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

        _mintWork(tokenizedWork.owner);

        tokenizedWork.isMinted = true;
        tokenizedWork.workTokenId = s_tokenId;
        s_tokenizationRequestIdByTokenId[s_tokenId] = _tokenizationRequestId;
        tokenizedWork.ownerName = _verifiedOwnerName;
        tokenizedWork.lastWorkPriceUsd = _verifiedPriceUsd;
        tokenizedWork.verificationStep = VerificationStep.Tokenized;

        emit VerificationProcess(
            _tokenizationRequestId,
            VerificationStep.Tokenized
        );
    }

    function _mintWork(address _owner) internal {
        ++s_tokenId;
        _safeMint(_owner, s_tokenId);
    }

    function _sendCertificateExtractionRequest(
        uint256 _tokenizationRequestId,
        string memory _certificateIPFSHash
    ) internal {
        string[] memory _args = new string[](1);
        _args[0] = _certificateIPFSHash;

        IWorkVerifier(s_workVerifier).sendCertificateExtractionRequest(
            _tokenizationRequestId,
            _args
        );

        emit VerificationProcess(
            _tokenizationRequestId,
            VerificationStep.PendingCertificateAnalysis
        );
    }

    function _sendWorkVerificationRequest(
        uint256 _tokenizationRequestId
    ) internal {
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];

        string[] memory _args = new string[](4);
        _args[0] = tokenizedWork.customerSubmissionIPFSHash;
        _args[1] = tokenizedWork.appraiserReportIPFSHash;
        _args[2] = tokenizedWork.certificate.artist;
        _args[3] = tokenizedWork.certificate.work;

        tokenizedWork.verificationStep = VerificationStep
            .PendingWorkVerification;

        IWorkVerifier(s_workVerifier).sendWorkVerificationRequest(
            _tokenizationRequestId,
            _args
        );

        emit VerificationProcess(
            _tokenizationRequestId,
            VerificationStep.PendingWorkVerification
        );
    }

    function _fulfillCertificateExtractionRequest(
        uint256 _tokenizationRequestId,
        string memory _artist,
        string memory _work
    ) internal {
        // Within the Chainlink Functions request, gpt-4o is instructed to return empty strings if he can't extract the artist and work from the certificate.
        if (bytes(_artist).length == 0 || bytes(_work).length == 0) {
            emit CertificateExtractionError(_tokenizationRequestId);
            return;
        }

        WorkCertificate memory workCertificate = WorkCertificate({
            artist: _artist,
            work: _work
        });

        s_tokenizationRequests[_tokenizationRequestId]
            .certificate = workCertificate;
        s_tokenizationRequests[_tokenizationRequestId]
            .verificationStep = VerificationStep.CertificateAnalysisDone;

        emit VerificationProcess(
            _tokenizationRequestId,
            VerificationStep.CertificateAnalysisDone
        );
    }

    function _fulfillWorkVerificationRequest(
        uint256 _tokenizationRequestId,
        string memory _ownerName,
        uint256 _priceUsd
    ) internal {
        // Within the Chainlink Functions request, the computation will return a price of 0 if discrepancies are found.
        if (_priceUsd == 0) {
            emit WorkVerificationError(_tokenizationRequestId);
            return;
        }

        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];
        tokenizedWork.verificationStep = VerificationStep.WorkVerificationDone;
        s_tokenizationRequests[_tokenizationRequestId].lastVerifiedAt = block
            .timestamp;

        // If the work was already minted, we compare the latest appraiser report with the previous one.
        if (tokenizedWork.isMinted) {
            _compareLatestAppraiserReport(
                _tokenizationRequestId,
                _ownerName,
                _priceUsd
            );
        } else {
            _tokenizeWork(_tokenizationRequestId, _ownerName, _priceUsd);
        }

        emit VerificationProcess(
            _tokenizationRequestId,
            tokenizedWork.verificationStep
        );
    }

    /**
     * @dev Compare the latest appraiser report with the previous one to verify the work.
     * If there is a significant difference, freeze the work contract as well as the minted shares tokens.
     */
    function _compareLatestAppraiserReport(
        uint256 _tokenizationRequestId,
        string memory _ownerName,
        uint256 _priceUsd
    ) internal {
        TokenizedWork memory tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];
        if (
            (keccak256(abi.encodePacked(_ownerName)) !=
                keccak256(abi.encodePacked(tokenizedWork.ownerName))) ||
            _priceUsd != tokenizedWork.lastWorkPriceUsd
        ) {
            s_tokenizationRequests[_tokenizationRequestId].isPaused = true;
            if (tokenizedWork.isFractionalized) {
                IDWorkSharesManager(s_workSharesManager).pauseShares(
                    _tokenizationRequestId
                );
            }
            emit LastVerificationFailed(
                tokenizedWork.ownerName,
                tokenizedWork.lastWorkPriceUsd,
                _ownerName,
                _priceUsd
            );
        } else {
            if (tokenizedWork.isPaused) {
                s_tokenizationRequests[_tokenizationRequestId].isPaused = false;
                IDWorkSharesManager(s_workSharesManager).unpauseShares(
                    _tokenizationRequestId
                );
            }
        }
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

        s_tokenizationRequests[s_tokenizationRequestId] = updatedWork;
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
        if (
            s_tokenizationRequests[s_tokenizationRequestIdByTokenId[_tokenId]]
                .isPaused
        ) {
            revert dWork__TokenPaused();
        }
    }

    function getTokenizationRequestByWorkId(
        uint256 _workId
    ) public view returns (TokenizedWork memory) {
        return
            s_tokenizationRequests[s_tokenizationRequestIdByTokenId[_workId]];
    }
}
