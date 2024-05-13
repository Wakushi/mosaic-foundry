// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkFactory} from "../src/dWorkFactory.sol";
import {IGetDWorkFactoryReturnTypes} from "../src/interfaces/IGetDWorkFactoryReturnTypes.sol";

contract DeployDWorkFactory is Script {
    string constant workVerificationSource =
        "./functions/sources/work-verification-source.js";

    function run() external {
        IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType
            memory dWorkFactoryReturnType = getDWorkFactoryRequirements();

        vm.startBroadcast();
        deployDWorkFactory(
            dWorkFactoryReturnType.functionsRouter,
            dWorkFactoryReturnType.donId,
            dWorkFactoryReturnType.workVerificationSource,
            dWorkFactoryReturnType.priceFeed
        );
        vm.stopBroadcast();
    }

    function getDWorkFactoryRequirements()
        public
        returns (IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType memory)
    {
        HelperConfig helperConfig = new HelperConfig();
        (
            bytes32 donId,
            address functionsRouter,
            address priceFeed
        ) = helperConfig.activeNetworkConfig();

        if (
            functionsRouter == address(0) ||
            donId == bytes32(0) ||
            priceFeed == address(0)
        ) {
            revert("something is wrong");
        }
        string memory verificationSource = vm.readFile(workVerificationSource);
        return
            IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType(
                functionsRouter,
                donId,
                verificationSource,
                priceFeed
            );
    }

    function deployDWorkFactory(
        address _functionsRouter,
        bytes32 _donId,
        string memory _workVerificationSource,
        address priceFeed
    ) public returns (dWorkFactory) {
        dWorkFactory newDWorkFactory = new dWorkFactory(
            _functionsRouter,
            _donId,
            _workVerificationSource,
            priceFeed
        );
        return newDWorkFactory;
    }
}
