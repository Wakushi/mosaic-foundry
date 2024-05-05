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
    uint32 s_gasLimit = 300000;
    string s_workVerificationSource;
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
        uint32 _gasLimit,
        string memory _workVerificationSource,
        address _priceFeed
    ) Ownable(msg.sender) {
        s_functionsRouter = _functionsRouter;
        s_donID = _donId;
        s_gasLimit = _gasLimit;
        s_workVerificationSource = _workVerificationSource;
        s_priceFeed = _priceFeed;
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
}
