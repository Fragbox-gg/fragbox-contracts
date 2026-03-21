// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployFragBoxBetting is Script {
    function run() external returns (FragBoxBetting) {
        HelperConfig helperConfig = new HelperConfig();
        (
            address ethUsdPriceFeed,
            address chainLinkFunctionsRouter,
            bytes32 donId,
            uint64 subscriptionId,
            address linkToken
        ) = helperConfig.activeNetworkConfig();

        string memory faceitApiKey = vm.envOr("FACEIT_CLIENT_API_KEY", string("dummy-api-key"));

        vm.startBroadcast();

        FragBoxBetting fragBoxBetting =
            new FragBoxBetting(ethUsdPriceFeed, chainLinkFunctionsRouter, donId, subscriptionId, linkToken);

        fragBoxBetting.setFaceitApiKey(faceitApiKey);

        vm.stopBroadcast();
        return fragBoxBetting;
    }
}
