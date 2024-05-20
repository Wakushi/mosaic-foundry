// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";
import {IWorkVerifier} from "./interfaces/IWorkVerifier.sol";
import {Log, ILogAutomation} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";

contract dWork is
    ILogAutomation,
    ERC721,
    ERC721URIStorage,
    ERC721Burnable,
    Ownable,
    Pausable
{
    ///////////////////
    // Type declarations
    ///////////////////

    using OracleLib for AggregatorV3Interface;

    enum VerificationStep {
        PendingCertificateAnalysis,
        CertificateAnalysisDone,
        PendingWorkVerification,
        WorkVerificationDone,
        PendingTokenization,
        Tokenized
    }

    struct TokenizationRequest {
        string customerSubmissionIPFSHash;
        string appraiserReportIPFSHash;
        string certificateIPFSHash;
        address customer;
        string initialOwnerName;
        uint256 lastWorkPriceUsd;
        uint256 tokenId;
        uint256 sharesTokenId;
        bool isMinted;
        bool isFractionalized;
        bool isPaused;
        uint256 lastVerifiedAt;
        VerificationStep verificationStep;
        WorkCertificate certificate;
    }

    struct WorkCertificate {
        string artist;
        string work;
    }

    ///////////////////
    // State variables
    ///////////////////

    uint256 s_tokenizationRequestId;
    uint256 s_tokenId;

    bytes public s_lastPerformData;

    mapping(uint256 tokenizationRequestId => TokenizationRequest tokenizationRequest) s_tokenizationRequests;
    mapping(address customer => uint256[] tokenizationRequestsIds) s_customerTokenizationRequests;
    mapping(uint256 tokenizationRequestId => uint256 sharesTokenId) s_sharesTokenIds;
    mapping(uint256 workTokenId => TokenizationRequest tokenizationRequest) s_tokenById;

    uint256 constant MIN_VERIFICATION_INTERVAL = 30 days;
    address s_workSharesManager;
    address s_workVerifier;

    bytes s_lastVerifierResponse;
    bytes s_lastVerifierError;

    ///////////////////
    // Events
    ///////////////////

    event WorkFractionalized(uint256 sharesTokenId);
    event VerificationProcess(
        uint256 tokenizationRequestId,
        VerificationStep step
    );
    event CertificateExtracted(
        uint256 tokenizationRequestId,
        WorkCertificate certificate
    );
    event WorkTokenized(uint256 tokenizationRequestId);
    event LastVerificationFailed(
        string previousOwner,
        uint256 previousPrice,
        string newOwner,
        uint256 newPrice
    );
    event WorkSharesCreated(
        uint256 sharesTokenId,
        uint256 workTokenId,
        uint256 shareSupply
    );
    event CertificateExtractionError(uint256 tokenizationRequestId);
    event WorkVerificationError(uint256 tokenizationRequestId);

    //////////////////
    // Errors
    ///////////////////

    error dWork__WorkNotMinted();
    error dWork__AlreadyFractionalized();
    error dWork__ProcessOrderError();
    error dWork__NotEnoughTimePassedSinceLastVerification();
    error dWork__WorkVerificationNotExpected();
    error dWork__NotZeroAddress();
    error dWork__TokenPaused();

    //////////////////
    // Modifiers
    //////////////////

    modifier notZeroAddress(address _address) {
        _ensureNotZeroAddress(_address);
        _;
    }

    modifier verifyProcessOrder(
        uint256 _tokenizationRequestId,
        VerificationStep _requiredStep
    ) {
        _ensureProcessOrder(_tokenizationRequestId, _requiredStep);
        _;
    }

    modifier tokenNotPaused(uint256 _tokenId) {
        _ensureTokenNotPaused(_tokenId);
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor(
        address _workSharesManager,
        address _workVerifier
    ) Ownable(msg.sender) ERC721("xArtwork", "xART") {
        s_workSharesManager = _workSharesManager;
        s_workVerifier = _workVerifier;
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
     *
     * @param _customerSubmissionIPFSHash The IPFS hash of the customer submission.
     * @param _appraiserReportIPFSHash The IPFS hash of the appraiser report.
     * @param _certificateIPFSHash The IPFS hash of the certificate image.
     * @param _customer The address of the customer who submitted the work.
     * @notice Open a new tokenization request for a work of art. It registers the initial data and tasks the WorkVerifier contract to extract the certificate of authenticity.
     */
    function openTokenizationRequest(
        string memory _customerSubmissionIPFSHash,
        string memory _appraiserReportIPFSHash,
        string memory _certificateIPFSHash,
        address _customer
    ) external onlyOwner notZeroAddress(_customer) {
        ++s_tokenizationRequestId;
        s_tokenizationRequests[s_tokenizationRequestId] = TokenizationRequest({
            customerSubmissionIPFSHash: _customerSubmissionIPFSHash,
            appraiserReportIPFSHash: _appraiserReportIPFSHash,
            certificateIPFSHash: _certificateIPFSHash,
            customer: _customer,
            initialOwnerName: "",
            lastWorkPriceUsd: 0,
            tokenId: 0,
            sharesTokenId: 0,
            isMinted: false,
            isFractionalized: false,
            lastVerifiedAt: 0,
            isPaused: false,
            verificationStep: VerificationStep.PendingCertificateAnalysis,
            certificate: WorkCertificate({artist: "", work: ""})
        });
        s_customerTokenizationRequests[_customer].push(s_tokenizationRequestId);
        _sendCertificateExtractionRequest(
            s_tokenizationRequestId,
            _certificateIPFSHash
        );
    }

    /**
     * @notice Request the work verification using all aggregated data.
     * @dev Tasks the WorkVerifier contract to fetch and organize all data sources using OpenAI GPT-4o through Chainlink Functions.
     * This request will fetch the data from the customer submission, the appraiser report and global market data,
     * join the certificate data obtained by _sendCertificateExtractionRequest() and logically verify the work.
     * Once the request is fulfilled, the _fulfillWorkVerificationRequest() function will be called on this contract to mint the work as an ERC721 token.
     *
     * Note: This function has to be called after the certificate extraction request is fulfilled, and then
     * will be called every 3 months with the latest appraiser report using Chainlink Automation.
     */
    function requestWorkVerification(
        uint256 _tokenizationRequestId
    )
        external
        verifyProcessOrder(
            _tokenizationRequestId,
            VerificationStep.CertificateAnalysisDone
        )
    {
        if (isMinted(_tokenizationRequestId)) {
            _ensureEnoughTimePassedSinceLastVerification(
                _tokenizationRequestId
            );
        }
        _sendWorkVerificationRequest(_tokenizationRequestId);
    }

    function createWorkShares(
        uint256 _tokenizationRequestId,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external onlyOwner {
        TokenizationRequest
            storage tokenizationRequest = s_tokenizationRequests[
                _tokenizationRequestId
            ];

        if (!tokenizationRequest.isMinted) {
            revert dWork__WorkNotMinted();
        }

        if (tokenizationRequest.isFractionalized) {
            revert dWork__AlreadyFractionalized();
        }

        address workOwner = ownerOf(tokenizationRequest.tokenId);

        uint256 sharesTokenId = IDWorkSharesManager(s_workSharesManager)
            .createShares(
                tokenizationRequest.tokenId,
                workOwner,
                _shareSupply,
                _sharePriceUsd
            );

        tokenizationRequest.sharesTokenId = sharesTokenId;
        emit WorkSharesCreated(
            sharesTokenId,
            tokenizationRequest.tokenId,
            _shareSupply
        );
    }

    /**
     *
     * @param _newAppraiserReportIPFSHash The IPFS hash of the latest appraiser report.
     * @notice Update the IPFS hash of the latest appraiser report.
     */
    function updateLastAppraiserReportIPFSHash(
        uint256 _tokenizationRequestId,
        string calldata _newAppraiserReportIPFSHash
    ) external onlyOwner {
        s_tokenizationRequests[_tokenizationRequestId]
            .appraiserReportIPFSHash = _newAppraiserReportIPFSHash;
    }

    /**
     *
     * @param _sharesTokenId The ERC1155 token ID of the work shares.
     * @dev Set the ERC1155 token ID of the shares tokens associated with this work.
     * This function can only be called by the factory contract after calling its createWorkShares() function.
     */
    function setWorkSharesTokenId(
        uint256 _tokenizationRequestId,
        uint256 _sharesTokenId
    ) external onlyOwner whenNotPaused {
        s_sharesTokenIds[_tokenizationRequestId] = _sharesTokenId;
        emit WorkFractionalized(_sharesTokenId);
    }

    /**
     * @dev Triggered using Chainlink log-based Automation once a VerifierTaskDone event is emitted by
     * the WorkVerifier contract. It confirms that the work verification is needed and that performUpkeep() should be called.
     */
    function checkLog(
        Log calldata log,
        bytes memory
    ) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256 tokenizationRequestId = bytes32ToUint256(log.topics[1]);
        VerificationStep requestVerificationStep = getTokenizationRequestStatus(
            tokenizationRequestId
        );
        if (
            requestVerificationStep ==
            VerificationStep.PendingWorkVerification ||
            requestVerificationStep ==
            VerificationStep.PendingCertificateAnalysis
        ) {
            performData = abi.encode(tokenizationRequestId);
            upkeepNeeded = true;
        }
    }

    /**
     * @dev Called by Chainlink log-based Automation to fulfill the work verification request.
     * It should be triggered by when the VerifierTaskDone event is emitted by the WorkVerifier contract.
     */
    function performUpkeep(bytes calldata performData) external override {
        s_lastPerformData = performData;
        uint256 tokenizationRequestId = abi.decode(performData, (uint256));
        IDWorkConfig.VerifiedWorkData memory lastVerifiedData = IWorkVerifier(
            s_workVerifier
        ).getLastVerifiedData(tokenizationRequestId);
        if (
            s_tokenizationRequests[tokenizationRequestId].verificationStep ==
            VerificationStep.PendingCertificateAnalysis
        ) {
            _fullfillCertificateExtractionRequest(
                tokenizationRequestId,
                lastVerifiedData.artist,
                lastVerifiedData.work
            );
        } else if (
            s_tokenizationRequests[tokenizationRequestId].verificationStep ==
            VerificationStep.PendingWorkVerification
        ) {
            _fulfillWorkVerificationRequest(
                tokenizationRequestId,
                lastVerifiedData.ownerName,
                lastVerifiedData.priceUsd
            );
        }
    }

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

    function setWorkSharesManager(
        address _workSharesManager
    ) external onlyOwner {
        s_workSharesManager = _workSharesManager;
    }

    function setWorkVerifier(address _workVerifier) external onlyOwner {
        s_workVerifier = _workVerifier;
    }

    ////////////////////
    // Internal
    ////////////////////

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
        TokenizationRequest
            storage tokenizationRequest = s_tokenizationRequests[
                _tokenizationRequestId
            ];
        string[] memory _args = new string[](4);
        _args[0] = tokenizationRequest.customerSubmissionIPFSHash;
        _args[1] = tokenizationRequest.appraiserReportIPFSHash;
        _args[2] = tokenizationRequest.certificate.artist;
        _args[3] = tokenizationRequest.certificate.work;

        tokenizationRequest.verificationStep = VerificationStep
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

    function _fullfillCertificateExtractionRequest(
        uint256 _tokenizationRequestId,
        string memory _artist,
        string memory _work
    ) internal {
        if (bytes(_artist).length == 0 || bytes(_work).length == 0) {
            emit CertificateExtractionError(_tokenizationRequestId);
            return;
        }

        WorkCertificate memory workCertificate;
        workCertificate = WorkCertificate({artist: _artist, work: _work});

        s_tokenizationRequests[_tokenizationRequestId]
            .certificate = workCertificate;
        s_tokenizationRequests[_tokenizationRequestId]
            .verificationStep = VerificationStep.CertificateAnalysisDone;

        emit CertificateExtracted(_tokenizationRequestId, workCertificate);
    }

    function _fulfillWorkVerificationRequest(
        uint256 _tokenizationRequestId,
        string memory _ownerName,
        uint256 _priceUsd
    ) internal {
        if (_priceUsd == 0) {
            emit WorkVerificationError(_tokenizationRequestId);
            return;
        }

        s_tokenizationRequests[_tokenizationRequestId]
            .verificationStep = VerificationStep.WorkVerificationDone;

        s_tokenizationRequests[_tokenizationRequestId].lastVerifiedAt = block
            .timestamp;

        if (isMinted(_tokenizationRequestId)) {
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
            s_tokenizationRequests[_tokenizationRequestId].verificationStep
        );
    }

    /**
     * @dev Compare the latest appraiser report with the previous one to verify the work.
     * If there is a significant difference, freeze the work contract
     */
    function _compareLatestAppraiserReport(
        uint256 _tokenizationRequestId,
        string memory _ownerName,
        uint256 _priceUsd
    ) internal {
        TokenizationRequest memory tokenizationRequest = s_tokenizationRequests[
            _tokenizationRequestId
        ];
        if (
            (keccak256(abi.encodePacked(_ownerName)) !=
                keccak256(
                    abi.encodePacked(tokenizationRequest.initialOwnerName)
                )) || _priceUsd != tokenizationRequest.lastWorkPriceUsd
        ) {
            _pause();
            if (isFractionalized(_tokenizationRequestId)) {
                IDWorkSharesManager(s_workSharesManager).pauseShares(
                    _tokenizationRequestId
                );
            }
            emit LastVerificationFailed(
                tokenizationRequest.initialOwnerName,
                tokenizationRequest.lastWorkPriceUsd,
                _ownerName,
                _priceUsd
            );
        } else {
            if (paused()) {
                _unpause();
                IDWorkSharesManager(s_workSharesManager).unpauseShares(
                    _tokenizationRequestId
                );
            }
        }
    }

    function _tokenizeWork(
        uint256 _tokenizationRequestId,
        string memory _verifiedOwnerName,
        uint256 _verifiedPriceUsd
    ) internal {
        TokenizationRequest
            storage tokenizationRequest = s_tokenizationRequests[
                _tokenizationRequestId
            ];

        _mintWork(_tokenizationRequestId);

        tokenizationRequest.isMinted = true;
        tokenizationRequest.initialOwnerName = _verifiedOwnerName;
        tokenizationRequest.lastWorkPriceUsd = _verifiedPriceUsd;
        tokenizationRequest.verificationStep = VerificationStep.Tokenized;

        emit WorkTokenized(_tokenizationRequestId);
    }

    function _mintWork(uint256 _tokenizationRequestId) internal {
        ++s_tokenId;
        s_tokenizationRequests[_tokenizationRequestId].isMinted = true;
        s_tokenizationRequests[_tokenizationRequestId].tokenId = s_tokenId;
        _safeMint(
            s_tokenizationRequests[_tokenizationRequestId].customer,
            s_tokenId
        );
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

    function _ensureTokenNotPaused(uint256 _tokenId) internal view {
        if (s_tokenById[_tokenId].isPaused) {
            revert dWork__TokenPaused();
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function getTokenizationRequest(
        uint256 _tokenizationRequestId
    ) public view returns (TokenizationRequest memory) {
        return s_tokenizationRequests[_tokenizationRequestId];
    }

    function getTokenizationRequestStatus(
        uint256 _tokenizationRequestId
    ) public view returns (VerificationStep) {
        return s_tokenizationRequests[_tokenizationRequestId].verificationStep;
    }

    function getLastTokenId() public view returns (uint256) {
        return s_tokenId;
    }

    function getSharesTokenId(
        uint256 _tokenizationRequestId
    ) public view returns (uint256) {
        return s_sharesTokenIds[_tokenizationRequestId];
    }

    function getWorkSharesManager() public view returns (address) {
        return s_workSharesManager;
    }

    function getTokenizationRequestByWorkTokenId(
        uint256 _workTokenId
    ) public view returns (TokenizationRequest memory) {
        return s_tokenById[_workTokenId];
    }

    function customerTokenizationRequests(
        address _customer
    ) public view returns (uint256[] memory) {
        return s_customerTokenizationRequests[_customer];
    }

    function getWorkVerifier() public view returns (address) {
        return s_workVerifier;
    }

    function getLastVerifierResponse() public view returns (bytes memory) {
        return s_lastVerifierResponse;
    }

    function getLastVerifierError() public view returns (bytes memory) {
        return s_lastVerifierError;
    }

    function getLastTokenizationRequestId() public view returns (uint256) {
        return s_tokenizationRequestId;
    }

    function isMinted(
        uint256 _tokenizationRequestId
    ) public view returns (bool) {
        return s_tokenizationRequests[_tokenizationRequestId].isMinted;
    }

    function isFractionalized(
        uint256 _tokenizationRequestId
    ) public view returns (bool) {
        return s_tokenizationRequests[_tokenizationRequestId].isFractionalized;
    }

    function bytes32ToUint256(bytes32 _uint) public pure returns (uint256) {
        return uint256(_uint);
    }

    function bytes32ToString(
        bytes32 _bytes32
    ) public pure returns (string memory) {
        return string(abi.encodePacked(_bytes32));
    }

    function toBytes(bytes32 _data) public pure returns (bytes memory) {
        return abi.encodePacked(_data);
    }

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
