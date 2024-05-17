// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkFactory} from "../src/dWorkFactory.sol";
import {IGetWorkVerifierReturnTypes} from "../src/interfaces/IGetWorkVerifierReturnTypes.sol";

contract DeployDWorkFactory is Script {
    address workVerifier = 0x8a6aBe1ed2bE7EA85391039c19178eF9c480c1E9;
    address workSharesManager = 0xb4F885259EA241973960C4910254d417b73a6A80;

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
