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
        uint256 workTokenId;
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
    address s_dWork;
    uint256 s_tokenId;

    mapping(uint256 sharesTokenId => WorkShares workShares) s_workShares;
    mapping(uint256 workTokenId => uint256 sharesTokenId) s_sharesTokenIdByWorkId;

    ///////////////////
    // Events
    ///////////////////

    event SharesCreated(
        uint256 sharesTokenId,
        uint256 maxShareSupply,
        uint256 workTokenId,
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
    error dWork__SharesPaused();
    error dWork__TokenIdDoesNotExist();

    //////////////////
    // Modifiers
    //////////////////

    modifier onlyDWork() {
        _ensureOnlydWork();
        _;
    }

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
        uint256 _workTokenId,
        address _workOwner,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external returns (uint256) {
        _ensureOnlydWork();

        unchecked {
            ++s_tokenId;
        }

        _mint(_workOwner, s_tokenId, _shareSupply, "");

        s_workShares[s_tokenId] = WorkShares({
            maxShareSupply: _shareSupply,
            sharePriceUsd: _sharePriceUsd,
            workTokenId: _workTokenId,
            totalShareBought: 0,
            totalSellValueUsd: 0,
            workOwner: _workOwner,
            isPaused: false
        });

        s_sharesTokenIdByWorkId[_workTokenId] = s_tokenId;

        emit SharesCreated(s_tokenId, _shareSupply, _workTokenId, _workOwner);

        return s_tokenId;
    }

    function buyInitialShare(
        uint256 _sharesTokenId,
        uint256 _shareAmount
    ) external payable whenSharesNotPaused(_sharesTokenId) {
        if (_sharesTokenId == 0) {
            revert dWork__TokenIdDoesNotExist();
        }

        WorkShares storage workShares = s_workShares[_sharesTokenId];

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

    function setDWorkAddress(address _dWork) external onlyOwner {
        s_dWork = _dWork;
    }

    function pauseShares(uint256 _workTokenId) external onlyDWork {
        uint256 sharesTokenId = s_sharesTokenIdByWorkId[_workTokenId];
        WorkShares storage workShares = s_workShares[sharesTokenId];
        workShares.isPaused = true;
        emit SharesPaused(workShares, true);
    }

    function unpauseShares(uint256 _workTokenId) external onlyDWork {
        uint256 sharesTokenId = s_sharesTokenIdByWorkId[_workTokenId];
        WorkShares storage workShares = s_workShares[sharesTokenId];
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

    function _ensureOnlydWork() internal view {
        if (msg.sender != s_dWork) {
            revert dWork__NotWorkContract();
        }
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

    function getDWorkAddress() external view returns (address) {
        return s_dWork;
    }

    function getLastTokenId() external view returns (uint256) {
        return s_tokenId;
    }

    function getSharesTokenIdByWorkId(
        uint256 _workTokenId
    ) external view returns (uint256) {
        return s_sharesTokenIdByWorkId[_workTokenId];
    }

    function getWorkSharesByTokenId(
        uint256 _sharesTokenId
    ) external view returns (WorkShares memory) {
        return s_workShares[_sharesTokenId];
    }

    function getNativeTokenPriceUsd() external view returns (uint256) {
        (, int256 answer, , , ) = s_priceFeed.latestRoundData();
        return uint256(answer * 10000000000);
    }
}
