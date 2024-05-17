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

    address s_priceFeed;
    address s_workSharesManager;
    address s_workVerifier;

    mapping(address customer => address[] works) s_customerWorks;
    mapping(address workContract => uint256 workSharesTokenId) s_workShares;
    mapping(address workContract => bool isWorkContract) s_workContracts;

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
        address _priceFeed,
        address _workVerifier,
        address _workSharesManager
    ) Ownable(msg.sender) {
        s_priceFeed = _priceFeed;
        s_workVerifier = _workVerifier;
        s_workSharesManager = _workSharesManager;
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
            customerSubmissionIPFSHash: _customerSubmissionIPFSHash,
            appraiserReportIPFSHash: _appraiserReportIPFSHash,
            customer: _customer,
            workName: _workName,
            workSymbol: _workSymbol,
            factoryAddress: address(this),
            workSharesManagerAddress: s_workSharesManager,
            workVerifierAddress: s_workVerifier
        });
        dWork newWork = new dWork(workConfig);
        address newWorkAddress = address(newWork);
        s_customerWorks[_customer].push(newWorkAddress);
        s_workContracts[newWorkAddress] = true;
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

    function setWorkVerifier(address _workVerifier) external onlyOwner {
        s_workVerifier = _workVerifier;
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

    function getWorkSharesManager() external view returns (address) {
        return s_workSharesManager;
    }

    function getWorkVerifier() external view returns (address) {
        return s_workVerifier;
    }

    function isWorkContract(
        address _workContract
    ) external view returns (bool) {
        return s_workContracts[_workContract];
    }
}
