// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {ETHReceiver} from "./mocks/ETHReceiver.sol";
import {SimulateOracles} from "./SimulateOracles.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FragBoxBettingFuzzTest is SimulateOracles {
    FragBoxBetting fragBoxBetting;
    address chainLinkFunctionsRouter;

    address public USER;
    ETHReceiver public receiver;
    uint256 constant SEND_VALUE = 0.1 ether;
    uint256 constant STARTING_BALANCE = 10 ether;

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        (fragBoxBetting, chainLinkFunctionsRouter) = deployFragBoxBetting.run();

        receiver = new ETHReceiver();
        USER = address(receiver);
        vm.deal(USER, STARTING_BALANCE);

        super.setUpSimulation(chainLinkFunctionsRouter, fragBoxBetting);
    }

    function testFuzz_DepositAndTopUp(uint256 bet1, uint256 bet2) public {
        bet1 = bound(bet1, 0.01 ether, 1.2 ether);
        bet2 = bound(bet2, 0.01 ether, 1.2 ether);

        // (your existing mock setup for roster + status would go here)
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: bet1}(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = super._captureRequestId();
        super._simulateFulfill(requestId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        // Don't need to capture request id and simulate fulfill because we're stacking a bet on the same playerid, so the roster was already validated
        vm.prank(USER);
        fragBoxBetting.deposit{value: bet2}(MATCHID, WINNING_PLAYERID);

        FragBoxBetting.MatchBetView memory vw = fragBoxBetting.getMatchBet(fragBoxBetting.getKey(MATCHID));
        uint256 bet1Fee = fragBoxBetting.calculateDepositFee(bet1);
        uint256 bet2Fee = fragBoxBetting.calculateDepositFee(bet2);
        uint256 betSum = (bet1 - bet1Fee) + (bet2 - bet2Fee);

        uint256 sum = 0;
        uint256 len = vw.factionTotals.length;
        for (uint256 i = 0; i < len; i++) {
            sum += vw.factionTotals[i];
        }

        assertEq(sum, betSum); // after 1% fee
    }

    function testFuzz_ClaimPayoutSymmetry(
        uint256 betWin1, uint256 betWin2, uint256 betLose1, uint256 betLose2
    ) public {
        // setup match, deposit various amounts on F1/F2, fulfill as Finished with winner = F1
        // ... (use your existing SimulateFunctionsOracle helpers)
        uint256 totalWin = 0;
        uint256 totalLose = 0;
        
        uint256 minBet = Math.min(totalWin, totalLose);
        uint256 expectedTotalToWinners = 2 * minBet;

        // claim for each winner
        // assert each winner received exactly (bet * 2 * minBet) / totalWin   (plus dust handling)
        // assert losers received excess only if applicable
        // assert contract balance + ownerFees == totalDeposits (invariant)
    }


}
