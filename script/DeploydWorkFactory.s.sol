// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkFactory} from "../src/dWorkFactory.sol";
import {IGetWorkVerifierReturnTypes} from "../src/interfaces/IGetWorkVerifierReturnTypes.sol";

contract DeployDWorkFactory is Script {
    address workVerifier = 0xD69752D5F0fd86A2241c1bb5B2c1a1b0A486F155;
    address workSharesManager = 0x60f7b9f6f83b38e98CCAB2b594F4bABd830307Ae;

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
