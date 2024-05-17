// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {dWorkFactory} from "../src/dWorkFactory.sol";
import {IGetDWorkFactoryReturnTypes} from "../src/interfaces/IGetDWorkFactoryReturnTypes.sol";

contract DeployDWorkFactory is Script {
    string constant WORK_VERIFIATION_SOURCE =
        "./functions/sources/work-verification-source.js";
    string constant CERTIFICATE_EXTRACTION_SOURCE =
        "./functions/sources/certificate-extraction-source.js";
    bytes constant DON_SECRETS_REFERENCE = "0x0";

    function run() external {
        IGetDWorkFactoryReturnTypes.GetDWorkFactoryReturnType
            memory dWorkFactoryReturnType = getDWorkFactoryRequirements();

        vm.startBroadcast();
        deployDWorkFactory(
            dWorkFactoryReturnType.functionsRouter,
            dWorkFactoryReturnType.donId,
            dWorkFactoryReturnType.secretReference,
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

        string memory verificationSource = vm.readFile(WORK_VERIFIATION_SOURCE);
        string memory certificateSource = vm.readFile(
            CERTIFICATE_EXTRACTION_SOURCE
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
                DON_SECRETS_REFERENCE,
                functionsSubId,
                verificationSource,
                certificateSource,
                priceFeed
            );
    }

    function deployDWorkFactory(
        address _functionsRouter,
        bytes32 _donId,
        bytes memory _secretReference,
        uint64 _functionsSubId,
        string memory _workVerificationSource,
        string memory _certificateExtractionSource,
        address priceFeed
    ) public returns (dWorkFactory) {
        dWorkFactory newDWorkFactory = new dWorkFactory(
            _functionsRouter,
            _donId,
            _secretReference,
            _functionsSubId,
            _workVerificationSource,
            _certificateExtractionSource,
            priceFeed
        );
        return newDWorkFactory;
    }
}
