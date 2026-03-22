// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";

abstract contract ChainChecker {
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant ANVIL_CHAIN_ID = 31337;

    function isOnBaseChainId() public view returns (bool) {
        return block.chainid == BASE_MAINNET_CHAIN_ID || block.chainid == BASE_SEPOLIA_CHAIN_ID;
    }

    modifier skipBase() {
        if (isOnBaseChainId()) {
            console2.log("Skipping test because we are on Base");
            return;
        } else {
            _;
        }
    }

    modifier onlyBase() {
        if (!isOnBaseChainId()) {
            console2.log("Skipping test because we are not on Base");
            return;
        } else {
            _;
        }
    }
}
