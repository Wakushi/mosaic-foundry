// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Chainlink
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
// OpenZeppelin
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// Custom
import {PriceConverter} from "./libraries/PriceConverter.sol";
import {IDWorkSharesManager} from "./interfaces/IDWorkSharesManager.sol";

contract dWorkSharesManager is
    ERC1155,
    IERC1155Receiver,
    Ownable,
    IAny2EVMMessageReceiver,
    ReentrancyGuard
{
    using PriceConverter for uint256;

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

    AggregatorV3Interface private s_nativePriceFeed;

    IRouterClient internal immutable i_ccipRouter;
    LinkTokenInterface internal immutable i_linkToken;
    address internal immutable i_usdc;
    uint64 private immutable i_currentChainSelector;
    mapping(uint64 destChainSelector => address xWorkAddress) s_chains;

    address s_dWork;
    uint256 s_shareTokenId;
    uint256 s_marketShareItemId;
    uint256[] s_listedShareItemsIds;

    mapping(uint256 sharesTokenId => IDWorkSharesManager.WorkShares workShares) s_workShares;
    mapping(uint256 workTokenId => uint256 sharesTokenId) s_sharesTokenIdByWorkId;
    mapping(uint256 marketShareItemId => MarketShareItem marketShareItem) s_marketShareItems;
    mapping(uint256 marketShareItemId => bool isListed) s_isItemListed;
    mapping(uint256 listedShareItem => uint256 index)
        public s_listedShareItemIndex;
    mapping(uint256 shareTokenId => uint256 totalRedeemableValue) s_totalRedeemableValuePerWork;

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
    event SharesPaused(
        IDWorkSharesManager.WorkShares workShares,
        bool isPaused
    );
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
    error dWorkSharesManager__ShareNotRedeemable();
    error dWorkSharesManager__SharesNotOwned();
    error dWorkSharesManager__TransferFailedOnRedeem();
    error dWorkSharesManager__RedeemableValueExceeded();
    error dWorkSharesManager__SellValueError();
    error dWorkSharesManager__InvalidRouter();
    error dWorkSharesManager__ChainNotEnabled();
    error dWorkSharesManager__SenderNotEnabled();
    error dWorkSharesManager__NotEnoughBalanceForFees();
    error dWorkSharesManager__TransferFailed();

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

    modifier onlyRouter() {
        if (msg.sender != address(i_ccipRouter)) {
            revert dWorkSharesManager__InvalidRouter();
        }
        _;
    }

    modifier onlyEnabledChain(uint64 _chainSelector) {
        if (s_chains[_chainSelector] == address(0)) {
            revert dWorkSharesManager__ChainNotEnabled();
        }
        _;
    }

    modifier onlyEnabledSender(uint64 _chainSelector, address _sender) {
        if (s_chains[_chainSelector] != _sender) {
            revert dWorkSharesManager__SenderNotEnabled();
        }
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor(
        string memory _baseUri,
        address _priceFeed,
        address _ccipRouterAddress,
        address _linkTokenAddress,
        uint64 _currentChainSelector,
        address _usdc
    ) ERC1155(_baseUri) Ownable(msg.sender) {
        s_nativePriceFeed = AggregatorV3Interface(_priceFeed);
        i_ccipRouter = IRouterClient(_ccipRouterAddress);
        i_linkToken = LinkTokenInterface(_linkTokenAddress);
        i_currentChainSelector = _currentChainSelector;
        i_usdc = _usdc;
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
     *
     * @param _workTokenId Token id of the tokenized work on dWork.sol
     * @param _workOwner Owner of the work token
     * @param _shareSupply Total supply of the created shares
     * @param _sharePriceUsd Price of each share in USD
     * @dev Creates shares for a work that was tokenized on dWork.sol
     */
    function createShares(
        uint256 _workTokenId,
        address _workOwner,
        uint256 _shareSupply,
        uint256 _sharePriceUsd
    ) external onlyDWork returns (uint256) {
        unchecked {
            ++s_shareTokenId;
        }

        _mint(_workOwner, s_shareTokenId, _shareSupply, "");

        s_workShares[s_shareTokenId] = IDWorkSharesManager.WorkShares({
            maxShareSupply: _shareSupply,
            sharePriceUsd: _sharePriceUsd,
            workTokenId: _workTokenId,
            totalShareBought: 0,
            totalSellValueUsd: 0,
            workOwner: _workOwner,
            isPaused: false,
            isRedeemable: false,
            redeemableValuePerShare: 0
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

    /**
     * @param _sharesTokenId The token id of the share related to the work token that was fractionalized on dWork.sol
     * @param _shareAmount Amount of shares to buy
     * @dev Allows users to buy shares of a work that was tokenized and fractionalized on dWork.sol
     */
    function buyInitialShare(
        uint256 _sharesTokenId,
        uint256 _shareAmount
    ) external payable whenSharesNotPaused(_sharesTokenId) nonReentrant {
        if (_sharesTokenId == 0) {
            revert dWorkSharesManager__TokenIdDoesNotExist();
        }

        IDWorkSharesManager.WorkShares storage workShares = s_workShares[
            _sharesTokenId
        ];

        if (
            workShares.totalShareBought + _shareAmount >
            workShares.maxShareSupply
        ) {
            revert dWorkSharesManager__InitialSaleClosed();
        }

        uint256 sentValueUsd = msg.value.getConversionRate(s_nativePriceFeed);
        uint256 usdAmountDue = _shareAmount * workShares.sharePriceUsd;

        if (sentValueUsd < usdAmountDue) {
            revert dWorkSharesManager__InsufficientFunds();
        }

        unchecked {
            workShares.totalShareBought += _shareAmount;
            workShares.totalSellValueUsd += usdAmountDue;
        }

        (bool success, ) = payable(workShares.workOwner).call{value: msg.value}(
            ""
        );

        if (!success) {
            revert dWorkSharesManager__TransferFailed();
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

    /**
     * @param _sharesTokenId The token id of the share related to the work token that was fractionalized on dWork.sol
     * @param _amount Amount of shares to list
     * @param _priceUsd Price of the share in USD
     * @dev Allows users to list shares of a work that was tokenized and fractionalized on dWork.sol
     */
    function listMarketShareItem(
        uint256 _sharesTokenId,
        uint256 _amount,
        uint256 _priceUsd
    )
        external
        whenSharesNotPaused(_sharesTokenId)
        returns (uint256 marketShareItemId)
    {
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

        return s_marketShareItemId;
    }

    /**
     * @param _marketShareItemId The id of the market share item to buy
     * @dev Allows users to buy a listed share item
     */
    function buyMarketShareItem(
        uint256 _marketShareItemId
    ) external payable nonReentrant {
        if (!s_isItemListed[_marketShareItemId]) {
            revert dWorkSharesManager__ItemNotListed();
        }

        MarketShareItem storage marketShareItem = s_marketShareItems[
            _marketShareItemId
        ];

        if (marketShareItem.isSold) {
            revert dWorkSharesManager__ItemAlreadySold();
        }

        uint256 sentValueUsd = msg.value.getConversionRate(s_nativePriceFeed);

        if (sentValueUsd < marketShareItem.priceUsd) {
            revert dWorkSharesManager__InsufficientFunds();
        }

        (bool success, ) = payable(marketShareItem.seller).call{
            value: msg.value
        }("");

        if (!success) {
            revert dWorkSharesManager__TransferFailed();
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

    /**
     * @param _marketShareItemId The id of the market share item to unlist
     * @dev Allows users to unlist a listed share item
     */
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

        _safeTransferFrom(
            address(this),
            msg.sender,
            marketShareItem.sharesTokenId,
            1,
            ""
        );

        _unlistItem(_marketShareItemId);

        emit MarketShareItemUnlisted(_marketShareItemId);
    }

    /**
     * @param _sharesTokenId The token id of the share related to the work token that was sold on dWork.sol
     * @dev Called by dWork contract when a work is sold. Its job is to set the work shares as redeemable
     * and set the redeemable value per share so they can be redeemed and burn by the share holders.
     */
    function onWorkSold(
        uint256 _sharesTokenId,
        uint256 _sellValueUSDC
    ) external onlyDWork {
        _onWorkSold(_sharesTokenId, _sellValueUSDC);
    }

    /**
     * @param _shareTokenId The token id of the share related to the work token that was sold on dWork.sol
     * @param _shareAmount Amount of shares to redeem
     * @dev Allows users to burn and redeem their shares for the value they are worth in USDC
     */
    function redeemAndBurnSharesForUSDC(
        uint256 _shareTokenId,
        uint256 _shareAmount
    ) external {
        if (balanceOf(msg.sender, _shareTokenId) < _shareAmount) {
            revert dWorkSharesManager__SharesNotOwned();
        }

        IDWorkSharesManager.WorkShares
            memory workShare = getWorkSharesByTokenId(_shareTokenId);

        if (!workShare.isRedeemable) {
            revert dWorkSharesManager__ShareNotRedeemable();
        }

        uint256 redeemableValue = workShare.redeemableValuePerShare *
            _shareAmount;
        _ensureEnoughValueToRedeem(_shareTokenId, redeemableValue);
        s_totalRedeemableValuePerWork[_shareTokenId] -= redeemableValue;
        _burn(msg.sender, _shareTokenId, _shareAmount);

        bool success = IERC20(i_usdc).transferFrom(
            address(this),
            msg.sender,
            redeemableValue
        );

        if (!success) {
            revert dWorkSharesManager__TransferFailedOnRedeem();
        }
    }

    function ccipReceive(
        Client.Any2EVMMessage calldata message
    )
        external
        virtual
        override
        onlyRouter
        nonReentrant
        onlyEnabledChain(message.sourceChainSelector)
        onlyEnabledSender(
            message.sourceChainSelector,
            abi.decode(message.sender, (address))
        )
    {
        (uint256 sharesTokenId, uint256 sellValue) = abi.decode(
            message.data,
            (uint256, uint256)
        );

        _onWorkSold(sharesTokenId, sellValue);
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

    /**
     * @param _workTokenId The token id of the work that was fractionalized on dWork.sol
     * @dev Pauses the shares of a work that was fractionalized on dWork.sol (triggered by dWork.sol when discrepancies are found during the work verification process)
     */
    function pauseShares(uint256 _workTokenId) external onlyDWork {
        uint256 sharesTokenId = s_sharesTokenIdByWorkId[_workTokenId];
        IDWorkSharesManager.WorkShares storage workShares = s_workShares[
            sharesTokenId
        ];
        workShares.isPaused = true;
        emit SharesPaused(workShares, true);
    }

    /**
     * @param _workTokenId The token id of the work that was fractionalized on dWork.sol
     * @dev Unpauses the shares of a work that was fractionalized on dWork.sol
     */
    function unpauseShares(uint256 _workTokenId) external onlyDWork {
        uint256 sharesTokenId = s_sharesTokenIdByWorkId[_workTokenId];
        IDWorkSharesManager.WorkShares storage workShares = s_workShares[
            sharesTokenId
        ];
        workShares.isPaused = false;
        emit SharesPaused(workShares, false);
    }

    function setDWorkAddress(address _dWork) external onlyOwner {
        s_dWork = _dWork;
    }

    function enableChain(
        uint64 _chainSelector,
        address _xWorkAddress
    ) external onlyOwner {
        s_chains[_chainSelector] = _xWorkAddress;
    }

    ////////////////////
    // Internal
    ////////////////////

    function _onWorkSold(
        uint256 _sharesTokenId,
        uint256 _sellValueUSDC
    ) internal {
        IDWorkSharesManager.WorkShares storage workShares = s_workShares[
            _sharesTokenId
        ];

        if (
            _sellValueUSDC == 0 ||
            workShares.maxShareSupply == 0 ||
            _sellValueUSDC < workShares.maxShareSupply
        ) {
            revert dWorkSharesManager__SellValueError();
        }

        workShares.isRedeemable = true;
        workShares.redeemableValuePerShare =
            _sellValueUSDC /
            workShares.maxShareSupply;

        s_totalRedeemableValuePerWork[_sharesTokenId] = _sellValueUSDC;
    }

    function _ensureOnlydWork() internal view {
        if (msg.sender != s_dWork) {
            revert dWorkSharesManager__NotWorkContract();
        }
    }

    function _ensureSharesNotPaused(uint256 _sharesTokenId) internal view {
        IDWorkSharesManager.WorkShares storage workShares = s_workShares[
            _sharesTokenId
        ];
        if (workShares.isPaused) {
            revert dWorkSharesManager__SharesPaused();
        }
    }

    function _ensureSharesBatchNotPaused(
        uint256[] memory _sharesTokenIds
    ) internal view {
        for (uint256 i = 1; i < _sharesTokenIds.length; i++) {
            IDWorkSharesManager.WorkShares storage workShares = s_workShares[
                _sharesTokenIds[i]
            ];
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

    function _ensureEnoughValueToRedeem(
        uint256 _shareTokenId,
        uint256 _redeemableValue
    ) internal view {
        uint256 totalRedeemableValue = s_totalRedeemableValuePerWork[
            _shareTokenId
        ];
        if (totalRedeemableValue < _redeemableValue) {
            revert dWorkSharesManager__RedeemableValueExceeded();
        }
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
    ) public view returns (uint256 sharesTokenId) {
        return s_sharesTokenIdByWorkId[_workTokenId];
    }

    function getWorkSharesByTokenId(
        uint256 _sharesTokenId
    ) public view returns (IDWorkSharesManager.WorkShares memory) {
        return s_workShares[_sharesTokenId];
    }

    function getWorkShareByWorkTokenId(
        uint256 _workTokenId
    ) external view returns (IDWorkSharesManager.WorkShares memory) {
        uint256 sharesTokenId = getSharesTokenIdByWorkId(_workTokenId);
        return getWorkSharesByTokenId(sharesTokenId);
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
        (, int256 answer, , , ) = s_nativePriceFeed.latestRoundData();
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

    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
