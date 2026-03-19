// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract ChainChecker {
    uint256 constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant ANVIL_CHAIN_ID = 31337;

    function isOnBaseChainId() public view returns (bool) {
        // We can make a "dummy" check by looking at the chainId, but this won't work for when working with foundry
        return block.chainid == BASE_MAINNET_CHAIN_ID || block.chainid == BASE_SEPOLIA_CHAIN_ID;
    }

    function isOnBasePrecompiles() public returns (bool isBase) {
        // As of writing, at least 0x03, 0x04, 0x05, and 0x08 precompiles are not supported on base
        // So, we can call them to check if we are on base or not
        // This test may fail in the future if these precompiles become supported on base
        uint256 value = 1;
        address ripemd = address(uint160(3));
        address identity = address(uint160(4));
        address modexp = address(uint160(5));

        address[3] memory targets = [ripemd, identity, modexp];

        for (uint256 i = 0; i < targets.length; i++) {
            bool success;
            address target = targets[i];
            assembly {
                success := call(gas(), target, value, 0, 0, 0, 0)
            }
            if (!success) {
                isBase = true;
                return isBase;
            }
        }
        return isBase;
    }

    function isBaseChain() public returns (bool isBase) {
        if (isOnBaseChainId()) {
            return isBase;
        }
        return isOnBasePrecompiles();
    }

    modifier skipBase() {
        if (isBaseChain()) {
            console2.log("Skipping test because we are on base");
            return;
        } else {
            _;
        }
    }

    modifier onlyBase() {
        if (!isBaseChain()) {
            console2.log("Skipping test because we are not on base");
            return;
        } else {
            _;
        }
    }
}