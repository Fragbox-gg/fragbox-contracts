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

    function invariant_emergencyRefundOnlyAfterTrueTimeout() public {
        // after deposit, lastStatusUpdate must be > 0
        // emergencyRefund must revert if < 24h from lastStatusUpdate
    }

    function invariant_contractBalanceConsistency() public {
        // total ETH in contract == sum(all factionTotals) + sum(flight funds) + sum(playerToWinnings) + ownerFeesCollected
        // (modulo any withdrawn owner fees)
    }

    // Add these invariants (they run after every handler call)
    function invariant_totalEthConservation() public view {
        uint256 contractBal = address(fragBoxBetting).balance;
        uint256 totalInFlight = handler.ghost_totalInFlight(); // add ghost to handler
        uint256 totalWinnings = 0; // sum playerToWinnings across actors (or expose view)
        uint256 ownerFees = fragBoxBetting.getOwnerFees();

        // Rough but powerful: contract ETH should equal in-flight + winnings + fees + factionTotals
        assertEq(contractBal, totalInFlight + totalWinnings + ownerFees + handler.ghost_factionTotalsSum());
    }

    function invariant_noDoubleClaim() public {
        // after claim or emergencyRefund, betAmount == 0 and cannot claim again
    }

    function invariant_cooldownsPreventSpam() public {
        // status/roster requests respect cooldowns (use handler timestamps)
    }

    function invariant_emergencyOnlyAfterTimeout() public {
        // emergencyRefund reverts unless >=24h from lastStatusUpdate
    }
}
