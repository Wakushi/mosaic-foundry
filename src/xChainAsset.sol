// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Chainlink
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// OpenZeppelin
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// Custom
import {TokenizedAsset} from "./TokenizedAsset.sol";
import {IDWorkConfig} from "./interfaces/IDWorkConfig.sol";

contract xChainAsset is
    TokenizedAsset,
    IAny2EVMMessageReceiver,
    ReentrancyGuard
{
    ///////////////////
    // State variables
    ///////////////////

    // Chainlink CCIP
    uint256 constant POLYGON_AMOY_CHAIN_ID = 80002;
    uint64 constant POLYGON_AMOY_CHAIN_SELECTOR = 16281711391670634445;
    uint256 constant OPTIMISM_SEPOLIA_CHAIN_ID = 11155420;
    uint64 constant OPTIMISM_SEPOLIA_CHAIN_SELECTOR = 5224473277236331295;

    IRouterClient internal immutable i_ccipRouter;
    LinkTokenInterface internal immutable i_linkToken;
    uint64 private immutable i_currentChainSelector;
    address immutable i_usdc;

    mapping(uint64 destChainSelector => address xWorkAddress) s_chains;
    mapping(uint256 chainId => uint64 chainSelector) s_chainSelectors;
    mapping(uint64 destChainSelector => address xWorkSharesManagerAddress) s_sharesManagers;

    ///////////////////
    // Events
    ///////////////////

    event CrossChainSent(
        address to,
        uint256 tokenId,
        uint64 sourceChainSelector,
        uint64 destinationChainSelector
    );
    event CrossChainReceived(
        address to,
        uint256 tokenId,
        uint64 sourceChainSelector,
        uint64 destinationChainSelector
    );

    //////////////////
    // Errors
    //////////////////

    error dWork__InvalidRouter();
    error dWork__ChainNotEnabled();
    error dWork__SenderNotEnabled();
    error dWork__NotEnoughBalanceForFees();
    error dWork__OnlyOnPolygonAmoy();

    //////////////////
    // Modifiers
    //////////////////

    modifier onlyRouter() {
        if (msg.sender != address(i_ccipRouter)) {
            revert dWork__InvalidRouter();
        }
        _;
    }

    modifier onlyEnabledChain(uint64 _chainSelector) {
        if (s_chains[_chainSelector] == address(0)) {
            revert dWork__ChainNotEnabled();
        }
        _;
    }

    modifier onlyEnabledSender(uint64 _chainSelector, address _sender) {
        if (s_chains[_chainSelector] != _sender) {
            revert dWork__SenderNotEnabled();
        }
        _;
    }

    modifier onlyOnPolygonAmoy() {
        if (block.chainid != POLYGON_AMOY_CHAIN_ID) {
            revert dWork__OnlyOnPolygonAmoy();
        }
        _;
    }

    //////////////////
    // Functions
    //////////////////

    constructor(
        address _ccipRouterAddress,
        address _linkTokenAddress,
        uint64 _currentChainSelector,
        address _usdc
    ) {
        if (_ccipRouterAddress == address(0)) revert dWork__InvalidRouter();
        i_ccipRouter = IRouterClient(_ccipRouterAddress);
        i_linkToken = LinkTokenInterface(_linkTokenAddress);
        i_currentChainSelector = _currentChainSelector;
        i_usdc = _usdc;
        s_chainSelectors[POLYGON_AMOY_CHAIN_ID] = POLYGON_AMOY_CHAIN_SELECTOR;
        s_chainSelectors[
            OPTIMISM_SEPOLIA_CHAIN_ID
        ] = OPTIMISM_SEPOLIA_CHAIN_SELECTOR;
    }

    ////////////////////
    // External / Public
    ////////////////////

    function xChainWorkTokenTransfer(
        address _to,
        uint256 _tokenizationRequestId,
        uint64 _destinationChainSelector,
        IDWorkConfig.PayFeesIn _payFeesIn,
        uint256 _gasLimit
    )
        public
        nonReentrant
        onlyEnabledChain(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        TokenizedWork storage tokenizedWork = s_tokenizationRequests[
            _tokenizationRequestId
        ];

        if (msg.sender != tokenizedWork.owner) {
            revert dWork__NotWorkOwner();
        }

        _burn(tokenizedWork.workTokenId);

        tokenizedWork.owner = _to;

        IDWorkConfig.xChainWorkTokenTransferData memory data = IDWorkConfig
            .xChainWorkTokenTransferData({
                to: _to,
                workTokenId: tokenizedWork.workTokenId,
                ownerName: tokenizedWork.ownerName,
                lastWorkPriceUsd: tokenizedWork.lastWorkPriceUsd,
                artist: tokenizedWork.certificate.artist,
                work: tokenizedWork.certificate.work,
                sharesTokenId: tokenizedWork.sharesTokenId,
                tokenizationRequestId: _tokenizationRequestId
            });

        bytes memory encodedArgs = _encodeArgs(data);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(s_chains[_destinationChainSelector]),
            data: encodedArgs,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: _gasLimit})
            ),
            feeToken: _payFeesIn == IDWorkConfig.PayFeesIn.LINK
                ? address(i_linkToken)
                : address(0)
        });

        uint256 fees = i_ccipRouter.getFee(_destinationChainSelector, message);

        if (_payFeesIn == IDWorkConfig.PayFeesIn.LINK) {
            if (fees > i_linkToken.balanceOf(address(this))) {
                revert dWork__NotEnoughBalanceForFees();
            }

            i_linkToken.approve(address(i_ccipRouter), fees);

            messageId = i_ccipRouter.ccipSend(
                _destinationChainSelector,
                message
            );
        } else {
            if (fees > address(this).balance) {
                revert dWork__NotEnoughBalanceForFees();
            }

            messageId = i_ccipRouter.ccipSend{value: fees}(
                _destinationChainSelector,
                message
            );
        }

        emit CrossChainSent(
            _to,
            tokenizedWork.workTokenId,
            i_currentChainSelector,
            _destinationChainSelector
        );
    }

    function _xChainOnWorkSold(
        uint256 _sharesTokenId,
        uint256 _sellValue,
        uint256 _mintedChainId
    ) internal returns (bytes32 messageId) {
        uint64 destinationChainSelector = s_chainSelectors[_mintedChainId];

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: i_usdc,
            amount: _sellValue
        });
        tokenAmounts[0] = tokenAmount;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(s_sharesManagers[destinationChainSelector]),
            data: abi.encode(_sharesTokenId, _sellValue),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300000})
            ),
            feeToken: address(i_linkToken)
        });

        uint256 fees = i_ccipRouter.getFee(destinationChainSelector, message);

        if (fees > i_linkToken.balanceOf(address(this))) {
            revert dWork__NotEnoughBalanceForFees();
        }

        i_linkToken.approve(address(i_ccipRouter), fees);

        IERC20(i_usdc).approve(address(i_ccipRouter), _sellValue);

        messageId = i_ccipRouter.ccipSend{value: fees}(
            destinationChainSelector,
            message
        );
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
        uint64 sourceChainSelector = message.sourceChainSelector;
        IDWorkConfig.xChainWorkTokenTransferData memory data = _decodeWhole(
            message.data
        );
        _safeMint(data.to, data.workTokenId);
        _createTokenizedWork(data);

        emit CrossChainReceived(
            data.to,
            data.workTokenId,
            sourceChainSelector,
            i_currentChainSelector
        );
    }

    ////////////////////
    // Internal
    ////////////////////

    function _enableChain(
        uint64 _chainSelector,
        address _xWorkAddress
    ) internal {
        s_chains[_chainSelector] = _xWorkAddress;
    }

    function _setChainSharesManager(
        uint64 _chainSelector,
        address _sharesManagerAddress
    ) internal {
        s_sharesManagers[_chainSelector] = _sharesManagerAddress;
    }

    function _encodeArgs(
        IDWorkConfig.xChainWorkTokenTransferData memory _encodeTokenTransferData
    ) internal pure returns (bytes memory) {
        bytes memory encodedArgs = abi.encode(
            _encodeTokenTransferData.to,
            _encodeTokenTransferData.workTokenId
        );
        return encodedArgs;
    }

    function _decodeWhole(
        bytes memory encodedPackage
    ) internal pure returns (IDWorkConfig.xChainWorkTokenTransferData memory) {
        (
            address to,
            uint256 workTokenId,
            string memory ownerName,
            uint256 lastWorkPriceUsd,
            string memory artist,
            string memory work,
            uint256 sharesTokenId,
            uint256 tokenizationRequestId
        ) = abi.decode(
                encodedPackage,
                (
                    address,
                    uint256,
                    string,
                    uint256,
                    string,
                    string,
                    uint256,
                    uint256
                )
            );

        return
            IDWorkConfig.xChainWorkTokenTransferData({
                to: to,
                workTokenId: workTokenId,
                ownerName: ownerName,
                lastWorkPriceUsd: lastWorkPriceUsd,
                artist: artist,
                work: work,
                sharesTokenId: sharesTokenId,
                tokenizationRequestId: tokenizationRequestId
            });
    }
}
