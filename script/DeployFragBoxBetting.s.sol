// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {
    IFunctionsSubscriptions
} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsSubscriptions.sol";

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

        IFunctionsSubscriptions functionsSubscriptions = IFunctionsSubscriptions(chainLinkFunctionsRouter);
        IFunctionsSubscriptions.Subscription memory sub = functionsSubscriptions.getSubscription(subscriptionId);

        vm.startBroadcast(sub.owner);

        FragBoxBetting fragBoxBetting =
            new FragBoxBetting(ethUsdPriceFeed, chainLinkFunctionsRouter, donId, subscriptionId, linkToken);

        fragBoxBetting.setFaceitApiKey(faceitApiKey);

        functionsSubscriptions.addConsumer(subscriptionId, address(fragBoxBetting));

        vm.stopBroadcast();

        return fragBoxBetting;
    }
}
