// SPDX-License-Identifier: MIt
pragma solidity ^0.8.19;

interface IDWork {
    function isMinted() external view returns (bool);

    function isFractionalized() external view returns (bool);

    function setIsFractionalized(bool _isFractionalized) external;

    function getWorkPriceUsd() external view returns (uint256);
}
