// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployFragBoxBetting is Script {
    function run() external returns (FragBoxBetting) {
        HelperConfig helperConfig = new HelperConfig();
        address ethUsdPriceFeed = helperConfig.activeNetworkConfig();

        vm.startBroadcast();
        FragBoxBetting fragBoxBetting = new FragBoxBetting(ethUsdPriceFeed);
        vm.stopBroadcast();
        return fragBoxBetting;
    }
}