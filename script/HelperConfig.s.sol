// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {Script, console} from "forge-std/Script.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;

    struct NetworkConfig {
        address ethUsdPriceFeed;
        address chainLinkFunctionsRouter;
        bytes32 donId;
        uint64 subscriptionId;
        address linkToken;
    }

    constructor() {
        if (block.chainid == 84532) {
            activeNetworkConfig = getSepoliaBaseConfig();
        } else if (block.chainid == 31337) {
            activeNetworkConfig = getOrCreateAnvilConfig();
        } else {
            console.log("Error: invalid chain id! ", block.chainid);
        }
    }

    function getSepoliaBaseConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory sepoliaConfig = NetworkConfig({
            ethUsdPriceFeed: 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1,
            chainLinkFunctionsRouter: 0xf9B8fc078197181C841c296C876945aaa425B278,
            donId: 0x66756e2d626173652d7365706f6c69612d310000000000000000000000000000,
            subscriptionId: 607,
            linkToken: 0xE4aB69C077896252FAFBD49EFD26B5D171A32410
        });
        return sepoliaConfig;
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        // If we call this function twice on accident it will create a new price feed.
        // So if the priceFeed is not the default value, return the existing one
        if (activeNetworkConfig.ethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        // 1. Deploy the mocks
        // 2. Return the mock address

        vm.startBroadcast();
        MockV3Aggregator ethUsdMockPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        vm.stopBroadcast();

        NetworkConfig memory anvilConfig = NetworkConfig({
            ethUsdPriceFeed: address(ethUsdMockPriceFeed),
            chainLinkFunctionsRouter: address(0),
            donId: bytes32(0),
            subscriptionId: 0,
            linkToken: address(0)
        });
        return anvilConfig;
    }
}
