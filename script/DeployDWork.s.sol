// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWork} from "../src/dWork.sol";

contract DeployDWork is Script {
    address WORK_VERIFIER_CONTRACT = 0x7Fd5fF811f9ffffb66cF05b225dc4c13B35a9bA2;
    address WORK_SHARES_MANAGER = 0xAaA9fBaFb9a8AbB649f8577065aaa42A4A90E567;

    function run() external returns (dWork) {
        HelperConfig helperConfig = new HelperConfig();
        (, , address priceFeed, ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast();
        dWork newDWork = new dWork(
            WORK_SHARES_MANAGER,
            WORK_VERIFIER_CONTRACT,
            priceFeed
        );
        vm.stopBroadcast();
        return newDWork;
    }
}
