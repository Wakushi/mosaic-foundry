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
import {Log, ILogAutomation} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";

contract dWork is ILogAutomation, ERC721, Ownable, Pausable {
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
    bool s_expectsWorkVerification;
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
    error dWork__WorkVerificationNotExpected();

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
     * @notice Request the certificate data extraction from the scanned image.
     * @dev Tasks the WorkVerifier contract to extract the image data using OpenAI GPT-4o through Chainlink Functions.
     * Once fulfilled on WorkVerifier, it will call back the fulfillCertificateExtractionRequest() function on this contract.
     * Note: This function can only be called as long as the work is not minted.
     */
    function requestCertificateExtraction(
        string[] calldata _args
    ) external onlyOwnerOrFactory notMinted {
        _sendCertificateExtractionRequest(_args);
    }

    /**
     * @notice Request the work verification using all aggregated data.
     * @dev Tasks the WorkVerifier contract to fetch and organize all data sources using OpenAI GPT-4o through Chainlink Functions.
     * This request will fetch the data from the customer submission, the appraiser report and global market data,
     * join the certificate data obtained by requestCertificateExtraction() and logically verify the work.
     * Once the request is fulfilled, the fulfillWorkVerificationRequest() function will be called on this contract to mint the work as an ERC721 token.
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

    /**
     * @param requestId The Chainlink request ID.
     * @param response The response data from the Chainlink node.
     * @param err The error message from the Chainlink node.
     * @param certificateImageHash The IPFS hash of the certificate image.
     * @notice Registers the data extracted from the certificate of authenticity on this contract.
     * @dev This function can only be called by the WorkVerifier contract, after the certificate extraction request is fulfilled.
     */
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
     * @notice Fulfill the work verification request by minting the work as an ERC721 token.
     * @dev Called by Chainlink Log-based Automation, when WorkVerificationDone event is emitted on WorkVerifier contract.
     */
    function fulfillWorkVerificationRequest()
        public
        verifyProcessOrder(VerificationStep.CertificateAnalysisDone)
    {
        _ensureExpectsWorkVerification();
        _fulfillWorkVerificationRequest();
    }

    /**
     *
     * @param _newAppraiserReportIPFSHash The IPFS hash of the latest appraiser report.
     * @notice Update the IPFS hash of the latest appraiser report.
     */
    function updateLastAppraiserReportIPFSHash(
        string calldata _newAppraiserReportIPFSHash
    ) external onlyOwnerOrFactory {
        s_lastAppraiserReportIPFSHash = _newAppraiserReportIPFSHash;
    }

    /**
     *
     * @param _sharesTokenId The ERC1155 token ID of the work shares.
     * @dev Set the ERC1155 token ID of the shares tokens associated with this work.
     * This function can only be called by the factory contract after calling its createWorkShares() function.
     */
    function setWorkSharesTokenId(
        uint256 _sharesTokenId
    ) external onlyFactory whenNotPaused {
        s_sharesTokenId = _sharesTokenId;
        emit WorkFractionalized(_sharesTokenId);
    }

    /**
     * @dev Triggered using Chainlink log-based Automation once a WorkVerificationDone event is emitted by
     * the WorkVerifier contract. It confirms that the work verification is needed and that performUpkeep() should be called.
     */
    function checkLog(
        Log calldata log,
        bytes memory
    ) external view returns (bool upkeepNeeded, bytes memory performData) {
        address workRequester = bytes32ToAddress(log.topics[1]);
        upkeepNeeded = workRequester == address(this);
        performData = abi.encode(workRequester);
    }

    /**
     * @dev Called by Chainlink log-based Automation to fulfill the work verification request.
     * It should be triggered by when the WorkVerificationDone event is emitted by the WorkVerifier contract.
     */
    function performUpkeep(bytes calldata performData) external override {
        address workRequester = abi.decode(performData, (address));
        if (workRequester == address(this)) {
            fulfillWorkVerificationRequest();
        }
    }

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
        s_expectsWorkVerification = true;
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
        s_expectsWorkVerification = false;
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

    function _ensureExpectsWorkVerification() internal view {
        if (!s_expectsWorkVerification) {
            revert dWork__WorkVerificationNotExpected();
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

    function bytes32ToAddress(bytes32 _address) public pure returns (address) {
        return address(uint160(uint256(_address)));
    }
}
