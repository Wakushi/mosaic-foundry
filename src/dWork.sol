// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";
import {IWorkVerifier} from "./interfaces/IWorkVerifier.sol";

contract dWork is Ownable, ERC721, Pausable {
    ///////////////////
    // Type declarations
    ///////////////////

    using OracleLib for AggregatorV3Interface;

    enum VerificationStep {
        Pending,
        PendingCertificateAnalysis,
        CertificateAnalysisDone,
        PendingWorkVerification,
        PendingTokenization,
        Tokenized
    }

    struct WorkCertificate {
        string artist;
        string work;
        uint256 year;
        string imageURL;
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

    uint256 constant MIN_VERIFICATION_INTERVAL = 30 days;
    address immutable i_workFactoryAddress;
    address immutable i_workSharesManager;
    address immutable i_workVerifier;
    string s_customerSubmissionIPFSHash;
    string s_lastAppraiserReportIPFSHash;

    VerificationStep s_verificationStep;
    WorkCertificate s_certificate;
    TokenizedWork s_tokenizedWork;

    bool s_isMinted;
    uint256 s_lastVerifiedAt;
    uint256 s_sharesTokenId;

    address s_workOwner;

    bytes s_lastVerifierResponse;
    bytes s_lastVerifierError;

    ///////////////////
    // Events
    ///////////////////

    event WorkFractionalized(uint256 sharesTokenId);
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
    error dWork__NotOwnerOrFactory();
    error dWork__ProcessOrderError();
    error dWork__NotEnoughTimePassedSinceLastVerification();
    error dWork__NotWorkOwner();
    error dWork__NotWorkVerifier();

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

    modifier onlyWorkVerifier() {
        _ensureOnlyWorkVerifier();
        _;
    }

    modifier verifyProcessOrder(VerificationStep _requiredStep) {
        _ensureProcessOrder(_requiredStep);
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor(
        IDWorkConfig.dWorkConfig memory _config
    ) Ownable(_config.owner) ERC721(_config.workName, _config.workSymbol) {
        s_customerSubmissionIPFSHash = _config.customerSubmissionIPFSHash;
        s_lastAppraiserReportIPFSHash = _config.appraiserReportIPFSHash;
        s_workOwner = _config.customer;
        i_workFactoryAddress = _config.factoryAddress;
        i_workSharesManager = _config.workSharesManagerAddress;
        i_workVerifier = _config.workVerifierAddress;
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
    function requestWorkVerification()
        external
        verifyProcessOrder(VerificationStep.CertificateAnalysisDone)
    {
        if (isMinted()) {
            _ensureEnoughTimePassedSinceLastVerification();
        }
        _sendWorkVerificationRequest();
    }

    function fulfillCertificateExtractionRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err,
        string memory certificateImageHash
    )
        external
        onlyWorkVerifier
        verifyProcessOrder(VerificationStep.PendingCertificateAnalysis)
    {
        _fullfillCertificateExtractionRequest(
            requestId,
            response,
            err,
            certificateImageHash
        );
    }

    /**
     * @dev Fulfill the work verification, tiggered on WorkVerifier contract CF callback using log-based automation.
     * @notice Called by Chainlink Log-based Automation
     */
    function fulfillWorkVerificationRequest()
        external
        // TO-DO add control on over which conditions this function can be called
        verifyProcessOrder(VerificationStep.CertificateAnalysisDone)
    {
        _fulfillWorkVerificationRequest();
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

    function _sendCertificateExtractionRequest(string[] memory _args) internal {
        s_verificationStep = VerificationStep.PendingCertificateAnalysis;
        IWorkVerifier(i_workVerifier).sendCertificateExtractionRequest(_args);
        emit VerificationProcess(VerificationStep.PendingCertificateAnalysis);
    }

    function _sendWorkVerificationRequest() internal {
        string[] memory _args = new string[](4);
        _args[0] = s_customerSubmissionIPFSHash;
        _args[1] = s_lastAppraiserReportIPFSHash;
        _args[2] = s_certificate.artist;
        _args[3] = s_certificate.work;

        IWorkVerifier(i_workVerifier).sendWorkVerificationRequest(_args);
        emit VerificationProcess(VerificationStep.PendingWorkVerification);
    }

    function _fullfillCertificateExtractionRequest(
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
            s_lastVerifierError = err;
            emit ChainlinkResponse(
                requestId,
                s_lastVerifierResponse,
                s_lastVerifierError
            );
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
        emit ChainlinkResponse(
            requestId,
            s_lastVerifierResponse,
            s_lastVerifierError
        );
    }

    function _fulfillWorkVerificationRequest() internal {
        IDWorkConfig.WorkVerificationResponse
            memory workVerificationResponse = IWorkVerifier(i_workVerifier)
                .getLastWorkVerificationResponse();
        (string memory ownerName, uint256 priceUsd) = abi.decode(
            workVerificationResponse.response,
            (string, uint256)
        );

        if (priceUsd == 0) {
            s_lastVerifierError = workVerificationResponse.err;
            emit ChainlinkResponse(
                workVerificationResponse.requestId,
                s_lastVerifierResponse,
                s_lastVerifierError
            );
            return;
        }

        if (isMinted()) {
            _compareLatestAppraiserReport(ownerName, priceUsd);
        } else {
            _tokenizeWork(ownerName, priceUsd);
        }

        s_lastVerifiedAt = block.timestamp;
        emit VerificationProcess(s_verificationStep);
        emit ChainlinkResponse(
            workVerificationResponse.requestId,
            s_lastVerifierResponse,
            s_lastVerifierError
        );
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
        string memory _verifiedOwnerName,
        uint256 _verifiedPriceUsd
    ) internal {
        _mintWork();
        TokenizedWork memory tokenizedWork;
        tokenizedWork = TokenizedWork({
            artist: s_certificate.artist,
            work: s_certificate.work,
            ownerName: _verifiedOwnerName,
            workPriceUsd: _verifiedPriceUsd
        });
        s_tokenizedWork = tokenizedWork;
        s_verificationStep = VerificationStep.Tokenized;
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

    function _ensureOnlyWorkVerifier() internal view {
        if (msg.sender != i_workVerifier) {
            revert dWork__NotWorkVerifier();
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

    function getWorkPriceUsd() external view returns (uint256) {
        return s_tokenizedWork.workPriceUsd;
    }

    function getWorkOwner() external view returns (address) {
        return s_workOwner;
    }

    function getLastResponse() external view returns (bytes memory) {
        return s_lastVerifierResponse;
    }

    function getLastError() external view returns (bytes memory) {
        return s_lastVerifierError;
    }

    function getWorkFactoryAddress() external view returns (address) {
        return i_workFactoryAddress;
    }

    function getWorkSharesManagerAddress() external view returns (address) {
        return i_workSharesManager;
    }

    function getWorkVerifierAddress() external view returns (address) {
        return i_workVerifier;
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
}
