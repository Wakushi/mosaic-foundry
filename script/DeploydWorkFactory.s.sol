// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkFactory} from "../src/dWorkFactory.sol";
import {IGetDWorkFactoryReturnTypes} from "../src/interfaces/IGetDWorkFactoryReturnTypes.sol";

contract DeployDWorkFactory is Script {
    string constant workVerificationSource =
        "./functions/sources/work-verification-source.js";
    string constant certificateExtractionSource =
        "./functions/sources/certificate-extraction-source.js";

    function run() external {
        IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType
            memory dWorkFactoryReturnType = getDWorkFactoryRequirements();

        vm.startBroadcast();
        deployDWorkFactory(
            dWorkFactoryReturnType.functionsRouter,
            dWorkFactoryReturnType.donId,
            dWorkFactoryReturnType.functionsSubId,
            dWorkFactoryReturnType.workVerificationSource,
            dWorkFactoryReturnType.certificateExtractionSource,
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
            address priceFeed,
            uint64 functionsSubId
        ) = helperConfig.activeNetworkConfig();

        string memory verificationSource = vm.readFile(workVerificationSource);
        string memory certificateSource = vm.readFile(
            certificateExtractionSource
        );
        if (
            functionsRouter == address(0) ||
            donId == bytes32(0) ||
            priceFeed == address(0) ||
            bytes(verificationSource).length == 0
        ) {
            revert("something is wrong");
        }

        return
            IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType(
                functionsRouter,
                donId,
                functionsSubId,
                verificationSource,
                certificateSource,
                priceFeed
            );
    }

    function deployDWorkFactory(
        address _functionsRouter,
        bytes32 _donId,
        uint64 _functionsSubId,
        string memory _workVerificationSource,
        string memory _certificateExtractionSource,
        address priceFeed
    ) public returns (dWorkFactory) {
        dWorkFactory newDWorkFactory = new dWorkFactory(
            _functionsRouter,
            _donId,
            _functionsSubId,
            _workVerificationSource,
            _certificateExtractionSource,
            priceFeed
        );
        return newDWorkFactory;
    }
}
