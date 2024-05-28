// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWork} from "../src/dWork.sol";

contract DeployDWork is Script {
    address WORK_VERIFIER_CONTRACT = 0x65a03bb314220C6be26AA273C951bf06739f619a;
    address WORK_SHARES_MANAGER = 0x7AdA800898fB8ff735f39d8C2D497AD8894460aF;

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
