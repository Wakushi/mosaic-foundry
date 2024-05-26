// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Chainlink
import {Log, ILogAutomation} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";
// OpenZeppelin
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
// Custom
import {AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {PriceConverter} from "./libraries/PriceConverter.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";
import {IWorkVerifier} from "./interfaces/IWorkVerifier.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";
import {xChainAsset} from "./xChainAsset.sol";

contract dWork is xChainAsset, ILogAutomation, Ownable, Pausable {
    ///////////////////
    // Type declarations
    ///////////////////

    using PriceConverter for uint256;

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink Price Feed
    AggregatorV3Interface s_priceFeed;

    address s_workSharesManager;
    address s_workVerifier;

    // A collection of a customer's tokenization requests
    mapping(address customer => uint256[] tokenizationRequestsIds) s_customerTokenizationRequests;
    // Fees percentage taken by the protocol on work sales
    uint256 constant PROTOCOL_FEE_PERCENTAGE = 30; // 3%
    // Fees collected by the protocol on work sales
    uint256 s_protocolFees;

    ///////////////////
    // Events
    ///////////////////

    event VerificationProcess(
        uint256 tokenizationRequestId,
        VerificationStep step
    );

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

    event CertificateExtractionError(
        uint256 indexed tokenizationRequestId,
        string indexed errorTitle,
        string indexed errorMessage
    );

    event WorkVerificationError(
        uint256 tokenizationRequestId,
        string indexed errorMessage
    );

    //////////////////
    // Errors
    //////////////////

    error dWork__WorkNotMinted();
    error dWork__AlreadyFractionalized();
    error dWork__NotEnoughValueSent();
    error dWork__InvalidIPFSHash();

    //////////////////
    // Modifiers
    //////////////////

    modifier notZeroAddress(address _address) {
        _ensureNotZeroAddress(_address);
        _;
    }

    // Ensure the order of the process is respected (e.g. The work's certificate of authenticity must be extracted before the work can be verified).
    modifier verifyProcessOrder(
        uint256 _tokenizationRequestId,
        VerificationStep _requiredStep
    ) {
        _ensureProcessOrder(_tokenizationRequestId, _requiredStep);
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor(
        address _workSharesManager,
        address _workVerifier,
        address _priceFeed,
        address _ccipRouterAddress,
        address _linkTokenAddress,
        uint64 _currentChainSelector
    )
        Ownable(msg.sender)
        xChainAsset(
            _ccipRouterAddress,
            _linkTokenAddress,
            _currentChainSelector
        )
    {
        s_workSharesManager = _workSharesManager;
        s_workVerifier = _workVerifier;
        s_priceFeed = AggregatorV3Interface(_priceFeed);
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
     * @param _customerSubmissionIPFSHash The IPFS hash of the customer submission.
     * @param _appraiserReportIPFSHash The IPFS hash of the appraiser report.
     * @param _certificateIPFSHash The IPFS hash of the certificate image.
     * @param _customer The address of the customer who submitted the work.
     *
     * @notice Open a new tokenization request for a work of art. It registers the initial data and tasks the WorkVerifier contract to extract the certificate of authenticity.
     * This method will be called by the Mosaic Admins after the art appraisers have submitted their reports along with a scanned copy of the certificate of authenticity.
     *
     * @dev Only the 'minter' contract (dWork instance deployed on Polygon) can perform this function.
     */
    function openTokenizationRequest(
        string memory _customerSubmissionIPFSHash,
        string memory _appraiserReportIPFSHash,
        string memory _certificateIPFSHash,
        address _customer
    )
        external
        onlyOwner
        notZeroAddress(_customer)
        onlyOnPolygonAmoy
        returns (uint256 tokenizationRequestId)
    {
        if (
            bytes(_customerSubmissionIPFSHash).length == 0 ||
            bytes(_appraiserReportIPFSHash).length == 0 ||
            bytes(_certificateIPFSHash).length == 0
        ) {
            revert dWork__InvalidIPFSHash();
        }

        ++s_tokenizationRequestId;

        _registerTokenizationRequest(
            _customerSubmissionIPFSHash,
            _appraiserReportIPFSHash,
            _certificateIPFSHash,
            _customer,
            s_tokenizationRequestId
        );

        s_customerTokenizationRequests[_customer].push(s_tokenizationRequestId);

        _sendCertificateExtractionRequest(
            s_tokenizationRequestId,
            _certificateIPFSHash
        );

        return s_tokenizationRequestId;
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

    /**
     * @param _tokenizationRequestId The ID of the tokenization request.
     * @param _shareSupply The total supply of the shares tokens to be created.
     * @param _sharePriceUsd The price of each share token in USD.
     * @notice Fractionalize a tokenized work of art into shares tokens.
     * @dev Tasks the WorkSharesManager contract to create ERC1155 shares tokens for the work.
     * This function can only be called after the work has been minted as an ERC721 token.
     */
    function createWorkShares(
        uint256 _tokenizationRequestId,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external onlyOwner {
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];

        if (!tokenizedWork.isMinted) {
            revert dWork__WorkNotMinted();
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

    /**
     * @dev Triggered using Chainlink log-based Automation once a VerifierTaskDone event is emitted by
     * the WorkVerifier contract. It confirms that the work verification is needed and that performUpkeep() should be called.
     * The tokenizationRequestId retrieved from the log us encoded and passed as performData to performUpkeep().
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
     * @param performData The encoded tokenizationRequestId.
     * @dev Called by Chainlink log-based Automation to fulfill the certificate extraction the work verification request.
     * It should be triggered by when the VerifierTaskDone event is emitted by the WorkVerifier contract.
     */
    function performUpkeep(bytes calldata performData) external override {
        uint256 tokenizationRequestId = abi.decode(performData, (uint256));

        // We retrieve the last verified data associated with our tokenization request from the WorkVerifier contract.
        // This way we don't have to pass the data via the log and trust the performData integrity.
        IDWorkConfig.VerifiedWorkData memory lastVerifiedData = IWorkVerifier(
            s_workVerifier
        ).getLastVerifiedData(tokenizationRequestId);

        if (
            s_tokenizationRequests[tokenizationRequestId].verificationStep ==
            VerificationStep.PendingCertificateAnalysis
        ) {
            _fulfillCertificateExtractionRequest(
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

    /**
     * @param _workTokenId The ID of the work token to be listed for sale.
     * @param _listPriceUsd The price at which the work token will be listed.
     * @notice List a work token for sale.
     * @dev Transfer the work token to the dWork contract and set the listing price.
     */
    function listWorkToken(
        uint256 _listPriceUsd,
        uint256 _workTokenId
    ) external {
        TokenizedWork storage tokenizedWork = s_tokenizedWorkByTokenId[
            _workTokenId
        ];
        _ensureWorkOwner(tokenizedWork.owner);
        tokenizedWork.listingPriceUsd = _listPriceUsd;
        tokenizedWork.isListed = true;
        safeTransferFrom(msg.sender, address(this), _workTokenId, "");
    }

    /**
     * @param _workTokenId The ID of the work token to be unlisted.
     * @notice Unlist a work token that is listed for sale.
     * @dev Transfer the work token back to the owner and set the listing price to 0.
     */
    function unlistWorkToken(uint256 _workTokenId) external {
        TokenizedWork storage tokenizedWork = s_tokenizedWorkByTokenId[
            _workTokenId
        ];
        _ensureWorkOwner(tokenizedWork.owner);
        tokenizedWork.listingPriceUsd = 0;
        tokenizedWork.isListed = false;
        _update(msg.sender, _workTokenId, msg.sender);
    }

    /**
     *
     * @param _workTokenId The ID of the work token to be bought.
     * @notice Buy a work token that is listed for sale.
     * Once bought, we update the tokenized work data, transfer the work token to the buyer and call
     * the WorkSharesManager contract to enable the share holders to claim their share of the sale.
     */
    function buyWorkToken(uint256 _workTokenId) external payable {
        TokenizedWork storage tokenizedWork = s_tokenizedWorkByTokenId[
            _workTokenId
        ];

        uint256 sentValueUsd = msg.value.getConversionRate(s_priceFeed);

        if (sentValueUsd < tokenizedWork.listingPriceUsd) {
            revert dWork__NotEnoughValueSent();
        }

        _updateTokenizedWorkOnSale(tokenizedWork, sentValueUsd);
        _update(msg.sender, _workTokenId, address(this));

        uint256 protocolFees = (msg.value * PROTOCOL_FEE_PERCENTAGE) / 1000;
        s_protocolFees += protocolFees;
        uint256 sellValue = msg.value - protocolFees;

        IDWorkSharesManager(s_workSharesManager).onWorkSold{value: sellValue}(
            tokenizedWork.sharesTokenId
        );
    }

    /**
     * @param _newAppraiserReportIPFSHash The IPFS hash of the latest appraiser report.
     * @notice Update the IPFS hash of the latest appraiser report.
     * It should be called by the Mosaic Admins after the appraisers have submitted their latest reports (e.g. every 3 months).
     */
    function updateLastAppraiserReportIPFSHash(
        uint256 _tokenizationRequestId,
        string calldata _newAppraiserReportIPFSHash
    ) external onlyOwner {
        s_tokenizationRequests[_tokenizationRequestId]
            .appraiserReportIPFSHash = _newAppraiserReportIPFSHash;
    }

    function setCustomerSubmissionIPFSHash(
        uint256 _tokenizationRequestId,
        string memory _customerSubmissionIPFSHash
    ) external onlyOwner {
        s_tokenizationRequests[_tokenizationRequestId]
            .customerSubmissionIPFSHash = _customerSubmissionIPFSHash;
    }

    function setCertificateIPFSHash(
        uint256 _tokenizationRequestId,
        string memory _certificateIPFSHash
    ) external onlyOwner {
        s_tokenizationRequests[_tokenizationRequestId]
            .certificateIPFSHash = _certificateIPFSHash;
    }

    function setWorkSharesManager(
        address _workSharesManager
    ) external onlyOwner {
        s_workSharesManager = _workSharesManager;
    }

    function setWorkVerifier(address _workVerifier) external onlyOwner {
        s_workVerifier = _workVerifier;
    }

    function enableChain(
        uint64 _chainSelector,
        address xWorkAddress
    ) external onlyOwner {
        _enableChain(_chainSelector, xWorkAddress);
    }

    function pauseWorkToken(uint256 _tokenizationRequestId) external onlyOwner {
        _pauseWorkToken(_tokenizationRequestId);
    }

    function unpauseWorkToken(
        uint256 _tokenizationRequestId
    ) external onlyOwner {
        _unpauseWorkToken(_tokenizationRequestId);
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
            emit CertificateExtractionError(
                _tokenizationRequestId,
                _artist,
                _work
            );
            return;
        }

        WorkCertificate memory workCertificate;
        workCertificate = WorkCertificate({artist: _artist, work: _work});

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
            emit WorkVerificationError(_tokenizationRequestId, _ownerName);
            return;
        }

        s_tokenizationRequests[_tokenizationRequestId]
            .verificationStep = VerificationStep.WorkVerificationDone;

        s_tokenizationRequests[_tokenizationRequestId].lastVerifiedAt = block
            .timestamp;

        // If the work was already minted, we compare the latest appraiser report with the previous one.
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
        TokenizedWork memory tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];
        if (
            (keccak256(abi.encodePacked(_ownerName)) !=
                keccak256(abi.encodePacked(tokenizedWork.ownerName))) ||
            _priceUsd != tokenizedWork.lastWorkPriceUsd
        ) {
            _pauseWorkToken(_tokenizationRequestId);
            if (isFractionalized(_tokenizationRequestId)) {
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
            if (isPaused(_tokenizationRequestId)) {
                _unpauseWorkToken(_tokenizationRequestId);
                IDWorkSharesManager(s_workSharesManager).unpauseShares(
                    _tokenizationRequestId
                );
            }
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

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

    function isPaused(
        uint256 _tokenizationRequestId
    ) public view returns (bool) {
        return s_tokenizationRequests[_tokenizationRequestId].isPaused;
    }

    function bytes32ToUint256(bytes32 _uint) public pure returns (uint256) {
        return uint256(_uint);
    }

    function getLastTokenizationRequestId() public view returns (uint256) {
        return s_tokenizationRequestId;
    }

    function getLastTokenId() public view returns (uint256) {
        return s_tokenId;
    }

    function getTokenizationRequest(
        uint256 _tokenizationRequestId
    ) public view returns (TokenizedWork memory) {
        return s_tokenizationRequests[_tokenizationRequestId];
    }

    function getTokenizationRequestStatus(
        uint256 _tokenizationRequestId
    ) public view returns (VerificationStep) {
        return s_tokenizationRequests[_tokenizationRequestId].verificationStep;
    }

    function customerTokenizationRequests(
        address _customer
    ) public view returns (uint256[] memory) {
        return s_customerTokenizationRequests[_customer];
    }

    function getTokenizationRequestByWorkTokenId(
        uint256 _workTokenId
    ) public view returns (TokenizedWork memory) {
        return s_tokenizedWorkByTokenId[_workTokenId];
    }

    function getWorkSharesManager() public view returns (address) {
        return s_workSharesManager;
    }

    function getWorkVerifier() public view returns (address) {
        return s_workVerifier;
    }
}
