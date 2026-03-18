// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract FragBoxBetting is ReentrancyGuard, Ownable, FunctionsClient {
    using OracleLib for AggregatorV3Interface;

    AggregatorV3Interface private s_ethUsdPriceFeed;

    constructor(address ethUsdPriceFeed) Ownable(msg.sender) FunctionsClient(msg.sender) {
        s_ethUsdPriceFeed = AggregatorV3Interface(ethUsdPriceFeed);
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {}
}
