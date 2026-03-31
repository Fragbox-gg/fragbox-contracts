// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {
    IFunctionsSubscriptions
} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsSubscriptions.sol";

contract DeployFragBoxBetting is Script {
    function run() external returns (FragBoxBetting, address) {
        HelperConfig helperConfig = new HelperConfig();
        (
            address ethUsdPriceFeed,
            address chainLinkFunctionsRouter,
            bytes32 donId,
            uint64 subscriptionId,
            uint64 donHostedSecretsVersion
        ) = helperConfig.activeNetworkConfig();

        IFunctionsSubscriptions functionsSubscriptions = IFunctionsSubscriptions(chainLinkFunctionsRouter);
        IFunctionsSubscriptions.Subscription memory sub = functionsSubscriptions.getSubscription(subscriptionId);

        string memory getRoster = vm.readFile("script/functions/getRoster.js");
        string memory getStatus = vm.readFile("script/functions/getStatus.js");

        vm.startBroadcast(sub.owner);

        FragBoxBetting fragBoxBetting =
            new FragBoxBetting(ethUsdPriceFeed, chainLinkFunctionsRouter, donId, subscriptionId, getRoster, getStatus);

        fragBoxBetting.updateDonSecrets(0, donHostedSecretsVersion);

        functionsSubscriptions.addConsumer(subscriptionId, address(fragBoxBetting));

        vm.stopBroadcast();

        return (fragBoxBetting, chainLinkFunctionsRouter);
    }
}
