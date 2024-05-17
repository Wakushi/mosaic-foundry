// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWorkFactory {
    function isWorkContract(address _workContract) external view returns (bool);
}
