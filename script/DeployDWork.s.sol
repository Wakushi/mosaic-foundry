// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWork} from "../src/dWork.sol";

contract DeployDWork is Script {
    address WORK_VERIFIER_CONTRACT = 0xe94079Bae7d3aD1d2FB9Fc5F4726bcAd8FCE21Fc;
    address WORK_SHARES_MANAGER = 0x6c76dF0cBc3020cb7c4597001Fe751Ed9f9E5a63;

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
