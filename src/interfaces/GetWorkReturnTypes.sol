// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IGetWorkReturnTypes {
    struct GetWorkReturnType {
        uint64 subId;
        bytes32 donId;
        address gallery;
        string workName;
        string workSymbol;
        address functionsRouter;
    }
}
