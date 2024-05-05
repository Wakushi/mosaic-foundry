// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract dWork is FunctionsClient, Ownable, ERC721, Pausable {
    ///////////////////
    // Type declarations
    ///////////////////

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    struct WorkVerificationRequest {
        string workID;
        uint256 requestAt;
    }

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink Functions
    address s_functionsRouter;
    bytes32 s_donID;
    uint32 s_gasLimit = 300000;
    uint64 s_subscriptionId;
    string s_workVerificationSource;
    bytes s_lastResponse;
    bytes s_lastError;
    bytes32 s_lastRequestId;

    mapping(bytes32 requestId => WorkVerificationRequest request)
        private s_requestIdToRequest;
    address immutable i_factoryAddress;
    string constant BASE_URI =
        "https://peach-genuine-lamprey-766.mypinata.cloud/ipfs/";

    // Work
    uint256 s_workPriceUsd;
    string s_workURI;
    bool s_isMinted;
    bool s_isFractionalized;
    address s_customer;
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

    //////////////////
    // Modifiers
    //////////////////

    modifier notMinted() {
        _ensureNotMinted();
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor(
        address _functionsRouter,
        bytes32 _donId,
        uint32 _gasLimit,
        string memory _workVerificationSource,
        address _customer,
        string memory _workName,
        string memory _workSymbol,
        string memory _workURI,
        address _factoryAddress
    )
        FunctionsClient(_functionsRouter)
        Ownable(msg.sender)
        ERC721(_workName, _workSymbol)
    {
        s_donID = _donId;
        s_gasLimit = _gasLimit;
        s_workVerificationSource = _workVerificationSource;
        s_customer = _customer;
        s_workURI = _workURI;
        i_factoryAddress = _factoryAddress;
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
     *
     * @param _args [customerAddress, workID]
     * @dev Performs multiple API calls using Chainlink Functions to verify the work
     */
    function requestWorkVerification(
        string[] calldata _args
    ) external onlyOwner notMinted {
        _sendRequest(_args);
    }

    function setIsFractionalized(bool _isFractionalized) external {
        _ensureOwnerOrFactory();
        s_isFractionalized = _isFractionalized;
    }

    function setCFSubId(uint64 _subscriptionId) external onlyOwner {
        s_subscriptionId = _subscriptionId;
    }

    ////////////////////
    // Internal
    ////////////////////

    function _sendRequest(
        string[] calldata args
    ) internal returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_workVerificationSource);
        if (args.length > 0) {
            req.setArgs(args);
        }

        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            s_subscriptionId,
            s_gasLimit,
            s_donID
        );

        s_requestIdToRequest[s_lastRequestId] = WorkVerificationRequest(
            args[0],
            block.timestamp
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

        s_lastResponse = response;
        uint256 workPrice = uint256(bytes32(response));

        if (workPrice > 0) {
            _mintWork();
            s_workPriceUsd = workPrice;
        }

        s_lastError = err;

        emit Response(requestId, workPrice, s_lastResponse, s_lastError);
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
}
