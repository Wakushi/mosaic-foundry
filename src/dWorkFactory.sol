// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {dWork} from "./dWork.sol";
import {dWorkShare} from "./dWorkShare.sol";

contract dWorkFactory is Ownable {
    address s_functionsRouter;
    bytes32 s_donID;
    uint32 s_gasLimit = 300000;
    string s_workVerificationSource;

    constructor(
        address _functionsRouter,
        bytes32 _donId,
        uint32 _gasLimit,
        string memory _workVerificationSource
    ) Ownable(msg.sender) {
        s_functionsRouter = _functionsRouter;
        s_donID = _donId;
        s_gasLimit = _gasLimit;
        s_workVerificationSource = _workVerificationSource;
    }

    function deployWork(
        address _functionsRouter,
        bytes32 _donId,
        uint32 _gasLimit,
        string memory _workVerificationSource,
        address _customer,
        string memory _workName,
        string memory _workSymbol,
        string memory _workURI
    ) external onlyOwner returns (address) {
        dWork newWork = new dWork(
            _functionsRouter,
            _donId,
            _gasLimit,
            _workVerificationSource,
            _customer,
            _workName,
            _workSymbol,
            _workURI
        );
        return address(newWork);
    }

    function deployWorkShare(
        address _initialOwner,
        uint256 _shareSupply,
        uint256 _sharePrice,
        string memory _name,
        string memory _symbol
    ) external onlyOwner returns (address) {
        dWorkShare newWorkShare = new dWorkShare(
            _initialOwner,
            _shareSupply,
            _sharePrice,
            _name,
            _symbol
        );
        return address(newWorkShare);
    }
}
