// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkFactory} from "../src/dWorkFactory.sol";
import {IGetWorkVerifierReturnTypes} from "../src/interfaces/IGetWorkVerifierReturnTypes.sol";

contract DeployDWorkFactory is Script {
    address workVerifier = 0x83fDB0D28eeDA2a74a4E6223a4FA15ca60447862; // Replace with actual address
    address workSharesManager = 0x7760B6Fd01995E942B8b87152BC25D0bD9c06d76; // Replace with actual address

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
