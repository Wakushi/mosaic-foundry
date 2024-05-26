// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
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

    bytes32 s_lastRequestId;
    address s_dWork;

    mapping(uint256 tokenizationRequestId => WorkCFRequestType requestType) s_tokenizationRequestType;
    mapping(uint256 tokenizationRequestId => IDWorkConfig.VerifiedWorkData lastVerifiedData) s_lastVerifiedData;
    mapping(bytes32 requestId => uint256 tokenizationRequestId)
        private s_tokenizationRequestIdByCFRequestId;

    ///////////////////
    // Events
    ///////////////////

    // Emits when a Chainlink Functions task is done and is listened by Chainlink Log-based automation,
    // to trigger the next step in the workflow (triggers _fulfillCertificateExtractionRequest() or
    // _fulfillWorkVerificationRequest() on dWork contract).
    event VerifierTaskDone(uint256 indexed tokenizationRequestId);
    event ChainlinkRequestSent(bytes32 requestId);

    //////////////////
    // Errors
    ///////////////////

    error dWorkVerifier__UnexpectedRequestID(bytes32 requestId);
    error dWorkVerifier__NotWorkContract();

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

    /**
     * @param _tokenizationRequestId Tokenization request ID registered on dWork
     * @param _args Arguments to be passed to the Chainlink DON, here the IPFS hash of the certificate of authenticity
     * @dev Sends a request to the Chainlink DON to extract the artist and work name from the certificate of authenticity
     */
    function sendCertificateExtractionRequest(
        uint256 _tokenizationRequestId,
        string[] calldata _args
    ) external onlyWorkContract {
        s_lastRequestId = _generateSendRequest(
            _args,
            s_certificateExtractionSource
        );
        _registerRequest(
            _tokenizationRequestId,
            s_lastRequestId,
            WorkCFRequestType.CertificateExtraction
        );
    }

    /**
     * @param _tokenizationRequestId Tokenization request ID registered on dWork
     * @param _args Arguments to be passed to the Chainlink DON:
     *                  - Customer submission's data IPFS hash;
     *                  - Art appraiser's report data IPFS hash;
     *                  - Artist name extracted from the certificate of authenticity;
     *                  - Work name extracted from the certificate of authenticity;
     * @dev Fetch and organize all data sources using OpenAI GPT-4o through Chainlink Functions.
     * This request will fetch the data from the customer submission, the appraiser report and global market data,
     * join the certificate data obtained by _sendCertificateExtractionRequest() and logically verify the work.
     */
    function sendWorkVerificationRequest(
        uint256 _tokenizationRequestId,
        string[] calldata _args
    ) external onlyWorkContract {
        s_lastRequestId = _generateSendRequest(_args, s_workVerificationSource);
        _registerRequest(
            _tokenizationRequestId,
            s_lastRequestId,
            WorkCFRequestType.WorkVerification
        );
    }

    function setDWorkAddress(address _dWork) external onlyOwner {
        s_dWork = _dWork;
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
     * @dev Callback function to receive the response from the Chainlink DON after the certificate extraction or work verification task is done
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        uint256 tokenizationRequestId = getTokenizationRequestId(requestId);
        WorkCFRequestType requestType = getRequestType(tokenizationRequestId);

        IDWorkConfig.VerifiedWorkData memory verifiedWorkData;

        if (requestType == WorkCFRequestType.CertificateExtraction) {
            (string memory artist, string memory work) = abi.decode(
                response,
                (string, string)
            );

            verifiedWorkData.artist = artist;
            verifiedWorkData.work = work;

            _setLastVerifiedData(tokenizationRequestId, verifiedWorkData);

            emit VerifierTaskDone(tokenizationRequestId);
        } else if (requestType == WorkCFRequestType.WorkVerification) {
            (string memory ownerName, uint256 priceUsd) = abi.decode(
                response,
                (string, uint256)
            );

            verifiedWorkData.ownerName = ownerName;
            verifiedWorkData.priceUsd = priceUsd;

            _setLastVerifiedData(tokenizationRequestId, verifiedWorkData);

            emit VerifierTaskDone(tokenizationRequestId);
        }
    }

    function _registerRequest(
        uint256 _tokenizationRequestId,
        bytes32 _requestId,
        WorkCFRequestType _requestType
    ) internal {
        _setTokenizationRequestIdByCFRequestId(
            _requestId,
            _tokenizationRequestId
        );
        _setRequestType(_tokenizationRequestId, _requestType);
    }

    function _setTokenizationRequestIdByCFRequestId(
        bytes32 _requestId,
        uint256 _tokenizationRequestId
    ) internal {
        s_tokenizationRequestIdByCFRequestId[
            _requestId
        ] = _tokenizationRequestId;
    }

    function _setRequestType(
        uint256 _tokenizationRequestId,
        WorkCFRequestType _requestType
    ) internal {
        s_tokenizationRequestType[_tokenizationRequestId] = _requestType;
    }

    function _setLastVerifiedData(
        uint256 _tokenizationRequestId,
        IDWorkConfig.VerifiedWorkData memory _verifiedWorkData
    ) internal {
        s_lastVerifiedData[_tokenizationRequestId] = _verifiedWorkData;
    }

    function _ensureIsWorkContract() internal view {
        if (msg.sender != s_dWork) {
            revert dWorkVerifier__NotWorkContract();
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function getTokenizationRequestId(
        bytes32 requestId
    ) public view returns (uint256) {
        return s_tokenizationRequestIdByCFRequestId[requestId];
    }

    function getRequestType(
        uint256 tokenizationRequestId
    ) public view returns (WorkCFRequestType) {
        return s_tokenizationRequestType[tokenizationRequestId];
    }

    function getLastVerifiedData(
        uint256 _tokenizationRequestId
    ) external view returns (IDWorkConfig.VerifiedWorkData memory) {
        return s_lastVerifiedData[_tokenizationRequestId];
    }

    function getLastRequestId() external view returns (bytes32) {
        return s_lastRequestId;
    }

    function getSecretsReference() external view returns (bytes memory) {
        return s_secretReference;
    }

    function getDWorkAddress() external view returns (address) {
        return s_dWork;
    }
}
