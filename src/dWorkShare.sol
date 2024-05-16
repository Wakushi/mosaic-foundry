// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceConverter} from "./libraries/PriceConverter.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract dWorkShare is ERC20, Pausable {
    using PriceConverter for uint256;

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink Data Feed
    AggregatorV3Interface private s_priceFeed;

    uint256 immutable i_maxShareSupply;
    uint256 immutable i_sharePriceUsd;
    address immutable i_workContract;
    uint256 s_totalShareBought;
    uint256 s_totalSellValueUsd;
    address s_workOwner;

    ///////////////////
    // Events
    ///////////////////

    event ShareBought(uint256 amount, address buyer);

    //////////////////
    // Errors
    ///////////////////

    error dWorkShare__InsufficientFunds();
    error dWorkShare__InitialSaleClosed();
    error dWork__NotWorkContract();

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
    ) ERC20(_name, _symbol) {
        _mint(_workOwner, _shareSupply);
        i_sharePriceUsd = _sharePriceUsd;
        i_maxShareSupply = _shareSupply;
        i_workContract = _workContract;
        s_priceFeed = AggregatorV3Interface(_priceFeed);
        s_workOwner = _workOwner;
    }

    function buyInitialShare(
        uint256 _shareAmount
    ) external payable whenNotPaused {
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
        _transfer(s_workOwner, msg.sender, _shareAmount);
        emit ShareBought(_shareAmount, msg.sender);
    }

    function pauseContract() external whenNotPaused {
        _ensureOnlyWorkContract();
        _pause();
    }

    function unpauseContract() external whenPaused {
        _ensureOnlyWorkContract();
        _unpause();
    }

    function transfer(
        address to,
        uint256 value
    ) public override whenNotPaused returns (bool) {
        return super.transfer(to, value);
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override whenNotPaused returns (bool) {
        return super.transferFrom(from, to, value);
    }

    function _ensureOnlyWorkContract() internal view {
        if (msg.sender != i_workContract) {
            revert dWork__NotWorkContract();
        }
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
        return i_workContract;
    }
}
