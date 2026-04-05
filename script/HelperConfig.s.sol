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
            usdcAddress: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
        });
    }

    function getBaseSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            usdcAddress: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
        });
    }

    function getOrCreateAnvilConfig() public view returns (NetworkConfig memory) {
        // If we call this function twice on accident it will create a new price feed.
        // So if the priceFeed is not the default value, return the existing one
        if (activeNetworkConfig.usdcAddress != address(0)) {
            return activeNetworkConfig;
        }

        NetworkConfig memory anvilConfig = NetworkConfig({
            usdcAddress: address(0)
        });
        return anvilConfig;
    }
}
