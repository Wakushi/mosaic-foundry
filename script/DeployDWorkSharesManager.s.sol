// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkSharesManager} from "../src/dWorkSharesManager.sol";

contract DeployDWorkSharesManager is Script {
    string constant BASE_URI =
        "https://peach-genuine-lamprey-766.mypinata.cloud/ipfs/";

    function run() external returns (dWorkSharesManager) {
        HelperConfig helperConfig = new HelperConfig();
        (
            ,
            ,
            address nativeUsdPriceFeed,
            ,
            address ccipRouterAddress,
            address linkTokenAddress,
            uint64 chainSelector,
            address usdcAddress,

        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast();
        dWorkSharesManager newDWorkShare = new dWorkSharesManager(
            BASE_URI,
            nativeUsdPriceFeed,
            ccipRouterAddress,
            linkTokenAddress,
            chainSelector,
            usdcAddress
        );
        vm.stopBroadcast();

        return newDWorkShare;
    }
}
