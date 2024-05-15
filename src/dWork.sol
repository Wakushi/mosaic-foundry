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

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink Functions
    bytes32 s_donID;
    uint32 s_gasLimit = 300000;
    uint64 s_functionsSubId;
    bytes public s_secretReference;

    string s_workVerificationSource;
    string s_certificateExtractionSource;

    bytes s_lastResponse;
    bytes s_lastError;
    bytes32 s_lastRequestId;

    mapping(bytes32 requestId => WorkCFRequest request) private s_requestById;

    address immutable i_factoryAddress;
    string constant BASE_URI =
        "https://peach-genuine-lamprey-766.mypinata.cloud/ipfs/";

    // Work
    VerificationStep s_verificationStep;
    WorkCertificate s_certificate;

    string s_workURI;
    string s_ownerName;
    uint256 s_workPriceUsd;
    address s_customer;

    bool s_isMinted;
    bool s_isFractionalized;
    uint256 s_lastVerifiedAt;

    ///////////////////
    // Events
    ///////////////////

    event Response(
        bytes32 indexed requestId,
        uint256 workPrice,
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

    //////////////////
    // Functions
    //////////////////

    constructor(
        IDWorkConfig.dWorkConfig memory _config
    )
        FunctionsClient(_config.functionsRouter)
        Ownable(_config.initialOwner)
        ERC721(_config.workName, _config.workSymbol)
    {
        s_donID = _config.donId;
        s_functionsSubId = _config.functionsSubId;
        s_gasLimit = _config.gasLimit;
        s_secretReference = _config.secretReference;
        s_workVerificationSource = _config.workVerificationSource;
        s_certificateExtractionSource = _config.certificateExtractionSource;
        s_customer = _config.customer;
        s_workURI = _config.workURI;
        i_factoryAddress = _config.factoryAddress;
        s_verificationStep = VerificationStep.Pending;
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
     *
     * @param _args [CERTIFICATE IMAGE IPFS HASH]
     * @dev Performs multiple API calls using Chainlink Functions to extract the certificate data
     */
    function requestCertificateExtraction(
        string[] calldata _args
    ) external onlyOwnerOrFactory notMinted {
        _sendCertificateExtractionRequest(_args);
    }

    /**
     *
     * @param _customerSubmissionHash IPFS hash of the customer's submission
     * @param _appraiserReportHash IPFS hash of the appraiser's report
     * @dev Performs multiple API calls using Chainlink Functions to verify the work
     */
    function requestWorkVerification(
        string memory _customerSubmissionHash,
        string memory _appraiserReportHash
    ) external onlyOwnerOrFactory notMinted {
        _ensureProcessOrder(VerificationStep.CertificateAnalysisDone);
        _sendWorkVerificationRequest(
            _customerSubmissionHash,
            _appraiserReportHash
        );
    }

    function setIsFractionalized(
        bool _isFractionalized
    ) external onlyOwnerOrFactory {
        s_isFractionalized = _isFractionalized;
    }

    function setCFSubId(uint64 _subscriptionId) external onlyOwnerOrFactory {
        s_functionsSubId = _subscriptionId;
    }

    function setDonId(bytes32 _newDonId) external onlyOwnerOrFactory {
        s_donID = _newDonId;
    }

    function setSecretReference(
        bytes calldata _secretReference
    ) external onlyOwnerOrFactory {
        s_secretReference = _secretReference;
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
        s_requestById[s_lastRequestId] = WorkCFRequest(
            WorkCFRequestType.CertificateExtraction,
            "",
            "",
            _args[0],
            block.timestamp
        );
        s_verificationStep = VerificationStep.PendingCertificateAnalysis;
        return s_lastRequestId;
    }

    function _sendWorkVerificationRequest(
        string memory _customerSubmissionHash,
        string memory _appraiserReportHash
    ) internal returns (bytes32 requestId) {
        string[] memory _args = new string[](4);
        _args[0] = _customerSubmissionHash;
        _args[1] = _appraiserReportHash;
        _args[2] = s_certificate.artist;
        _args[3] = s_certificate.work;

        s_lastRequestId = _generateSendRequest(_args, s_workVerificationSource);
        s_requestById[s_lastRequestId] = WorkCFRequest(
            WorkCFRequestType.WorkVerification,
            _args[0],
            _args[1],
            "",
            block.timestamp
        );
        s_verificationStep = VerificationStep.PendingWorkVerification;
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
            emit Response(requestId, 0, s_lastResponse, s_lastError);
            return;
        }

        s_certificate = WorkCertificate(
            artist,
            work,
            year,
            certificateImageHash
        );

        s_verificationStep = VerificationStep.CertificateAnalysisDone;
        emit Response(requestId, 0, s_lastResponse, s_lastError);
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
            emit Response(requestId, priceUsd, s_lastResponse, s_lastError);
            return;
        }

        s_ownerName = ownerName;
        s_lastVerifiedAt = block.timestamp;
        s_workPriceUsd = priceUsd;
        _mintWork();

        s_verificationStep = VerificationStep.Tokenized;
        emit Response(requestId, priceUsd, s_lastResponse, s_lastError);
    }

    function _mintWork() internal {
        s_isMinted = true;
        _safeMint(s_customer, 0);
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
        if (msg.sender != owner() && msg.sender != i_factoryAddress) {
            revert dWork__NotOwnerOrFactory();
        }
    }

    function isMinted() public view returns (bool) {
        return s_isMinted;
    }

    function isFractionalized() external view returns (bool) {
        return s_isFractionalized;
    }

    function getWorkPriceUsd() external view returns (uint256) {
        return s_workPriceUsd;
    }

    function getWorkURI() external view returns (string memory) {
        return s_workURI;
    }

    function getCustomer() external view returns (address) {
        return s_customer;
    }

    function getLastVerifiedAt() external view returns (uint256) {
        return s_lastVerifiedAt;
    }

    function getOwnerName() external view returns (string memory) {
        return s_ownerName;
    }

    function getDonId() external view returns (bytes32) {
        return s_donID;
    }

    function getGasLimit() external view returns (uint32) {
        return s_gasLimit;
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

    function getFactoryAddress() external view returns (address) {
        return i_factoryAddress;
    }

    function getBaseURI() external pure returns (string memory) {
        return BASE_URI;
    }

    function getCertificate() external view returns (WorkCertificate memory) {
        return s_certificate;
    }

    function getVerificationStep() external view returns (VerificationStep) {
        return s_verificationStep;
    }
}
