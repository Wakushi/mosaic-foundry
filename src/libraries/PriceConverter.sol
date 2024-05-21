// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./OracleLib.sol";

library PriceConverter {
    using OracleLib for AggregatorV3Interface;

    function getPrice(
        AggregatorV3Interface priceFeed
    ) internal view returns (uint256) {
        (, int256 answer, , , ) = priceFeed.staleCheckLatestRoundData();
        return uint256(answer * 10000000000);
    }

    function getConversionRate(
        uint256 _nativeTokenAmount,
        AggregatorV3Interface priceFeed
    ) internal view returns (uint256) {
        uint256 nativeTokenPriceUsd = getPrice(priceFeed);
        uint256 nativeTokenAmountInUsd = (nativeTokenPriceUsd *
            _nativeTokenAmount) / 1000000000000000000;
        return nativeTokenAmountInUsd;
    }
}
