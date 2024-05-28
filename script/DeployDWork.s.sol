// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWork} from "../src/dWork.sol";

contract DeployDWork is Script {
    address WORK_VERIFIER_CONTRACT = 0x240b46926a2410A9A235667CB801a1155c77B718;
    address WORK_SHARES_MANAGER = 0x076cA48Bf22085863F3be55a899ca2e4aBA6266A;

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
