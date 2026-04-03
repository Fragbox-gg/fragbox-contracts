// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {ETHReceiver} from "./mocks/ETHReceiver.sol";
import {SimulateOracles} from "./SimulateOracles.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ETHReceiver} from "./mocks/ETHReceiver.sol";

contract FragBoxBettingFuzzTest is SimulateOracles {
    FragBoxBetting fragBoxBetting;
    address chainLinkFunctionsRouter;

    address public USER;
    address public USER2;
    ETHReceiver public receiver;
    uint256 constant SEND_VALUE = 0.1 ether;
    uint256 constant STARTING_BALANCE = 10 ether;

    FragBoxBetting.Faction constant LOSING_FACTION = FragBoxBetting.Faction.Faction2;

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        (fragBoxBetting, chainLinkFunctionsRouter) = deployFragBoxBetting.run();

        receiver = new ETHReceiver();
        USER = address(receiver);
        vm.deal(USER, STARTING_BALANCE);

        USER2 = address(new ETHReceiver());
        vm.deal(USER2, STARTING_BALANCE);

        super.setUpSimulation(chainLinkFunctionsRouter, fragBoxBetting);

        vm.startPrank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER);
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID, USER2);
        vm.stopPrank();
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

    function testFuzz_ClaimPayoutSymmetry(uint256 betWin1, uint256 betWin2, uint256 betLose1, uint256 betLose2) public {
        uint256 betWin1WithFee;
        uint256 betWin2WithFee;
        uint256 betLose1WithFee;
        uint256 betLose2WithFee;

        (betWin1, betWin2, betLose1, betLose2,,,,, betWin1WithFee, betWin2WithFee, betLose1WithFee, betLose2WithFee) =
            getRandomBets(betWin1, betWin2, betLose1, betLose2);

        uint256 user1BalanceBefore = USER.balance;
        uint256 user2BalanceBefore = USER2.balance;

        uint256 totalWin = betWin1WithFee + betWin2WithFee;
        uint256 totalLose = betLose1WithFee + betLose2WithFee;
        uint256 minBet = Math.min(totalWin, totalLose);

        uint256 expectedUser1 = 0;
        uint256 expectedUser2 = 0;

        // Winning bets (Faction1) — always get 2 * minBet pro-rata + excess refund if winners overbet
        if (totalWin > 0) {
            uint256 baseWin1 = (betWin1WithFee * 2 * minBet) / totalWin;
            uint256 baseWin2 = (betWin2WithFee * 2 * minBet) / totalWin;

            expectedUser1 += baseWin1;
            expectedUser2 += baseWin2;

            if (totalWin > totalLose) {
                uint256 excess = totalWin - minBet;
                expectedUser1 += (betWin1WithFee * excess) / totalWin;
                expectedUser2 += (betWin2WithFee * excess) / totalWin;
            }
        }

        // Losing bets excess refund (only if losers overbet — handled in the if inside claim)
        if (totalLose > totalWin && totalLose > 0) {
            uint256 excess = totalLose - minBet;
            expectedUser1 += (betLose1WithFee * excess) / totalLose;
            expectedUser2 += (betLose2WithFee * excess) / totalLose;
        }

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER);

        // Deposit winners
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: betWin1}(MATCHID, WINNING_PLAYERID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER2);

        vm.prank(USER2); // reuse USER2 for second winner (in real fuzz you'd add more actors)
        fragBoxBetting.deposit{value: betWin2}(MATCHID, WINNING_PLAYERID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID, USER);

        // Deposit losers
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: betLose1}(MATCHID, LOSING_PLAYERID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_LOSING_PLAYER), "");

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID, USER2);

        vm.prank(USER2);
        fragBoxBetting.deposit{value: betLose2}(MATCHID, LOSING_PLAYERID);

        // Finish match with Faction1 win
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_STATUS_READY), "");

        vm.warp(block.timestamp + 6 minutes);

        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_STATUS_FINISHED), "");

        // Claim + withdraw
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);

        if (totalLose > totalWin) {
            fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
            fragBoxBetting.withdraw(LOSING_PLAYERID);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__LosingFactionCannotClaim.selector, LOSING_FACTION)
            );
            fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
        }
        vm.stopPrank();

        vm.startPrank(USER2);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);

        if (totalLose > totalWin) {
            fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
            fragBoxBetting.withdraw(LOSING_PLAYERID);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__LosingFactionCannotClaim.selector, LOSING_FACTION)
            );
            fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
        }
        vm.stopPrank();

        // Verify each user received *exactly* their pro-rata share (after withdraw)
        assertEq(
            USER.balance,
            user1BalanceBefore - betWin1 - betLose1 + expectedUser1,
            "USER net payout incorrect (winning + optional losing excess)"
        );
        assertEq(
            USER2.balance,
            user2BalanceBefore - betWin2 - betLose2 + expectedUser2,
            "USER2 net payout incorrect (winning + optional losing excess)"
        );

        // === SYMMETRY + DUST INVARIANT (the strongest check) ===
        // Contract must hold *only* the rounding dust swept to ownerFeesCollected.
        // All bets (totalWin + totalLose) minus dust = everything paid to players.
        vm.prank(fragBoxBetting.owner());
        assertApproxEqAbs(
            address(fragBoxBetting).balance,
            fragBoxBetting.getOwnerFeesCollected(),
            1000,
            "Contract balance must equal collected owner fees + negligible flooring dust"
        );
    }

    function getRandomBets(uint256 betWin1, uint256 betWin2, uint256 betLose1, uint256 betLose2)
        internal
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        betWin1 = bound(betWin1, 0.01 ether, 1 ether);
        betWin2 = bound(betWin2, 0.01 ether, 1 ether);
        betLose1 = bound(betLose1, 0.01 ether, 1 ether);
        betLose2 = bound(betLose2, 0.01 ether, 1 ether);

        uint256 betWin1Fee = fragBoxBetting.calculateDepositFee(betWin1);
        uint256 betWin2Fee = fragBoxBetting.calculateDepositFee(betWin2);
        uint256 betLose1Fee = fragBoxBetting.calculateDepositFee(betLose1);
        uint256 betLose2Fee = fragBoxBetting.calculateDepositFee(betLose2);

        uint256 betWin1WithFee = betWin1 - betWin1Fee;
        uint256 betWin2WithFee = betWin2 - betWin2Fee;
        uint256 betLose1WithFee = betLose1 - betLose1Fee;
        uint256 betLose2WithFee = betLose2 - betLose2Fee;

        return (
            betWin1,
            betWin2,
            betLose1,
            betLose2,
            betWin1Fee,
            betWin2Fee,
            betLose1Fee,
            betLose2Fee,
            betWin1WithFee,
            betWin2WithFee,
            betLose1WithFee,
            betLose2WithFee
        );
    }
}
