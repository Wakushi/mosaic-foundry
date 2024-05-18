// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {IDWork} from "./interfaces/IDWork.sol";
import {IDWorkFactory} from "./interfaces/IDWorkFactory.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";

contract WorkVerifier is FunctionsClient, Ownable {
    ///////////////////
    // Type declarations
    ///////////////////

    using FunctionsRequest for FunctionsRequest.Request;

    enum WorkCFRequestType {
        WorkVerification,
        CertificateExtraction
    }

    struct WorkCFRequest {
        WorkCFRequestType requestType;
        address workRequester;
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
    bytes s_secretReference;

    string s_workVerificationSource;
    string s_certificateExtractionSource;

    bytes s_lastResponse;
    bytes s_lastError;
    bytes32 s_lastRequestId;

    address s_workFactory;
    IDWorkConfig.WorkVerificationResponse s_lastWorkVerificationResponse;

    mapping(bytes32 requestId => WorkCFRequest request) private s_requestById;

    ///////////////////
    // Events
    ///////////////////

    event ChainlinkRequestSent(bytes32 requestId);
    event WorkVerificationDone(
        address indexed workRequester,
        bytes32 indexed requestId,
        uint256 indexed timestamp
    );

    //////////////////
    // Errors
    ///////////////////

    error dWorkVerifier__UnexpectedRequestID(bytes32 requestId);
    error dWorkVerifier__NotWorkContract();
    error dWorkVerifier__WorkFactoryNotSet();

    //////////////////
    // Functions
    //////////////////

    modifier onlyWorkContract() {
        _ensureIsWorkContract();
        _;
    }

    constructor(
        address _functionsRouter,
        bytes32 _donId,
        uint64 _functionsSubId,
        bytes memory _secretReference,
        string memory _workVerificationSource,
        string memory _certificateExtractionSource
    ) FunctionsClient(_functionsRouter) Ownable(msg.sender) {
        s_donID = _donId;
        s_functionsSubId = _functionsSubId;
        s_secretReference = _secretReference;
        s_workVerificationSource = _workVerificationSource;
        s_certificateExtractionSource = _certificateExtractionSource;
    }

    ////////////////////
    // External / Public
    ////////////////////

    function sendCertificateExtractionRequest(
        string[] calldata _args
    ) external onlyWorkContract returns (bytes32 requestId) {
        s_lastRequestId = _generateSendRequest(
            _args,
            s_certificateExtractionSource
        );
        s_requestById[s_lastRequestId] = WorkCFRequest({
            requestType: WorkCFRequestType.CertificateExtraction,
            workRequester: msg.sender,
            customerSubmissionHash: _args[0],
            appraiserReportHash: "",
            certificateImageHash: "",
            timestamp: block.timestamp
        });
        return s_lastRequestId;
    }

    function sendWorkVerificationRequest(
        string[] calldata _args
    ) external onlyWorkContract returns (bytes32 requestId) {
        s_lastRequestId = _generateSendRequest(_args, s_workVerificationSource);
        s_requestById[s_lastRequestId] = WorkCFRequest({
            requestType: WorkCFRequestType.WorkVerification,
            workRequester: msg.sender,
            customerSubmissionHash: _args[0],
            appraiserReportHash: _args[1],
            certificateImageHash: "",
            timestamp: block.timestamp
        });
        return s_lastRequestId;
    }

    function setWorkFactory(address _workFactory) external onlyOwner {
        s_workFactory = _workFactory;
    }

    function updateCFSubId(uint64 _subscriptionId) external onlyOwner {
        s_functionsSubId = _subscriptionId;
    }

    function updateDonId(bytes32 _newDonId) external onlyOwner {
        s_donID = _newDonId;
    }

    function updateGasLimit(uint32 _newGasLimit) external onlyOwner {
        s_gasLimit = _newGasLimit;
    }

    function updateSecretReference(
        bytes calldata _secretReference
    ) external onlyOwner {
        s_secretReference = _secretReference;
    }

    ////////////////////
    // Internal
    ////////////////////

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
            revert dWorkVerifier__UnexpectedRequestID(requestId);
        }

        WorkCFRequest storage request = s_requestById[requestId];

        if (request.requestType == WorkCFRequestType.CertificateExtraction) {
            IDWork(request.workRequester).fulfillCertificateExtractionRequest(
                requestId,
                response,
                err,
                request.certificateImageHash
            );
        } else if (request.requestType == WorkCFRequestType.WorkVerification) {
            s_lastWorkVerificationResponse = IDWorkConfig
                .WorkVerificationResponse({
                    requestId: requestId,
                    response: response,
                    err: err
                });
            emit WorkVerificationDone(
                request.workRequester,
                requestId,
                block.timestamp
            );
        }

        s_lastResponse = response;
    }

    function _ensureIsWorkContract() internal view {
        if (s_workFactory == address(0)) {
            revert dWorkVerifier__WorkFactoryNotSet();
        }
        if (!IDWorkFactory(s_workFactory).isWorkContract(msg.sender)) {
            revert dWorkVerifier__NotWorkContract();
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function getLastWorkVerificationResponse()
        external
        view
        returns (IDWorkConfig.WorkVerificationResponse memory)
    {
        return s_lastWorkVerificationResponse;
    }

    function getLastResponse() external view returns (bytes memory) {
        return s_lastResponse;
    }

    function getLastRequestId() external view returns (bytes32) {
        return s_lastRequestId;
    }

    function getWorkFactory() external view returns (address) {
        return s_workFactory;
    }

    function getWorkCFRequest(
        bytes32 requestId
    ) external view returns (WorkCFRequest memory) {
        return s_requestById[requestId];
    }

    function getSecretsReference() external view returns (bytes memory) {
        return s_secretReference;
    }
}
