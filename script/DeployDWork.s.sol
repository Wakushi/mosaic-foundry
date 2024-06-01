// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWork} from "../src/dWork.sol";

contract DeployDWork is Script {
    address WORK_VERIFIER_CONTRACT = 0xa81bcb1DCbe2956E2e332ea83BC661Eb045A95bd;
    address WORK_SHARES_MANAGER = 0xc75d7685EB02216B1D273337D31be185A4A48a24;

    function run() external returns (dWork) {
        HelperConfig helperConfig = new HelperConfig();
        (
            ,
            ,
            ,
            ,
            address ccipRouterAddress,
            address linkTokenAddress,
            ,
            address usdcAddress,
            address usdcPriceFeed
        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast();
        dWork newDWork = new dWork(
            WORK_SHARES_MANAGER,
            WORK_VERIFIER_CONTRACT,
            usdcPriceFeed,
            ccipRouterAddress,
            linkTokenAddress,
            usdcAddress
        );
        vm.stopBroadcast();
        return newDWork;
    }
}
