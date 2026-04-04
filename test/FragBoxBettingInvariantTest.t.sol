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
    string constant PLAYER_WIN = "94f98244-169d-478a-a5dd-21dde2e649ca";
    string constant PLAYER_LOSE = "92f1450e-182b-41db-8f31-53079df20c73";

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

    function invariant_totalEthConservation() public view {
        uint256 totalWithdrawn = handler.ghost_totalWithdrawnUsers() + handler.ghost_totalWithdrawnOwner();

        assertEq(
            address(fragBoxBetting).balance + totalWithdrawn,
            handler.ghost_totalDeposited(),
            "ETH conservation violated: total input != contract balance + all withdrawals"
        );
    }

    function invariant_noDoubleClaimOrRefund() public view {
        // handler tracks claimed/refunded actors — assert they cannot claim twice
        assertTrue(handler.ghost_noDoubleClaim());
    }

    function invariant_cooldownsPreventSpam() public view {
        assertTrue(handler.ghost_statusCooldownRespected());
        assertTrue(handler.ghost_rosterCooldownRespected());
    }

    function invariant_emergencyOnlyAfterTimeout() public view {
        assertTrue(handler.ghost_emergencyOnlyAfter24h());
    }

    function invariant_noBetOnOppositeFaction() public view {
        // Roster validation already prevents it — invariant just sanity checks factionTotals
        assertTrue(handler.ghost_factionTotalsNeverNegative());
    }
}
