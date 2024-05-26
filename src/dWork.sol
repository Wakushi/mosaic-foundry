// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Chainlink
import {Log, ILogAutomation} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
// OpenZeppelin
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
// Custom
import {AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {PriceConverter} from "./libraries/PriceConverter.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";
import {IWorkVerifier} from "./interfaces/IWorkVerifier.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";

contract dWork is
    ILogAutomation,
    ERC721,
    ERC721URIStorage,
    ERC721Burnable,
    Ownable,
    Pausable,
    IAny2EVMMessageReceiver,
    ReentrancyGuard
{
    ///////////////////
    // Type declarations
    ///////////////////

    using PriceConverter for uint256;

    enum VerificationStep {
        PendingCertificateAnalysis,
        CertificateAnalysisDone,
        PendingWorkVerification,
        WorkVerificationDone,
        Tokenized
    }

    enum PayFeesIn {
        Native,
        LINK
    }

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

    struct WorkCertificate {
        string artist;
        string work;
    }

    struct xChainWorkTokenTransferData {
        address from;
        address to;
        uint256 workTokenId;
    }

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink CCIP
    uint256 constant POLYGON_AMOY_CHAIN_ID = 80002;
    IRouterClient internal immutable i_ccipRouter;
    uint64 private immutable i_currentChainSelector;
    LinkTokenInterface internal immutable i_linkToken;
    mapping(uint64 destChainSelector => address xWorkAddress) s_chains;

    // Chainlink Price Feed
    AggregatorV3Interface private s_priceFeed;

    /**
     * @dev The tokenizationRequestId is a unique identifier for each tokenization request.
     * As a request could fail or not be fulfilled, the tokenizationRequestId is different from the tokenId
     * which is the unique identifier for each minted work.
     */
    uint256 s_tokenizationRequestId;
    uint256 s_tokenId;

    mapping(uint256 tokenizationRequestId => TokenizedWork tokenizedWork) s_tokenizationRequests;
    mapping(address customer => uint256[] tokenizationRequestsIds) s_customerTokenizationRequests;
    mapping(uint256 tokenizationRequestId => uint256 sharesTokenId) s_sharesTokenIds;
    mapping(uint256 workTokenId => TokenizedWork tokenizedWork) s_tokenizedWorkByTokenId;

    uint256 constant MIN_VERIFICATION_INTERVAL = 30 days;
    uint256 constant PROTOCOL_FEE_PERCENTAGE = 30; // 3%
    uint256 s_protocolFees;
    address s_workSharesManager;
    address s_workVerifier;

    bytes s_lastPerformData;

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
    event CertificateExtractionError(
        uint256 indexed tokenizationRequestId,
        string indexed errorTitle,
        string indexed errorMessage
    );
    event WorkVerificationError(
        uint256 tokenizationRequestId,
        string indexed errorMessage
    );
    event CrossChainSent(
        address from,
        address to,
        uint256 tokenId,
        uint64 sourceChainSelector,
        uint64 destinationChainSelector
    );
    event CrossChainReceived(
        address from,
        address to,
        uint256 tokenId,
        uint64 sourceChainSelector,
        uint64 destinationChainSelector
    );

    //////////////////
    // Errors
    //////////////////

    error dWork__WorkNotMinted();
    error dWork__AlreadyFractionalized();
    error dWork__ProcessOrderError();
    error dWork__NotEnoughTimePassedSinceLastVerification();
    error dWork__WorkVerificationNotExpected();
    error dWork__NotZeroAddress();
    error dWork__TokenPaused();
    error dWork__NotWorkOwner();
    error dWork__NotEnoughValueSent();
    error dWork__InvalidRouter();
    error dWork__ChainNotEnabled();
    error dWork__SenderNotEnabled();
    error dWork__NotEnoughBalanceForFees();
    error dWork__OnlyOnPolygonAmoy();

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

    modifier onlyWorkOwner(address _owner, uint256 _tokenId) {
        _ensureWorkOwnership(_owner, _tokenId);
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != address(i_ccipRouter)) {
            revert dWork__InvalidRouter();
        }
        _;
    }

    modifier onlyEnabledChain(uint64 _chainSelector) {
        if (s_chains[_chainSelector] == address(0)) {
            revert dWork__ChainNotEnabled();
        }
        _;
    }

    modifier onlyEnabledSender(uint64 _chainSelector, address _sender) {
        if (s_chains[_chainSelector] != _sender) {
            revert dWork__SenderNotEnabled();
        }
        _;
    }

    modifier onlyOnPolygonAmoy() {
        if (block.chainid != POLYGON_AMOY_CHAIN_ID) {
            revert dWork__OnlyOnPolygonAmoy();
        }
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
    ) Ownable(msg.sender) ERC721("xWork", "xWORK") {
        s_workSharesManager = _workSharesManager;
        s_workVerifier = _workVerifier;
        s_priceFeed = AggregatorV3Interface(_priceFeed);
        if (_ccipRouterAddress == address(0)) revert dWork__InvalidRouter();
        i_ccipRouter = IRouterClient(_ccipRouterAddress);
        i_linkToken = LinkTokenInterface(_linkTokenAddress);
        i_currentChainSelector = _currentChainSelector;
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
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
    )
        external
        onlyOwner
        notZeroAddress(_customer)
        onlyOnPolygonAmoy
        returns (uint256 tokenizationRequestId)
    {
        _createTokenizationRequest(
            _customerSubmissionIPFSHash,
            _appraiserReportIPFSHash,
            _certificateIPFSHash,
            _customer
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
     * @param _shareSupply The total supply of the shares tokens.
     * @param _sharePriceUsd The price of each share token in USD.
     * @notice Fractionalize a work of art into shares tokens.
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

    function listWorkToken(
        uint256 _listPriceUsd,
        uint256 _workTokenId
    ) external onlyWorkOwner(msg.sender, _workTokenId) {
        TokenizedWork storage tokenizedWork = s_tokenizedWorkByTokenId[
            _workTokenId
        ];
        tokenizedWork.listingPriceUsd = _listPriceUsd;
        tokenizedWork.isListed = true;
        safeTransferFrom(msg.sender, address(this), _workTokenId, "");
    }

    function unlistWorkToken(
        uint256 _workTokenId
    ) external onlyWorkOwner(msg.sender, _workTokenId) {
        TokenizedWork storage tokenizedWork = s_tokenizedWorkByTokenId[
            _workTokenId
        ];
        tokenizedWork.isListed = false;
        tokenizedWork.listingPriceUsd = 0;
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

    function xChainWorkTokenTransfer(
        address _from,
        address _to,
        uint256 _workTokenId,
        uint64 _destinationChainSelector,
        PayFeesIn _payFeesIn,
        uint256 _gasLimit
    )
        external
        nonReentrant
        onlyEnabledChain(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        _burn(_workTokenId);

        xChainWorkTokenTransferData memory data = xChainWorkTokenTransferData({
            from: _from,
            to: _to,
            workTokenId: _workTokenId
        });

        bytes memory encodedArgs = _encodeArgs(data);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(s_chains[_destinationChainSelector]),
            data: encodedArgs,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: _gasLimit})
            ),
            feeToken: _payFeesIn == PayFeesIn.LINK
                ? address(i_linkToken)
                : address(0)
        });

        uint256 fees = i_ccipRouter.getFee(_destinationChainSelector, message);

        if (_payFeesIn == PayFeesIn.LINK) {
            if (fees > i_linkToken.balanceOf(address(this))) {
                revert dWork__NotEnoughBalanceForFees();
            }

            i_linkToken.approve(address(i_ccipRouter), fees);

            messageId = i_ccipRouter.ccipSend(
                _destinationChainSelector,
                message
            );
        } else {
            if (fees > address(this).balance) {
                revert dWork__NotEnoughBalanceForFees();
            }

            messageId = i_ccipRouter.ccipSend{value: fees}(
                _destinationChainSelector,
                message
            );
        }

        emit CrossChainSent(
            _from,
            _to,
            _workTokenId,
            i_currentChainSelector,
            _destinationChainSelector
        );
    }

    function ccipReceive(
        Client.Any2EVMMessage calldata message
    )
        external
        virtual
        override
        onlyRouter
        nonReentrant
        onlyEnabledChain(message.sourceChainSelector)
        onlyEnabledSender(
            message.sourceChainSelector,
            abi.decode(message.sender, (address))
        )
    {
        uint64 sourceChainSelector = message.sourceChainSelector;
        (address from, address to, uint256 tokenId) = abi.decode(
            message.data,
            (address, address, uint256)
        );

        _safeMint(to, tokenId);
        // _createTokenizedWork("", "", "", to);

        emit CrossChainReceived(
            from,
            to,
            tokenId,
            sourceChainSelector,
            i_currentChainSelector
        );
    }

    function enableChain(
        uint64 _chainSelector,
        address _xWorkAddress
    ) external onlyOwner {
        s_chains[_chainSelector] = _xWorkAddress;
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

        emit CertificateExtracted(_tokenizationRequestId, workCertificate);
    }

    function _fulfillWorkVerificationRequest(
        uint256 _tokenizationRequestId,
        string memory _ownerName,
        uint256 _priceUsd
    ) internal {
        if (_priceUsd == 0) {
            emit WorkVerificationError(_tokenizationRequestId, _ownerName);
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

    function _createTokenizationRequest(
        string memory _customerSubmissionIPFSHash,
        string memory _appraiserReportIPFSHash,
        string memory _certificateIPFSHash,
        address _customer
    ) internal returns (uint256 tokenizationRequestId) {
        ++s_tokenizationRequestId;
        s_tokenizationRequests[s_tokenizationRequestId] = TokenizedWork({
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
        return s_tokenizationRequestId;
    }

    function _createTokenizedWork(
        string memory _customerSubmissionIPFSHash,
        string memory _appraiserReportIPFSHash,
        string memory _certificateIPFSHash,
        address _customer,
        string memory _ownerName,
        uint256 _lastWorkPriceUsd,
        string memory _artist,
        string memory _work,
        uint256 _sharesTokenId
    ) internal {
        uint256 tokenizationRequestId = _createTokenizationRequest(
            _customerSubmissionIPFSHash,
            _appraiserReportIPFSHash,
            _certificateIPFSHash,
            _customer
        );

        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            tokenizationRequestId
        ];

        tokenizedWork.ownerName = _ownerName;
        tokenizedWork.lastWorkPriceUsd = _lastWorkPriceUsd;
        tokenizedWork.verificationStep = VerificationStep.Tokenized;
        tokenizedWork.isMinted = true;
        tokenizedWork.certificate = WorkCertificate({
            artist: _artist,
            work: _work
        });

        if (_sharesTokenId != 0) {
            tokenizedWork.sharesTokenId = _sharesTokenId;
            tokenizedWork.isFractionalized = true;
        }
    }

    function _updateTokenizedWorkOnSale(
        TokenizedWork memory tokenizedWork,
        uint256 _soldValueUsd
    ) internal {
        TokenizedWork memory updatedWork = TokenizedWork({
            customerSubmissionIPFSHash: tokenizedWork
                .customerSubmissionIPFSHash,
            appraiserReportIPFSHash: tokenizedWork.appraiserReportIPFSHash,
            certificateIPFSHash: tokenizedWork.certificateIPFSHash,
            owner: msg.sender,
            ownerName: tokenizedWork.ownerName,
            lastWorkPriceUsd: _soldValueUsd,
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

    function _encodeArgs(
        xChainWorkTokenTransferData memory _encodeTokenTransferData
    ) internal pure returns (bytes memory) {
        bytes memory encodedArgs = abi.encode(
            _encodeTokenTransferData.from,
            _encodeTokenTransferData.to,
            _encodeTokenTransferData.workTokenId
        );
        return encodedArgs;
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
        if (s_tokenizedWorkByTokenId[_tokenId].isPaused) {
            revert dWork__TokenPaused();
        }
    }

    function _ensureWorkOwnership(
        address _owner,
        uint256 _tokenId
    ) internal view {
        if (ownerOf(_tokenId) != _owner) {
            revert dWork__NotWorkOwner();
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function getLastTokenizationRequestId() public view returns (uint256) {
        return s_tokenizationRequestId;
    }

    function getLastTokenId() public view returns (uint256) {
        return s_tokenId;
    }

    function getLastPerformData() public view returns (bytes memory) {
        return s_lastPerformData;
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

    function getSharesTokenId(
        uint256 _tokenizationRequestId
    ) public view returns (uint256) {
        return s_sharesTokenIds[_tokenizationRequestId];
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
