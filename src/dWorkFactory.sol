// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {dWork} from "./dWork.sol";
import {dWorkShare} from "./dWorkShare.sol";
import {IDWork} from "./interfaces/IDWork.sol";

contract dWorkFactory is Ownable {
    ///////////////////
    // State variables
    ///////////////////

    address s_functionsRouter;
    bytes32 s_donID;
    uint32 constant GAS_LIMIT = 300000;
    string s_workVerificationSource;
    string s_certificateExtractionSource;
    address s_priceFeed;

    mapping(address customer => address[] works) s_customerWorks;
    mapping(address workContract => address sharesContract) s_workShares;

    ///////////////////
    // Events
    ///////////////////

    event WorkDeployed(address workAddress, address customer);
    event WorkSharesDeployed(address workSharesAddress, address workContract);

    //////////////////
    // Errors
    ///////////////////

    error dWorkFactory__WorkNotMinted();
    error dWorkFactory__WorkAlreadyFractionalized();
    error dWorkFactory__WrongWorkPrice();

    constructor(
        address _functionsRouter,
        bytes32 _donId,
        string memory _workVerificationSource,
        string memory _certificateExtractionSource,
        address _priceFeed
    ) Ownable(msg.sender) {
        s_functionsRouter = _functionsRouter;
        s_donID = _donId;
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
        string memory _workURI
    ) external onlyOwner returns (address) {
        dWork newWork = new dWork(
            msg.sender,
            s_functionsRouter,
            s_donID,
            GAS_LIMIT,
            s_workVerificationSource,
            s_certificateExtractionSource,
            _customer,
            _workName,
            _workSymbol,
            _workURI,
            address(this)
        );
        address newWorkAddress = address(newWork);
        s_customerWorks[_customer].push(newWorkAddress);
        emit WorkDeployed(newWorkAddress, _customer);
        return newWorkAddress;
    }

    function deployWorkShare(
        address _workContract,
        address _initialOwner,
        uint256 _shareSupply,
        string memory _name,
        string memory _symbol
    ) external onlyOwner returns (address) {
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

        dWorkShare newWorkShares = new dWorkShare(
            _workContract,
            _initialOwner,
            _shareSupply,
            _sharePriceUsd,
            _name,
            _symbol,
            s_priceFeed
        );

        dWorkContract.setIsFractionalized(true);
        address newWorkSharesAddress = address(newWorkShares);
        s_workShares[_workContract] = newWorkSharesAddress;
        emit WorkSharesDeployed(newWorkSharesAddress, _workContract);
        return newWorkSharesAddress;
    }

    //////////////////
    // External View
    ///////////////////

    function getCustomerWorks(
        address _customer
    ) external view returns (address[] memory) {
        return s_customerWorks[_customer];
    }

    function getWorkShares(
        address _workContract
    ) external view returns (address) {
        return s_workShares[_workContract];
    }

    function getFunctionsRouter() external view returns (address) {
        return s_functionsRouter;
    }

    function getDonID() external view returns (bytes32) {
        return s_donID;
    }

    function getWorkVerificationSource() external view returns (string memory) {
        return s_workVerificationSource;
    }

    function getPriceFeed() external view returns (address) {
        return s_priceFeed;
    }
}
