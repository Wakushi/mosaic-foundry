// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Chainlink
import {Log, ILogAutomation} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";
// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
// Custom
import {AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {PriceConverter} from "./libraries/PriceConverter.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";
import {xChainAsset} from "./xChainAsset.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {IWorkVerifier} from "./interfaces/IWorkVerifier.sol";

contract dWork is xChainAsset, ILogAutomation {
    using OracleLib for AggregatorV3Interface;

    AggregatorV3Interface immutable i_usdcUsdFeed;
    uint256 s_protocolFees;

    error dWork__InvalidIPFSHash();
    error dWork__NotEnoughValueSent();
    error dWork__TransferFailed();

    constructor(
        address _workSharesManager,
        address _workVerifier,
        address _uscdUsdpriceFeed,
        address _ccipRouterAddress,
        address _linkTokenAddress,
        address _usdcAddress
    )
        xChainAsset(
            _ccipRouterAddress,
            _linkTokenAddress,
            _usdcAddress,
            _workVerifier,
            _workSharesManager
        )
    {
        i_usdcUsdFeed = AggregatorV3Interface(_uscdUsdpriceFeed);
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
     *
     * @notice Open a new tokenization request for an art piece. It registers the initial data and tasks the WorkVerifier contract to extract the certificate of authenticity.
     * This method will be called by the Mosaic Admins after the art appraisers have submitted their reports along with a scanned copy of the certificate of authenticity.
     *
     * @dev Only the 'minter' contract (dWork instance deployed on Polygon Amoy) can perform this function.
     */
    function openTokenizationRequest(
        string memory _customerSubmissionIPFSHash,
        string memory _appraiserReportIPFSHash,
        string memory _certificateIPFSHash,
        address _customer
    )
        external
        onlyOwner
        onlyOnPolygonAmoy
        returns (uint256 tokenizationRequestId)
    {
        if (_customer == address(0)) {
            revert dWork__NotZeroAddress();
        }

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
    function requestWorkVerification(uint256 _tokenizationRequestId) external {
        _ensureProcessOrder(
            _tokenizationRequestId,
            VerificationStep.CertificateAnalysisDone
        );

        if (s_tokenizationRequests[_tokenizationRequestId].isMinted) {
            _ensureEnoughTimePassedSinceLastVerification(
                _tokenizationRequestId
            );
        }
        _sendWorkVerificationRequest(_tokenizationRequestId);
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
        uint256 tokenizationRequestId = uint256(log.topics[1]);
        VerificationStep requestVerificationStep = s_tokenizationRequests[
            tokenizationRequestId
        ].verificationStep;
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
     * @notice List a work token for sale.
     * @dev Transfer the work token ownership to the dWork contract and set the listing price.
     */
    function listWorkToken(
        uint256 _workTokenId,
        uint256 _listPriceUsd
    ) external {
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            s_tokenizationRequestIdByTokenId[_workTokenId]
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
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            s_tokenizationRequestIdByTokenId[_workTokenId]
        ];
        _ensureWorkOwner(tokenizedWork.owner);
        tokenizedWork.listingPriceUsd = 0;
        tokenizedWork.isListed = false;
        _update(msg.sender, _workTokenId, address(this));
    }

    /**
     *
     * @param _workTokenId The ID of the work token to be bought.
     * @notice Buy a work token that is listed for sale.
     * Once bought, we update the tokenized work data, transfer the work token to the buyer and call
     * the WorkSharesManager contract to enable the share holders to claim their share of the sale.
     */
    function buyWorkToken(uint256 _workTokenId) external {
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            s_tokenizationRequestIdByTokenId[_workTokenId]
        ];

        uint256 sentValueUSDC = getUsdcValueOfUsd(
            tokenizedWork.listingPriceUsd
        );

        // Buyer has to approve the listing price in USDC to the dWork contract
        if (
            !IERC20(i_usdc).transferFrom(
                msg.sender,
                address(this),
                sentValueUSDC
            )
        ) {
            revert dWork__TransferFailed();
        }

        // Transfer the work token to the buyer
        _update(msg.sender, _workTokenId, address(this));

        uint256 protocolFees = (sentValueUSDC * 30) / 1000;
        s_protocolFees += protocolFees;
        uint256 sellValueUSDC = sentValueUSDC - protocolFees;

        // If the work is fractionalized, we call the WorkSharesManager contract to enable the share holders to claim their share of the sale.
        if (tokenizedWork.isFractionalized) {
            // If the work token was sent to another chain, we need to send a CCIP message
            // to the chain where the shares were originally minted along with the sale value in USDC.
            if (POLYGON_AMOY_CHAIN_ID != block.chainid) {
                _xChainOnWorkSold(tokenizedWork.sharesTokenId, sellValueUSDC);
            } else {
                // If the shares were minted on the same chain as the associated work is on, we transfer the USDC value to the WorkSharesManager contract.
                if (
                    !IERC20(i_usdc).transfer(s_workSharesManager, sellValueUSDC)
                ) {
                    revert dWork__TransferFailed();
                }

                IDWorkSharesManager(s_workSharesManager).onWorkSold(
                    tokenizedWork.sharesTokenId,
                    sellValueUSDC
                );
            }
        } else {
            // If the work is not fractionalized, we transfer the USDC value to the previous work owner.
            if (!IERC20(i_usdc).transfer(tokenizedWork.owner, sellValueUSDC)) {
                revert dWork__TransferFailed();
            }
        }

        // Update the tokenized work data
        _updateTokenizedWorkOnSale(tokenizedWork);
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

    ////////////////////
    // External / Public View
    ////////////////////

    function getUsdcPrice() public view returns (uint256) {
        (, int256 price, , , ) = i_usdcUsdFeed.staleCheckLatestRoundData();
        return uint256(price) * 1e10;
    }

    function getUsdcValueOfUsd(
        uint256 usdAmount
    ) public view returns (uint256) {
        return (usdAmount * getUsdcPrice()) / 1e18;
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

    function getTokenizationRequestIdByWorkTokenId(
        uint256 _workTokenId
    ) public view returns (uint256) {
        return s_tokenizationRequestIdByTokenId[_workTokenId];
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
