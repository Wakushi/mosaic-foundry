// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceConverter} from "./libraries/PriceConverter.sol";

contract dWorkSharesManager is ERC1155, Ownable {
    using PriceConverter for uint256;

    struct WorkShares {
        uint256 maxShareSupply;
        uint256 sharePriceUsd;
        address workContract;
        uint256 totalShareBought;
        uint256 totalSellValueUsd;
        address workOwner;
        bool isPaused;
    }

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink Data Feed
    AggregatorV3Interface private s_priceFeed;
    address s_workFactoryAddress;
    uint256 s_tokenId;

    mapping(uint256 sharesTokenId => WorkShares workShares) s_workShares;
    mapping(address workContract => uint256 sharesTokenId) s_sharesTokenIds;

    ///////////////////
    // Events
    ///////////////////

    event SharesCreated(
        uint256 sharesTokenId,
        uint256 maxShareSupply,
        address workContract,
        address workOwner
    );
    event ShareBought(uint256 sharesTokenId, uint256 amount, address buyer);
    event SharesPaused(WorkShares workShares, bool isPaused);

    //////////////////
    // Errors
    ///////////////////

    error dWorkShare__InsufficientFunds();
    error dWorkShare__InitialSaleClosed();
    error dWork__NotWorkContract();
    error dWork__NotFactoryContract();
    error dWork__SharesPaused();

    //////////////////
    // Modifiers
    //////////////////

    modifier whenSharesNotPaused(uint256 _sharesTokenId) {
        _ensureSharesNotPaused(_sharesTokenId);
        _;
    }

    modifier whenSharesBatchNotPaused(uint256[] memory _sharesTokenIds) {
        _ensureSharesBatchNotPaused(_sharesTokenIds);
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor(
        string memory _baseUri,
        address _priceFeed
    ) ERC1155(_baseUri) Ownable(msg.sender) {
        s_priceFeed = AggregatorV3Interface(_priceFeed);
    }

    ////////////////////
    // External / Public
    ////////////////////

    function createShares(
        address _workContract,
        address _workOwner,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external returns (uint256) {
        _ensureOnlyWorkFactory();

        unchecked {
            ++s_tokenId;
        }

        _mint(_workOwner, s_tokenId, _shareSupply, "");

        s_workShares[s_tokenId] = WorkShares({
            maxShareSupply: _shareSupply,
            sharePriceUsd: _sharePriceUsd,
            workContract: _workContract,
            totalShareBought: 0,
            totalSellValueUsd: 0,
            workOwner: _workOwner,
            isPaused: false
        });

        s_sharesTokenIds[_workContract] = s_tokenId;

        emit SharesCreated(s_tokenId, _shareSupply, _workContract, _workOwner);

        return s_tokenId;
    }

    function buyInitialShare(
        uint256 _sharesTokenId,
        uint256 _shareAmount
    ) external payable whenSharesNotPaused(_sharesTokenId) {
        WorkShares storage workShares = _ensureTokenIdExists(_sharesTokenId);
        if (
            workShares.totalShareBought + _shareAmount >
            workShares.maxShareSupply
        ) {
            revert dWorkShare__InitialSaleClosed();
        }

        uint256 sentValueUsd = msg.value.getConversionRate(s_priceFeed);
        uint256 usdAmountDue = _shareAmount * workShares.sharePriceUsd;

        if (sentValueUsd < usdAmountDue) {
            revert dWorkShare__InsufficientFunds();
        }

        unchecked {
            ++workShares.totalShareBought;
            workShares.totalSellValueUsd += usdAmountDue;
        }

        _safeTransferFrom(
            workShares.workOwner,
            msg.sender,
            _sharesTokenId,
            _shareAmount,
            ""
        );

        emit ShareBought(_sharesTokenId, _shareAmount, msg.sender);
    }

    function setFactoryAddress(address _factoryAddress) external onlyOwner {
        s_workFactoryAddress = _factoryAddress;
    }

    function pauseShares() external {
        WorkShares storage workShares = _ensureOnlyWork();
        workShares.isPaused = true;
        emit SharesPaused(workShares, true);
    }

    function unpauseShares() external {
        WorkShares storage workShares = _ensureOnlyWork();
        workShares.isPaused = false;
        emit SharesPaused(workShares, false);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    ) public override whenSharesNotPaused(id) {
        super.safeTransferFrom(from, to, id, value, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public override whenSharesBatchNotPaused(ids) {
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    ////////////////////
    // Internal
    ////////////////////

    function _ensureTokenIdExists(
        uint256 _sharesTokenId
    ) internal view returns (WorkShares storage) {
        WorkShares storage workShares = s_workShares[_sharesTokenId];
        if (workShares.workContract == address(0)) {
            revert dWork__NotWorkContract();
        }
        return workShares;
    }

    function _ensureOnlyWorkFactory() internal view {
        if (msg.sender != s_workFactoryAddress) {
            revert dWork__NotFactoryContract();
        }
    }

    function _ensureOnlyWork() internal view returns (WorkShares storage) {
        uint256 shareTokenId = s_sharesTokenIds[msg.sender];
        if (shareTokenId == 0) {
            revert dWork__NotWorkContract();
        }
        return s_workShares[shareTokenId];
    }

    function _ensureSharesNotPaused(uint256 _sharesTokenId) internal view {
        WorkShares storage workShares = s_workShares[_sharesTokenId];
        if (workShares.isPaused) {
            revert dWork__SharesPaused();
        }
    }

    function _ensureSharesBatchNotPaused(
        uint256[] memory _sharesTokenIds
    ) internal view {
        for (uint256 i = 1; i < _sharesTokenIds.length; i++) {
            WorkShares storage workShares = s_workShares[_sharesTokenIds[i]];
            if (workShares.isPaused) {
                revert dWork__SharesPaused();
            }
        }
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function getWorkSharesByTokenId(
        uint256 _sharesTokenId
    ) external view returns (WorkShares memory) {
        return s_workShares[_sharesTokenId];
    }

    function getWorkSharesByWorkContract(
        address _workContract
    ) external view returns (WorkShares memory) {
        uint256 shareTokenId = s_sharesTokenIds[_workContract];
        return s_workShares[shareTokenId];
    }

    function getWorkSharesTokenId(
        address _workContract
    ) external view returns (uint256) {
        return s_sharesTokenIds[_workContract];
    }
}
