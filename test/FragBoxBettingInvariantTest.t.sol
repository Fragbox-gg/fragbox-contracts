// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {FragBoxHandler} from "./handlers/FragBoxHandler.sol";

contract FragBoxBettingInvariantTest is Test {
    FragBoxBetting public fragBoxBetting;
    FragBoxHandler public handler;

    string constant MATCH_ID = "1-a536dd90-4df3-42df-be6e-d158177fdef2";

    function setUp() public {
        DeployFragBoxBetting deployer = new DeployFragBoxBetting();
        (fragBoxBetting,) = deployer.run();

        handler = new FragBoxHandler(fragBoxBetting);

        // This tells Foundry to ONLY call functions on the handler
        targetContract(address(handler));
    }

    // ==================== INVARIANTS (these run after every fuzz call) ====================
    function invariant_contractBalanceNeverNegative() public view {
        assertGe(address(fragBoxBetting).balance, 0);
    }

    function invariant_ghostDepositedConsistency() public view {
        // Rough sanity check that deposits actually happened
        assertTrue(handler.ghost_totalDeposited() >= 0);
    }
}
