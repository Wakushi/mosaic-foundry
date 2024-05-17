// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {dWork} from "./dWork.sol";
import {IDWork} from "./interfaces/IDWork.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";

contract dWorkFactory is Ownable {
    ///////////////////
    // State variables
    ///////////////////

    address s_functionsRouter;
    bytes32 s_donID;
    uint64 s_functionsSubId;
    uint32 constant GAS_LIMIT = 300000;
    bytes s_secretReference;
    string s_workVerificationSource;
    string s_certificateExtractionSource;

    address s_priceFeed;
    address s_workSharesManager;

    mapping(address customer => address[] works) s_customerWorks;
    mapping(address workContract => uint256 workSharesTokenId) s_workShares;

    ///////////////////
    // Events
    ///////////////////

    event WorkDeployed(address workAddress, address customer);
    event WorkSharesCreated(uint256 sharesTokenId, address workContract);

    //////////////////
    // Errors
    ///////////////////

    error dWorkFactory__WorkNotMinted();
    error dWorkFactory__WorkAlreadyFractionalized();
    error dWorkFactory__WrongWorkPrice();

    constructor(
        address _functionsRouter,
        bytes32 _donId,
        bytes memory _secretReference,
        uint64 _functionsSubId,
        string memory _workVerificationSource,
        string memory _certificateExtractionSource,
        address _priceFeed
    ) Ownable(msg.sender) {
        s_functionsRouter = _functionsRouter;
        s_donID = _donId;
        s_secretReference = _secretReference;
        s_functionsSubId = _functionsSubId;
        s_workVerificationSource = _workVerificationSource;
        s_certificateExtractionSource = _certificateExtractionSource;
        s_priceFeed = _priceFeed;
    }

    //////////////////
    // External / Public
    ///////////////////

    function deployWork(
        address _customer,
        string memory _workName,
        string memory _workSymbol,
        string memory _customerSubmissionIPFSHash,
        string memory _appraiserReportIPFSHash
    ) external onlyOwner returns (address) {
        IDWorkConfig.dWorkConfig memory workConfig = IDWorkConfig.dWorkConfig({
            owner: owner(),
            donId: s_donID,
            functionsRouter: s_functionsRouter,
            functionsSubId: s_functionsSubId,
            gasLimit: GAS_LIMIT,
            secretReference: s_secretReference,
            workVerificationSource: s_workVerificationSource,
            certificateExtractionSource: s_certificateExtractionSource,
            customerSubmissionIPFSHash: _customerSubmissionIPFSHash,
            appraiserReportIPFSHash: _appraiserReportIPFSHash,
            customer: _customer,
            workName: _workName,
            workSymbol: _workSymbol,
            factoryAddress: address(this),
            workSharesManagerAddress: s_workSharesManager
        });
        dWork newWork = new dWork(workConfig);
        address newWorkAddress = address(newWork);
        s_customerWorks[_customer].push(newWorkAddress);
        emit WorkDeployed(newWorkAddress, _customer);
        return newWorkAddress;
    }

    function createWorkShares(
        address _workContract,
        uint256 _shareSupply
    ) external onlyOwner {
        IDWork dWorkContract = IDWork(_workContract);
        if (!dWorkContract.isMinted()) {
            revert dWorkFactory__WorkNotMinted();
        }
        if (dWorkContract.isFractionalized()) {
            revert dWorkFactory__WorkAlreadyFractionalized();
        }

        uint256 workPriceUsd = dWorkContract.getWorkPriceUsd();

        if (workPriceUsd == 0) {
            revert dWorkFactory__WrongWorkPrice();
        }

        uint256 _sharePriceUsd = workPriceUsd / _shareSupply;
        address workOwner = dWorkContract.getWorkOwner();

        uint256 sharesTokenId = IDWorkSharesManager(s_workSharesManager)
            .createShares(
                _workContract,
                workOwner,
                _shareSupply,
                _sharePriceUsd
            );

        dWorkContract.setWorkSharesTokenId(sharesTokenId);
        emit WorkSharesCreated(sharesTokenId, _workContract);
    }

    function setWorkSharesManager(
        address _workSharesManager
    ) external onlyOwner {
        s_workSharesManager = _workSharesManager;
    }

    function setSecretReference(
        bytes memory _secretReference
    ) external onlyOwner {
        s_secretReference = _secretReference;
    }

    //////////////////
    // External View
    ///////////////////

    function getCustomerWorks(
        address _customer
    ) external view returns (address[] memory) {
        return s_customerWorks[_customer];
    }

    function getWorkSharesTokenId(
        address _workContract
    ) external view returns (uint256) {
        return s_workShares[_workContract];
    }
}
