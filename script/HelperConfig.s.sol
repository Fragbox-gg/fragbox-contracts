// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChainChecker} from "../src/ChainChecker.sol";

contract HelperConfig is Script, ChainChecker {
    NetworkConfig public activeNetworkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;

    struct NetworkConfig {
        address usdcAddress;
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
            usdcAddress: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            chainLinkFunctionsRouter: 0xf9B8fc078197181C841c296C876945aaa425B278,
            donId: 0x66756e2d626173652d6d61696e6e65742d310000000000000000000000000000,
            subscriptionId: 0, // TODO
            donHostedSecretsVersion: 0 // TODO
        });
    }

    function getBaseSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            usdcAddress: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
            chainLinkFunctionsRouter: 0xf9B8fc078197181C841c296C876945aaa425B278,
            donId: 0x66756e2d626173652d7365706f6c69612d310000000000000000000000000000,
            subscriptionId: 607,
            donHostedSecretsVersion: 1774138413
        });
    }

    function getOrCreateAnvilConfig() public view returns (NetworkConfig memory) {
        // If we call this function twice on accident it will create a new price feed.
        // So if the priceFeed is not the default value, return the existing one
        if (activeNetworkConfig.usdcAddress != address(0)) {
            return activeNetworkConfig;
        }

        NetworkConfig memory anvilConfig = NetworkConfig({
            usdcAddress: address(0),
            chainLinkFunctionsRouter: address(0),
            donId: bytes32(0),
            subscriptionId: 0,
            donHostedSecretsVersion: 0
        });
        return anvilConfig;
    }
}
