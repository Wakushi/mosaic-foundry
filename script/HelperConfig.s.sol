// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {LinkToken} from "../test/mocks/LinkToken.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";
import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        bytes32 donId;
        address functionsRouter;
        address nativeUsdPriceFeed;
        uint64 functionsSubId;
        address ccipRouterAddress;
        address linkTokenAddress;
        uint64 chainSelector;
        address usdcAddress;
        address usdcPriceFeed;
    }

    uint256 public constant DEFAULT_ANVIL_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000e8;
    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 80002) {
            activeNetworkConfig = getPolygonAmoyConfig();
        } else if (block.chainid == 11155420) {
            activeNetworkConfig = getOptimismSepoliaConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getPolygonAmoyConfig() public pure returns (NetworkConfig memory) {
        return
            NetworkConfig({
                donId: bytes32("fun-polygon-amoy-1"),
                functionsRouter: 0xC22a79eBA640940ABB6dF0f7982cc119578E11De,
                nativeUsdPriceFeed: 0x001382149eBa3441043c1c66972b4772963f5D43,
                usdcPriceFeed: 0x1b8739bB4CdF0089d07097A9Ae5Bd274b29C6F16,
                functionsSubId: 279,
                ccipRouterAddress: 0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2,
                linkTokenAddress: 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904,
                chainSelector: 16281711391670634445,
                usdcAddress: 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582
            });
    }

    function getOptimismSepoliaConfig()
        public
        pure
        returns (NetworkConfig memory)
    {
        return
            NetworkConfig({
                donId: bytes32("fun-optimism-sepolia-1"),
                functionsRouter: 0xC17094E3A1348E5C7544D4fF8A36c28f2C6AAE28,
                nativeUsdPriceFeed: 0x61Ec26aA57019C486B10502285c5A3D4A4750AD7,
                usdcPriceFeed: 0x6e44e50E3cc14DD16e01C590DC1d7020cb36eD4C,
                functionsSubId: 192,
                ccipRouterAddress: 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57,
                linkTokenAddress: 0xE4aB69C077896252FAFBD49EFD26B5D171A32410,
                chainSelector: 5224473277236331295,
                usdcAddress: 0x5fd84259d66Cd46123540766Be93DFE6D43130D7
            });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.functionsRouter != address(0)) {
            return activeNetworkConfig;
        }

        // uint96 baseFee = 0.25 ether; // 0.25 LINK
        // uint96 gasPriceLink = 1e9; // 1 gwei LINK

        vm.startBroadcast();
        // VRFCoordinatorV2Mock vrfCoordinatorMock = new VRFCoordinatorV2Mock(
        //     baseFee,
        //     gasPriceLink
        // );
        LinkToken link = new LinkToken();
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(
            DECIMALS,
            INITIAL_PRICE
        );
        vm.stopBroadcast();

        return
            NetworkConfig({
                donId: bytes32("fun-ethereum-sepolia-1"),
                functionsRouter: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
                nativeUsdPriceFeed: address(mockPriceFeed),
                usdcPriceFeed: address(mockPriceFeed),
                functionsSubId: 0,
                ccipRouterAddress: 0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2,
                linkTokenAddress: address(link),
                chainSelector: 0,
                usdcAddress: 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582
            });
    }
}
