// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkFactory} from "../src/dWorkFactory.sol";
import {IGetWorkVerifierReturnTypes} from "../src/interfaces/IGetWorkVerifierReturnTypes.sol";

contract DeployDWorkFactory is Script {
    address workVerifier = 0x486Bc902b120741Dff8563d0462af105F49598db;
    address workSharesManager = 0x0bbc414f42DB6Ad35eEF14c553c49B63e368E965;

    function run() external returns (dWorkFactory) {
        HelperConfig helperConfig = new HelperConfig();
        (, , address priceFeed, ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast();
        dWorkFactory newdWorkFactory = new dWorkFactory(
            priceFeed,
            workVerifier,
            workSharesManager
        );
        vm.stopBroadcast();

        return newdWorkFactory;
    }
}
