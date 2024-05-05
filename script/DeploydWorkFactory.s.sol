// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkFactory} from "../src/dWorkFactory.sol";
import {IGetDWorkFactoryReturnTypes} from "../src/interfaces/IGetDWorkFactoryReturnTypes.sol";

contract DeployDWorkFactory is Script {
    string constant externalWorkVerificationSource =
        "./functions/sources/workVerification.js";
    uint32 constant GAS_LIMIT = 300000;

    function run() external {
        IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType
            memory dWorkFactoryReturnType = getDWorkFactoryRequirements();

        vm.startBroadcast();
        deployDWorkFactory(
            dWorkFactoryReturnType.functionsRouter,
            dWorkFactoryReturnType.donId,
            dWorkFactoryReturnType.workVerificationSource
        );
        vm.stopBroadcast();
    }

    function getDWorkFactoryRequirements()
        public
        returns (IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType memory)
    {
        HelperConfig helperConfig = new HelperConfig();
        (bytes32 donId, address functionsRouter) = helperConfig
            .activeNetworkConfig();

        if (functionsRouter == address(0) || donId == bytes32(0)) {
            revert("something is wrong");
        }
        string memory workVerificationSource = vm.readFile(
            externalWorkVerificationSource
        );
        return
            IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType(
                functionsRouter,
                donId,
                workVerificationSource
            );
    }

    function deployDWorkFactory(
        address _functionsRouter,
        bytes32 _donId,
        string memory _workVerificationSource
    ) public returns (dWorkFactory) {
        dWorkFactory newDWorkFactory = new dWorkFactory(
            _functionsRouter,
            _donId,
            GAS_LIMIT,
            _workVerificationSource
        );
        return newDWorkFactory;
    }
}
