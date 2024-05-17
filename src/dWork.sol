// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";

contract dWork is FunctionsClient, Ownable, ERC721, Pausable {
    ///////////////////
    // Type declarations
    ///////////////////

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    enum WorkCFRequestType {
        WorkVerification,
        CertificateExtraction
    }

    enum VerificationStep {
        Pending,
        PendingCertificateAnalysis,
        CertificateAnalysisDone,
        PendingWorkVerification,
        Tokenized
    }

    struct WorkCertificate {
        string artist;
        string work;
        uint256 year;
        string imageURL;
    }

    struct WorkCFRequest {
        WorkCFRequestType requestType;
        string customerSubmissionHash;
        string appraiserReportHash;
        string certificateImageHash;
        uint256 timestamp;
    }

    struct TokenizedWork {
        string artist;
        string work;
        string ownerName;
        uint256 workPriceUsd;
    }

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink Functions
    bytes32 s_donID;
    uint32 s_gasLimit = 300000;
    uint64 s_functionsSubId;
    bytes s_secretReference;

    string s_workVerificationSource;
    string s_certificateExtractionSource;

    bytes s_lastResponse;
    bytes s_lastError;
    bytes32 s_lastRequestId;

    mapping(bytes32 requestId => WorkCFRequest request) private s_requestById;

    // Work state
    uint256 constant MIN_VERIFICATION_INTERVAL = 30 days;
    address immutable i_workFactoryAddress;
    string s_customerSubmissionIPFSHash;
    string s_lastAppraiserReportIPFSHash;

    VerificationStep s_verificationStep;
    WorkCertificate s_certificate;
    TokenizedWork s_tokenizedWork;

    bool s_isMinted;
    uint256 s_lastVerifiedAt;
    uint256 s_sharesTokenId;

    address s_workOwner;
    address immutable i_workSharesManager;

    ///////////////////
    // Events
    ///////////////////

    event WorkFractionalized(uint256 sharesTokenId);
    event ChainlinkRequestSent(bytes32 requestId);
    event VerificationProcess(VerificationStep step);
    event CertificateExtracted(WorkCertificate certificate);
    event WorkTokenized(TokenizedWork tokenizedWork);
    event LastVerificationFailed(
        string previousOwner,
        uint256 previousPrice,
        string newOwner,
        uint256 newPrice
    );
    event ChainlinkResponse(
        bytes32 indexed requestId,
        bytes response,
        bytes err
    );

    //////////////////
    // Errors
    ///////////////////

    error dWork__AlreadyMinted();
    error dWork__UnexpectedRequestID(bytes32 requestId);
    error dWork__NotOwnerOrFactory();
    error dWork__ProcessOrderError();
    error dWork__NotEnoughTimePassedSinceLastVerification();
    error dWork__NotWorkOwner();

    //////////////////
    // Modifiers
    //////////////////

    modifier notMinted() {
        _ensureNotMinted();
        _;
    }

    modifier onlyOwnerOrFactory() {
        _ensureOwnerOrFactory();
        _;
    }

    modifier onlyFactory() {
        _ensureOnlyFactory();
        _;
    }

    modifier onlyWorkOwner() {
        _ensureOnlyWorkOwner();
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor(
        IDWorkConfig.dWorkConfig memory _config
    )
        FunctionsClient(_config.functionsRouter)
        Ownable(_config.owner)
        ERC721(_config.workName, _config.workSymbol)
    {
        s_donID = _config.donId;
        s_functionsSubId = _config.functionsSubId;
        s_gasLimit = _config.gasLimit;
        s_secretReference = _config.secretReference;
        s_workVerificationSource = _config.workVerificationSource;
        s_certificateExtractionSource = _config.certificateExtractionSource;
        s_customerSubmissionIPFSHash = _config.customerSubmissionIPFSHash;
        s_lastAppraiserReportIPFSHash = _config.appraiserReportIPFSHash;
        s_workOwner = _config.customer;
        i_workFactoryAddress = _config.factoryAddress;
        i_workSharesManager = _config.workSharesManagerAddress;
        s_verificationStep = VerificationStep.Pending;
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
     *
     * @param _args [CERTIFICATE IMAGE IPFS HASH]
     *
     * @dev Extract the certificate of authenticity data from the scanned image using Chainlink Functions and OpenAI GPT-4o.
     * The certificate data includes the artist name, work name, and year of creation.
     *
     * Note: This function can only be called once.
     */
    function requestCertificateExtraction(
        string[] calldata _args
    ) external onlyOwnerOrFactory notMinted {
        _sendCertificateExtractionRequest(_args);
    }

    /**
     * @dev Request the work verification using Chainlink Functions and OpenAI GPT-4o.
     * This request will fetch the data from the customer submission, the appraiser report and global market data,
     * join the certificate data obtained by requestCertificateExtraction() and logitically verify the work.
     * Once the request is fulfilled, the contract will mint the work as an ERC721 token.
     *
     * Note: This function has to be called after the certificate extraction request is fulfilled, and then
     * will be called every month with the latest appraiser report using Chainlink Automation.
     */
    function requestWorkVerification() external {
        _ensureProcessOrder(VerificationStep.CertificateAnalysisDone);
        if (isMinted()) {
            _ensureEnoughTimePassedSinceLastVerification();
        }
        _sendWorkVerificationRequest();
    }

    function updateLastAppraiserReportIPFSHash(
        string calldata _newAppraiserReportIPFSHash
    ) external onlyOwnerOrFactory {
        s_lastAppraiserReportIPFSHash = _newAppraiserReportIPFSHash;
    }

    function setWorkSharesTokenId(
        uint256 _sharesTokenId
    ) external onlyFactory whenNotPaused {
        s_sharesTokenId = _sharesTokenId;
        emit WorkFractionalized(_sharesTokenId);
    }

    function updateCFSubId(uint64 _subscriptionId) external onlyOwnerOrFactory {
        s_functionsSubId = _subscriptionId;
    }

    function updateDonId(bytes32 _newDonId) external onlyOwnerOrFactory {
        s_donID = _newDonId;
    }

    function updateSecretReference(
        bytes calldata _secretReference
    ) external onlyOwnerOrFactory {
        s_secretReference = _secretReference;
    }

    // What happens if the work is approved to a different address?
    function approve(
        address to,
        uint256 tokenId
    ) public override whenNotPaused onlyWorkOwner {
        super.approve(to, tokenId);
    }

    function setApprovalForAll(
        address operator,
        bool approved
    ) public override whenNotPaused onlyWorkOwner {
        super.setApprovalForAll(operator, approved);
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override whenNotPaused onlyWorkOwner {
        super.transferFrom(from, to, tokenId);
        s_workOwner = to;
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override whenNotPaused onlyWorkOwner {
        super.safeTransferFrom(from, to, tokenId, data);
        s_workOwner = to;
    }

    ////////////////////
    // Internal
    ////////////////////

    function _sendCertificateExtractionRequest(
        string[] calldata _args
    ) internal returns (bytes32 requestId) {
        s_lastRequestId = _generateSendRequest(
            _args,
            s_certificateExtractionSource
        );
        s_requestById[s_lastRequestId] = WorkCFRequest({
            requestType: WorkCFRequestType.CertificateExtraction,
            customerSubmissionHash: _args[0],
            appraiserReportHash: "",
            certificateImageHash: "",
            timestamp: block.timestamp
        });
        s_verificationStep = VerificationStep.PendingCertificateAnalysis;
        emit VerificationProcess(VerificationStep.PendingCertificateAnalysis);
        return s_lastRequestId;
    }

    function _sendWorkVerificationRequest()
        internal
        returns (bytes32 requestId)
    {
        string[] memory _args = new string[](4);
        _args[0] = s_customerSubmissionIPFSHash;
        _args[1] = s_lastAppraiserReportIPFSHash;
        _args[2] = s_certificate.artist;
        _args[3] = s_certificate.work;

        s_lastRequestId = _generateSendRequest(_args, s_workVerificationSource);
        s_requestById[s_lastRequestId] = WorkCFRequest({
            requestType: WorkCFRequestType.WorkVerification,
            customerSubmissionHash: _args[0],
            appraiserReportHash: _args[1],
            certificateImageHash: "",
            timestamp: block.timestamp
        });
        s_verificationStep = VerificationStep.PendingWorkVerification;
        emit VerificationProcess(VerificationStep.PendingWorkVerification);
        return s_lastRequestId;
    }

    function _generateSendRequest(
        string[] memory args,
        string memory source
    ) internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        req.secretsLocation = FunctionsRequest.Location.DONHosted;
        req.encryptedSecretsReference = s_secretReference;
        if (args.length > 0) {
            req.setArgs(args);
        }

        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            s_functionsSubId,
            s_gasLimit,
            s_donID
        );

        emit ChainlinkRequestSent(s_lastRequestId);
        return s_lastRequestId;
    }

    /**
     *
     * @param requestId Chainlink request ID
     * @param response Response from the Chainlink DON
     * @param err Error message from the Chainlink DON
     * @dev Callback function to receive the response from the Chainlink DON after the work verification request
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (s_lastRequestId != requestId) {
            revert dWork__UnexpectedRequestID(requestId);
        }

        WorkCFRequest storage request = s_requestById[requestId];

        if (request.requestType == WorkCFRequestType.CertificateExtraction) {
            _ensureProcessOrder(VerificationStep.PendingCertificateAnalysis);
            _fulfillCertificateExtractionRequest(
                requestId,
                response,
                err,
                request.certificateImageHash
            );
        } else if (request.requestType == WorkCFRequestType.WorkVerification) {
            _ensureProcessOrder(VerificationStep.PendingWorkVerification);
            _fulfillWorkVerificationRequest(requestId, response, err);
        }

        s_lastResponse = response;
    }

    function _fulfillCertificateExtractionRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err,
        string memory certificateImageHash
    ) internal {
        (string memory artist, string memory work, uint256 year) = abi.decode(
            response,
            (string, string, uint256)
        );

        if (bytes(artist).length == 0 || bytes(work).length == 0 || year == 0) {
            s_lastError = err;
            emit ChainlinkResponse(requestId, s_lastResponse, s_lastError);
            return;
        }

        WorkCertificate memory workCertificate;
        workCertificate = WorkCertificate({
            artist: artist,
            work: work,
            year: year,
            imageURL: certificateImageHash
        });

        s_certificate = workCertificate;
        s_verificationStep = VerificationStep.CertificateAnalysisDone;

        emit VerificationProcess(VerificationStep.CertificateAnalysisDone);
        emit CertificateExtracted(workCertificate);
        emit ChainlinkResponse(requestId, s_lastResponse, s_lastError);
    }

    function _fulfillWorkVerificationRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal {
        (string memory ownerName, uint256 priceUsd) = abi.decode(
            response,
            (string, uint256)
        );

        if (priceUsd == 0) {
            s_lastError = err;
            emit ChainlinkResponse(requestId, s_lastResponse, s_lastError);
            return;
        }

        if (isMinted()) {
            _compareLatestAppraiserReport(ownerName, priceUsd);
        } else {
            _tokenizeWork(ownerName, priceUsd);
        }

        s_lastVerifiedAt = block.timestamp;
        s_verificationStep = VerificationStep.Tokenized;
        emit VerificationProcess(VerificationStep.Tokenized);
        emit ChainlinkResponse(requestId, s_lastResponse, s_lastError);
    }

    /**
     * @dev Compare the latest appraiser report with the previous one to verify the work.
     * If there is a significant difference, freeze the work contract
     */
    function _compareLatestAppraiserReport(
        string memory _ownerName,
        uint256 _priceUsd
    ) internal {
        if (
            (keccak256(abi.encodePacked(_ownerName)) !=
                keccak256(abi.encodePacked(s_tokenizedWork.ownerName))) ||
            _priceUsd != s_tokenizedWork.workPriceUsd
        ) {
            _pause();
            if (isFractionalized()) {
                IDWorkSharesManager(i_workSharesManager).pauseShares();
            }
            emit LastVerificationFailed(
                s_tokenizedWork.ownerName,
                s_tokenizedWork.workPriceUsd,
                _ownerName,
                _priceUsd
            );
        } else {
            if (paused()) {
                _unpause();
                IDWorkSharesManager(i_workSharesManager).unpauseShares();
            }
        }
    }

    function _tokenizeWork(
        string memory _ownerName,
        uint256 _priceUsd
    ) internal {
        _mintWork();
        TokenizedWork memory tokenizedWork;
        tokenizedWork = TokenizedWork({
            artist: s_certificate.artist,
            work: s_certificate.work,
            ownerName: _ownerName,
            workPriceUsd: _priceUsd
        });
        s_tokenizedWork = tokenizedWork;
        emit WorkTokenized(tokenizedWork);
    }

    function _mintWork() internal {
        s_isMinted = true;
        _safeMint(s_workOwner, 0);
    }

    function _ensureNotMinted() internal view {
        if (isMinted()) {
            revert dWork__AlreadyMinted();
        }
    }

    function _ensureProcessOrder(VerificationStep _requiredStep) internal view {
        if (s_verificationStep < _requiredStep) {
            revert dWork__ProcessOrderError();
        }
    }

    function _ensureOwnerOrFactory() internal view {
        if (msg.sender != owner() && msg.sender != i_workFactoryAddress) {
            revert dWork__NotOwnerOrFactory();
        }
    }

    function _ensureOnlyFactory() internal view {
        if (msg.sender != i_workFactoryAddress) {
            revert dWork__NotOwnerOrFactory();
        }
    }

    function _ensureOnlyWorkOwner() internal view {
        if (msg.sender != s_workOwner) {
            revert dWork__NotWorkOwner();
        }
    }

    function _ensureEnoughTimePassedSinceLastVerification() internal view {
        if (
            s_lastVerifiedAt != 0 &&
            block.timestamp - s_lastVerifiedAt < MIN_VERIFICATION_INTERVAL
        ) {
            revert dWork__NotEnoughTimePassedSinceLastVerification();
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function isMinted() public view returns (bool) {
        return s_isMinted;
    }

    function isFractionalized() public view returns (bool) {
        return s_sharesTokenId != 0;
    }

    function getWorkOwner() external view returns (address) {
        return s_workOwner;
    }

    function getWorkVerificationSource() external view returns (string memory) {
        return s_workVerificationSource;
    }

    function getSecretReference() external view returns (bytes memory) {
        return s_secretReference;
    }

    function getLastResponse() external view returns (bytes memory) {
        return s_lastResponse;
    }

    function getLastError() external view returns (bytes memory) {
        return s_lastError;
    }

    function getLastRequestId() external view returns (bytes32) {
        return s_lastRequestId;
    }

    function getWorkFactoryAddress() external view returns (address) {
        return i_workFactoryAddress;
    }

    function getCertificate() external view returns (WorkCertificate memory) {
        return s_certificate;
    }

    function getVerificationStep() external view returns (VerificationStep) {
        return s_verificationStep;
    }

    function getTokenizedWork() external view returns (TokenizedWork memory) {
        return s_tokenizedWork;
    }

    function getSharesTokenId() external view returns (uint256) {
        return s_sharesTokenId;
    }

    function getCustomerSubmissionIPFSHash()
        external
        view
        returns (string memory)
    {
        return s_customerSubmissionIPFSHash;
    }

    function getLastAppraiserReportIPFSHash()
        external
        view
        returns (string memory)
    {
        return s_lastAppraiserReportIPFSHash;
    }

    function getLastVerifiedAt() external view returns (uint256) {
        return s_lastVerifiedAt;
    }

    function getFunctionsSubId() external view returns (uint64) {
        return s_functionsSubId;
    }

    function getDonId() external view returns (bytes32) {
        return s_donID;
    }
}
