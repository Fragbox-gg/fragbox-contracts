// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployFragBoxBetting is Script {
    function run() external returns (FragBoxBetting) {
        HelperConfig helperConfig = new HelperConfig();
        (
            address usdcAddress
        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast();
        FragBoxBetting fragBoxBetting = new FragBoxBetting(usdcAddress);
        vm.stopBroadcast();

        return fragBoxBetting;
    }
}
