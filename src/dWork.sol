// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// work json example
// https://peach-genuine-lamprey-766.mypinata.cloud/ipfs/QmSimNV6bDWiVocmH1xqkQwBeRKDuUWmMP2CNu4tfi2vfK

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
    bytes s_lastResponse;
    bytes s_lastError;
    string s_workVerificationSource;
    bytes32 s_lastRequestId;

    mapping(bytes32 requestId => WorkVerificationRequest request)
        private s_requestIdToRequest;

    string public s_workURI;
    bool public s_isMinted;
    address public s_gallery;
    uint256 public s_lastVerifiedAt;
    string public constant BASE_URI =
        "https://peach-genuine-lamprey-766.mypinata.cloud/ipfs/";

    ///////////////////
    // Events
    ///////////////////

    event Response(
        bytes32 indexed requestId,
        string character,
        bytes response,
        bytes err
    );

    //////////////////
    // Errors
    ///////////////////

    error dWork__AlreadyMinted();
    error dWork__UnexpectedRequestID(bytes32 requestId);

    //////////////////
    // Modifiers
    //////////////////

    modifier notMinted() {
        _ensureNotMinted();
        _;
    }

    constructor(
        bytes32 _donId,
        address _gallery,
        string memory _workName,
        string memory _workSymbol,
        address _functionsRouter
    )
        FunctionsClient(_functionsRouter)
        Ownable(msg.sender)
        ERC721(_workName, _workSymbol)
    {
        s_gallery = _gallery;
        s_donID = _donId;
        s_functionsRouter = _functionsRouter;
    }

    ////////////////////
    // External / Public
    ////////////////////

    function setCFSubId(uint64 _subscriptionId) external onlyOwner {
        s_subscriptionId = _subscriptionId;
    }

    function requestWorkVerification(
        string[] calldata _args
    ) external onlyOwner notMinted {
        // Goal: Verify that the work is original, unique and owned by the gallery
        _sendRequest(_args);
    }

    ////////////////////
    // Internal
    ////////////////////

    // Args : [workID, galleryAddress, workURI]

    function _sendRequest(
        string[] calldata args
    ) internal onlyOwner returns (bytes32 requestId) {
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

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (s_lastRequestId != requestId) {
            revert dWork__UnexpectedRequestID(requestId);
        }
        s_lastResponse = response;

        // Decode the response data and check if the work is validated
        string memory isValid = string(response);
        if (
            keccak256(abi.encodePacked(isValid)) ==
            keccak256(abi.encodePacked("true"))
        ) {
            _mintWork();
        }

        s_lastError = err;

        emit Response(requestId, isValid, s_lastResponse, s_lastError);
    }

    function _mintWork() internal {
        s_isMinted = true;
        _safeMint(s_gallery, 0);
    }

    function _ensureNotMinted() internal view returns (bool) {
        return s_isMinted;
    }
}
