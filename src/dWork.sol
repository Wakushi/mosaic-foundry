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
    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    struct dWorkConfig {
        address gallery;
        string workName;
        string workSymbol;
        address functionsRouter;
        bytes32 donId;
    }

    // Chainlink Functions
    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;
    string s_workVerificationSource;
    bytes32 s_donID;
    uint32 s_gasLimit = 300000;
    address s_functionsRouter;

    string public constant BASE_URI =
        "https://peach-genuine-lamprey-766.mypinata.cloud/ipfs/";
    string public s_workURI;
    bool public s_isMinted;
    address public s_gallery;
    uint256 public s_lastVerifiedAt;

    event Response(
        bytes32 indexed requestId,
        string character,
        bytes response,
        bytes err
    );

    error dWork__AlreadyMinted();
    error dWork__UnexpectedRequestID(bytes32 requestId);

    constructor(
        dWorkConfig memory _config
    )
        FunctionsClient(_config.functionsRouter)
        Ownable(msg.sender)
        ERC721(_config.workName, _config.workSymbol)
    {
        s_gallery = _config.gallery;
        s_donID = _config.donId;
        s_functionsRouter = _config.functionsRouter;
    }

    function performWorkVerification(string memory _workId) external onlyOwner {
        // Goal: Verify that the work is original, unique and owned by the gallery
        //
    }

    function sendRequest(
        uint64 subscriptionId,
        string[] calldata args
    ) external onlyOwner returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_workVerificationSource); // Initialize the request with JS code
        if (args.length > 0) req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            s_gasLimit,
            s_donID
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
        if (s_isMinted) {
            revert dWork__AlreadyMinted();
        }
        s_isMinted = true;
        _safeMint(s_gallery, 0);
    }
}
