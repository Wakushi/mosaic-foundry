// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {WorkVerifier} from "../src/WorkVerifier.sol";
import {IGetWorkVerifierReturnTypes} from "../src/interfaces/IGetWorkVerifierReturnTypes.sol";
import {IFunctionsSubscriptions} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsSubscriptions.sol";

contract DeployWorkVerifier is Script {
    string constant WORK_VERIFIATION_SOURCE =
        "./functions/sources/work-verification-source.js";
    string constant CERTIFICATE_EXTRACTION_SOURCE =
        "./functions/sources/certificate-extraction-source.js";
    bytes constant DON_SECRETS_REFERENCE =
        hex"a266736c6f744964006776657273696f6e1a664da557";

    function run() external {
        IGetWorkVerifierReturnTypes.GetWorkVerifierReturnType
            memory workVerifierReturnType = getWorkVerifierRequirements();

        vm.startBroadcast();
        address newWorkVerifier = deployWorkVerifier(
            workVerifierReturnType.functionsRouter,
            workVerifierReturnType.donId,
            workVerifierReturnType.functionsSubId,
            workVerifierReturnType.secretReference,
            workVerifierReturnType.workVerificationSource,
            workVerifierReturnType.certificateExtractionSource
        );
        IFunctionsSubscriptions(workVerifierReturnType.functionsRouter)
            .addConsumer(
                workVerifierReturnType.functionsSubId,
                newWorkVerifier
            );
        vm.stopBroadcast();
    }

    function getWorkVerifierRequirements()
        public
        returns (IGetWorkVerifierReturnTypes.GetWorkVerifierReturnType memory)
    {
        HelperConfig helperConfig = new HelperConfig();
        (
            bytes32 donId,
            address functionsRouter,
            ,
            uint64 functionsSubId,
            ,
            ,

        ) = helperConfig.activeNetworkConfig();

        string memory verificationSource = vm.readFile(WORK_VERIFIATION_SOURCE);
        string memory certificateSource = vm.readFile(
            CERTIFICATE_EXTRACTION_SOURCE
        );
        if (
            functionsRouter == address(0) ||
            donId == bytes32(0) ||
            bytes(verificationSource).length == 0
        ) {
            revert("something is wrong");
        }

        return
            IGetWorkVerifierReturnTypes.GetWorkVerifierReturnType(
                functionsRouter,
                donId,
                DON_SECRETS_REFERENCE,
                functionsSubId,
                verificationSource,
                certificateSource
            );
    }

    function deployWorkVerifier(
        address _functionsRouter,
        bytes32 _donId,
        uint64 _functionsSubId,
        bytes memory _secretReference,
        string memory _workVerificationSource,
        string memory _certificateExtractionSource
    ) public returns (address) {
        WorkVerifier newWorkVerifier = new WorkVerifier(
            _functionsRouter,
            _donId,
            _functionsSubId,
            _secretReference,
            _workVerificationSource,
            _certificateExtractionSource
        );
        return address(newWorkVerifier);
    }
}
