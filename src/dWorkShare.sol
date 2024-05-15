// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceConverter} from "./libraries/PriceConverter.sol";

contract dWorkShare is ERC20, Ownable {
    using PriceConverter for uint256;

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink Data Feed
    AggregatorV3Interface private s_priceFeed;

    uint256 immutable i_maxShareSupply;
    uint256 immutable i_sharePriceUsd;
    uint256 s_totalShareBought;
    uint256 s_totalSellValueUsd;
    address s_workContract;

    ///////////////////
    // Events
    ///////////////////

    event ShareBought(uint256 amount, address buyer);

    //////////////////
    // Errors
    ///////////////////

    error dWorkShare__InsufficientFunds();
    error dWorkShare__InitialSaleClosed();

    //////////////////
    // Functions
    //////////////////

    constructor(
        address _workContract,
        address _workOwner,
        uint256 _shareSupply,
        uint256 _sharePriceUsd,
        string memory _name,
        string memory _symbol,
        address _priceFeed
    ) ERC20(_name, _symbol) Ownable(_workOwner) {
        _mint(_workOwner, _shareSupply);
        i_sharePriceUsd = _sharePriceUsd;
        i_maxShareSupply = _shareSupply;
        s_workContract = _workContract;
        s_priceFeed = AggregatorV3Interface(_priceFeed);
    }

    function buyInitialShare(uint256 _shareAmount) external payable {
        if (s_totalShareBought + _shareAmount > i_maxShareSupply) {
            revert dWorkShare__InitialSaleClosed();
        }

        uint256 sentValueUsd = msg.value.getConversionRate(s_priceFeed);
        uint256 usdAmountDue = _shareAmount * i_sharePriceUsd;

        if (sentValueUsd < usdAmountDue) {
            revert dWorkShare__InsufficientFunds();
        }

        ++s_totalShareBought;
        s_totalSellValueUsd += usdAmountDue;
        _transfer(owner(), msg.sender, _shareAmount);
        emit ShareBought(_shareAmount, msg.sender);
    }

    function getSharePriceUsd() external view returns (uint256) {
        return i_sharePriceUsd;
    }

    function getMaxShareSupply() external view returns (uint256) {
        return i_maxShareSupply;
    }

    function getTotalShareBought() external view returns (uint256) {
        return s_totalShareBought;
    }

    function getTotalSellValueUsd() external view returns (uint256) {
        return s_totalSellValueUsd;
    }

    function getWorkContract() external view returns (address) {
        return s_workContract;
    }
}
