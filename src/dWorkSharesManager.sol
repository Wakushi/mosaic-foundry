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

    struct MarketShareItem {
        uint256 itemId;
        uint256 sharesTokenId;
        uint256 priceUsd;
        address seller;
        bool isSold;
    }

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink Data Feed
    AggregatorV3Interface private s_priceFeed;

    address s_dWork;
    uint256 s_shareTokenId;
    uint256 s_marketShareItemId;
    uint256[] s_listedShareItemsIds;
    mapping(uint256 sharesTokenId => WorkShares workShares) s_workShares;
    mapping(uint256 workTokenId => uint256 sharesTokenId) s_sharesTokenIdByWorkId;
    mapping(uint256 marketShareItemId => MarketShareItem marketShareItem) s_marketShareItems;
    mapping(uint256 marketShareItemId => bool isListed) s_isItemListed;
    mapping(uint256 listedShareItem => uint256 index)
        public s_listedShareItemIndex;

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
    event MarketShareItemListed(
        uint256 marketShareItemId,
        uint256 sharesTokenId,
        uint256 amount,
        uint256 priceUsd,
        address seller
    );
    event MarketShareItemSold(
        uint256 marketShareItemId,
        uint256 sharesTokenId,
        uint256 amount,
        uint256 priceUsd,
        address buyer
    );
    event MarketShareItemUnlisted(uint256 marketShareItemId);

    //////////////////
    // Errors
    ///////////////////

    error dWorkSharesManager__InsufficientFunds();
    error dWorkSharesManager__InitialSaleClosed();
    error dWorkSharesManager__NotWorkContract();
    error dWorkSharesManager__SharesPaused();
    error dWorkSharesManager__TokenIdDoesNotExist();
    error dWorkSharesManager__ItemNotListed();
    error dWorkSharesManager__NotItemSeller();
    error dWorkSharesManager__ItemAlreadySold();

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
            ++s_shareTokenId;
        }

        _mint(_workOwner, s_shareTokenId, _shareSupply, "");

        s_workShares[s_shareTokenId] = WorkShares({
            maxShareSupply: _shareSupply,
            sharePriceUsd: _sharePriceUsd,
            workTokenId: _workTokenId,
            totalShareBought: 0,
            totalSellValueUsd: 0,
            workOwner: _workOwner,
            isPaused: false
        });

        s_sharesTokenIdByWorkId[_workTokenId] = s_shareTokenId;

        emit SharesCreated(
            s_shareTokenId,
            _shareSupply,
            _workTokenId,
            _workOwner
        );

        return s_shareTokenId;
    }

    function buyInitialShare(
        uint256 _sharesTokenId,
        uint256 _shareAmount
    ) external payable whenSharesNotPaused(_sharesTokenId) {
        if (_sharesTokenId == 0) {
            revert dWorkSharesManager__TokenIdDoesNotExist();
        }

        WorkShares storage workShares = s_workShares[_sharesTokenId];

        if (
            workShares.totalShareBought + _shareAmount >
            workShares.maxShareSupply
        ) {
            revert dWorkSharesManager__InitialSaleClosed();
        }

        uint256 sentValueUsd = msg.value.getConversionRate(s_priceFeed);
        uint256 usdAmountDue = _shareAmount * workShares.sharePriceUsd;

        if (sentValueUsd < usdAmountDue) {
            revert dWorkSharesManager__InsufficientFunds();
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

    function listMarketShareItem(
        uint256 _sharesTokenId,
        uint256 _amount,
        uint256 _priceUsd
    ) external whenSharesNotPaused(_sharesTokenId) {
        if (_sharesTokenId == 0) {
            revert dWorkSharesManager__TokenIdDoesNotExist();
        }

        safeTransferFrom(
            msg.sender,
            address(this),
            _sharesTokenId,
            _amount,
            ""
        );

        unchecked {
            ++s_marketShareItemId;
        }

        s_marketShareItems[s_marketShareItemId] = MarketShareItem({
            itemId: s_marketShareItemId,
            sharesTokenId: _sharesTokenId,
            priceUsd: _priceUsd,
            seller: msg.sender,
            isSold: false
        });

        s_isItemListed[s_marketShareItemId] = true;

        s_listedShareItemsIds.push(s_marketShareItemId);
        s_listedShareItemIndex[s_marketShareItemId] =
            s_listedShareItemsIds.length -
            1;

        emit MarketShareItemListed(
            s_marketShareItemId,
            _sharesTokenId,
            _amount,
            _priceUsd,
            msg.sender
        );
    }

    function buyMarketShareItem(uint256 _marketShareItemId) external payable {
        if (!s_isItemListed[_marketShareItemId]) {
            revert dWorkSharesManager__ItemNotListed();
        }

        MarketShareItem storage marketShareItem = s_marketShareItems[
            _marketShareItemId
        ];

        if (marketShareItem.isSold) {
            revert dWorkSharesManager__ItemAlreadySold();
        }

        uint256 sentValueUsd = msg.value.getConversionRate(s_priceFeed);

        if (sentValueUsd < marketShareItem.priceUsd) {
            revert dWorkSharesManager__InsufficientFunds();
        }

        _safeTransferFrom(
            address(this),
            msg.sender,
            marketShareItem.sharesTokenId,
            1,
            ""
        );

        marketShareItem.isSold = true;

        _unlistItem(_marketShareItemId);

        emit MarketShareItemSold(
            _marketShareItemId,
            marketShareItem.sharesTokenId,
            1,
            marketShareItem.priceUsd,
            msg.sender
        );
    }

    function unlistMarketShareItem(uint256 _marketShareItemId) external {
        if (!s_isItemListed[_marketShareItemId]) {
            revert dWorkSharesManager__ItemNotListed();
        }

        MarketShareItem storage marketShareItem = s_marketShareItems[
            _marketShareItemId
        ];

        if (marketShareItem.seller != msg.sender) {
            revert dWorkSharesManager__NotItemSeller();
        }

        s_isItemListed[_marketShareItemId] = false;

        _unlistItem(_marketShareItemId);

        emit MarketShareItemUnlisted(_marketShareItemId);
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
            revert dWorkSharesManager__NotWorkContract();
        }
    }

    function _ensureSharesNotPaused(uint256 _sharesTokenId) internal view {
        WorkShares storage workShares = s_workShares[_sharesTokenId];
        if (workShares.isPaused) {
            revert dWorkSharesManager__SharesPaused();
        }
    }

    function _ensureSharesBatchNotPaused(
        uint256[] memory _sharesTokenIds
    ) internal view {
        for (uint256 i = 1; i < _sharesTokenIds.length; i++) {
            WorkShares storage workShares = s_workShares[_sharesTokenIds[i]];
            if (workShares.isPaused) {
                revert dWorkSharesManager__SharesPaused();
            }
        }
    }

    function _unlistItem(uint256 _marketShareItemId) internal {
        uint256 index = s_listedShareItemIndex[_marketShareItemId];
        uint256 lastItemId = s_listedShareItemsIds[
            s_listedShareItemsIds.length - 1
        ];

        s_listedShareItemsIds[index] = lastItemId;
        s_listedShareItemIndex[lastItemId] = index;

        s_listedShareItemsIds.pop();
        delete s_listedShareItemIndex[_marketShareItemId];
    }

    ////////////////////
    // External / Public View
    ////////////////////

    function getDWorkAddress() external view returns (address) {
        return s_dWork;
    }

    function getLastTokenId() external view returns (uint256) {
        return s_shareTokenId;
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

    function getLastMarketShareItemId() external view returns (uint256) {
        return s_marketShareItemId;
    }

    function getMarketShareItemById(
        uint256 _marketShareItemId
    ) external view returns (MarketShareItem memory) {
        return s_marketShareItems[_marketShareItemId];
    }

    function getMarketShareItemIndex(
        uint256 _marketShareItemId
    ) external view returns (uint256) {
        return s_listedShareItemIndex[_marketShareItemId];
    }

    function getNativeTokenPriceUsd() external view returns (uint256) {
        (, int256 answer, , , ) = s_priceFeed.latestRoundData();
        return uint256(answer * 10000000000);
    }

    function getListedItems() external view returns (MarketShareItem[] memory) {
        uint256 listedCount = s_listedShareItemsIds.length;
        MarketShareItem[] memory items = new MarketShareItem[](listedCount);

        for (uint256 i = 0; i < listedCount; i++) {
            items[i] = s_marketShareItems[s_listedShareItemsIds[i]];
        }

        return items;
    }
}
