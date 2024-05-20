// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWork} from "../src/dWork.sol";

contract DeployDWork is Script {
    address WORK_VERIFIER_CONTRACT = 0xDd8dcbBb8588D179b98BA9CF3F7E108195B4A4BE;
    address WORK_SHARES_MANAGER = 0x2E2c641F61b1b6144Be9558b714F7Db52A5f9f60;

    function run() external returns (dWork) {
        vm.startBroadcast();
        dWork newDWork = new dWork(WORK_SHARES_MANAGER, WORK_VERIFIER_CONTRACT);
        vm.stopBroadcast();
        return newDWork;
    }
}
