// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {Script, console} from "forge-std/Script.sol";
import {ChainChecker} from "../src/ChainChecker.sol";

contract HelperConfig is Script, ChainChecker {
    NetworkConfig public activeNetworkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;

    struct NetworkConfig {
        address ethUsdPriceFeed;
        address chainLinkFunctionsRouter;
        bytes32 donId;
        uint64 subscriptionId;
        uint64 donHostedSecretsVersion;
    }

    constructor() {
        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            activeNetworkConfig = getBaseMainnetConfig();
        } else if (block.chainid == BASE_SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getBaseSepoliaConfig();
        } else if (block.chainid == ANVIL_CHAIN_ID) {
            activeNetworkConfig = getOrCreateAnvilConfig();
        } else {
            console.log("Error: invalid chain id! ", block.chainid);
        }
    }

    function getBaseMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            ethUsdPriceFeed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            chainLinkFunctionsRouter: 0xf9B8fc078197181C841c296C876945aaa425B278,
            donId: 0x66756e2d626173652d6d61696e6e65742d310000000000000000000000000000,
            subscriptionId: 0, // TODO
            donHostedSecretsVersion: 0 // TODO
        });
    }

    function getBaseSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            ethUsdPriceFeed: 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1,
            chainLinkFunctionsRouter: 0xf9B8fc078197181C841c296C876945aaa425B278,
            donId: 0x66756e2d626173652d7365706f6c69612d310000000000000000000000000000,
            subscriptionId: 607,
            donHostedSecretsVersion: 1774138413
        });
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
            donHostedSecretsVersion: 0
        });
        return anvilConfig;
    }
}
