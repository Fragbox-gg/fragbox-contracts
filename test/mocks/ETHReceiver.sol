// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// This is necessary for forked testing otherwise the USER address won't be able to receive ETH
contract ETHReceiver {
    receive() external payable {}
    // optional: fallback() external payable {}
}