// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {SimulateOracles} from "./SimulateOracles.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FragBoxBettingFuzzTest is SimulateOracles {
    FragBoxBetting fragBoxBetting;
    address chainLinkFunctionsRouter;

    address public USER;
    address public USER2;
    address public USER3;
    address public USER4;
    uint256 constant MIN_SEND_VALUE = 5_000_000; // $5
    uint256 constant MAX_SEND_VALUE = 10_000_000; // $10
    uint8 constant DEFAULT_TIER_ID = 1;
    uint256 constant STARTING_USDC_BALANCE = 50_000_000; // $50

    FragBoxBetting.Faction constant LOSING_FACTION = FragBoxBetting.Faction.Faction2;

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        (fragBoxBetting, chainLinkFunctionsRouter) = deployFragBoxBetting.run();

        USER = makeAddr("USER");
        deal(address(fragBoxBetting.getUsdc()), USER, STARTING_USDC_BALANCE);

        USER2 = makeAddr("USER2");
        deal(address(fragBoxBetting.getUsdc()), USER2, STARTING_USDC_BALANCE);

        USER3 = makeAddr("USER3");
        deal(address(fragBoxBetting.getUsdc()), USER3, STARTING_USDC_BALANCE);

        USER4 = makeAddr("USER4");
        deal(address(fragBoxBetting.getUsdc()), USER4, STARTING_USDC_BALANCE);

        vm.startPrank(USER);
        fragBoxBetting.getUsdc().approve(address(fragBoxBetting), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER2);
        fragBoxBetting.getUsdc().approve(address(fragBoxBetting), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER3);
        fragBoxBetting.getUsdc().approve(address(fragBoxBetting), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER4);
        fragBoxBetting.getUsdc().approve(address(fragBoxBetting), type(uint256).max);
        vm.stopPrank();

        super.setUpSimulation(chainLinkFunctionsRouter, fragBoxBetting);

        vm.startPrank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER);
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID2, USER2);
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID, USER3);
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID2, USER4);
        vm.stopPrank();
    }

    function testFuzz_DepositAndTopUp(uint256 bet1, uint256 bet2) public {
        bet1 = bound(bet1, MIN_SEND_VALUE, MAX_SEND_VALUE);
        bet2 = bound(bet2, MIN_SEND_VALUE, MAX_SEND_VALUE);

        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, bet1, DEFAULT_TIER_ID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        super._startRequestCapture();
        vm.prank(USER2);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID2, bet2, DEFAULT_TIER_ID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER_2), "");

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
        BetTestData memory data = getRandomBets(betWin1, betWin2, betLose1, betLose2);

        // Deposit winners
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, data.betWin1, DEFAULT_TIER_ID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        super._startRequestCapture();
        vm.prank(USER2);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID2, data.betWin2, DEFAULT_TIER_ID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER_2), "");

        // Deposit losers
        super._startRequestCapture();
        vm.prank(USER3);
        fragBoxBetting.deposit(MATCHID, LOSING_PLAYERID, data.betLose1, DEFAULT_TIER_ID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_LOSING_PLAYER), "");

        super._startRequestCapture();
        vm.prank(USER4);
        fragBoxBetting.deposit(MATCHID, LOSING_PLAYERID2, data.betLose2, DEFAULT_TIER_ID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_LOSING_PLAYER_2), "");

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
        vm.stopPrank();

        vm.startPrank(USER2);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID2);
        fragBoxBetting.withdraw(WINNING_PLAYERID2);
        vm.stopPrank();

        vm.startPrank(USER3);
        if (data.totalLose > data.totalWin) {
            fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
            fragBoxBetting.withdraw(LOSING_PLAYERID);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__LosingFactionCannotClaim.selector, LOSING_FACTION)
            );
            fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
        }
        vm.stopPrank();

        vm.startPrank(USER4);
        if (data.totalLose > data.totalWin) {
            fragBoxBetting.claim(MATCHID, LOSING_PLAYERID2);
            fragBoxBetting.withdraw(LOSING_PLAYERID2);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__LosingFactionCannotClaim.selector, LOSING_FACTION)
            );
            fragBoxBetting.claim(MATCHID, LOSING_PLAYERID2);
        }
        vm.stopPrank();

        // Verify each user received *exactly* their pro-rata share (after withdraw)
        assertApproxEqAbs(
            fragBoxBetting.getUsdc().balanceOf(USER),
            data.user1BalanceBefore - data.betWin1 + data.expectedUser1,
            2,
            "USER net payout incorrect (winning + optional losing excess)"
        );
        assertApproxEqAbs(
            fragBoxBetting.getUsdc().balanceOf(USER2),
            data.user2BalanceBefore - data.betWin2 + data.expectedUser2,
            2,
            "USER2 net payout incorrect (winning + optional losing excess)"
        );
        assertApproxEqAbs(
            fragBoxBetting.getUsdc().balanceOf(USER3),
            data.user3BalanceBefore - data.betLose1 + data.expectedUser3,
            2,
            "USER3 net payout incorrect (winning + optional losing excess)"
        );
        assertApproxEqAbs(
            fragBoxBetting.getUsdc().balanceOf(USER4),
            data.user4BalanceBefore - data.betLose2 + data.expectedUser4,
            2,
            "USER4 net payout incorrect (winning + optional losing excess)"
        );

        // SYMMETRY + DUST INVARIANT
        // Contract must hold *only* the rounding dust swept to ownerFeesCollected.
        // All bets (totalWin + totalLose) minus dust = everything paid to players.
        vm.startPrank(fragBoxBetting.owner());
        assertApproxEqAbs(
            fragBoxBetting.getUsdc().balanceOf(address(fragBoxBetting)),
            fragBoxBetting.getOwnerFeesCollected(),
            2,
            "Contract balance must equal collected owner fees + negligible flooring dust"
        );
        vm.stopPrank();
    }

    struct BetTestData {
        uint256 betWin1;
        uint256 betWin2;
        uint256 betLose1;
        uint256 betLose2;

        uint256 betWin1WithFee;
        uint256 betWin2WithFee;
        uint256 betLose1WithFee;
        uint256 betLose2WithFee;

        uint256 user1BalanceBefore;
        uint256 user2BalanceBefore;
        uint256 user3BalanceBefore;
        uint256 user4BalanceBefore;

        uint256 totalWin;
        uint256 totalLose;
        uint256 minBet;

        uint256 expectedUser1;
        uint256 expectedUser2;
        uint256 expectedUser3;
        uint256 expectedUser4;
    }

    function getRandomBets(uint256 betWin1, uint256 betWin2, uint256 betLose1, uint256 betLose2)
        internal
        view
        returns (BetTestData memory data)
    {
        data.betWin1 = bound(betWin1, MIN_SEND_VALUE, MAX_SEND_VALUE);
        data.betWin2 = bound(betWin2, MIN_SEND_VALUE, MAX_SEND_VALUE);
        data.betLose1 = bound(betLose1, MIN_SEND_VALUE, MAX_SEND_VALUE);
        data.betLose2 = bound(betLose2, MIN_SEND_VALUE, MAX_SEND_VALUE);

        uint256 betWin1Fee = fragBoxBetting.calculateDepositFee(data.betWin1);
        uint256 betWin2Fee = fragBoxBetting.calculateDepositFee(data.betWin2);
        uint256 betLose1Fee = fragBoxBetting.calculateDepositFee(data.betLose1);
        uint256 betLose2Fee = fragBoxBetting.calculateDepositFee(data.betLose2);

        data.betWin1WithFee = data.betWin1 - betWin1Fee;
        data.betWin2WithFee = data.betWin2 - betWin2Fee;
        data.betLose1WithFee = data.betLose1 - betLose1Fee;
        data.betLose2WithFee = data.betLose2 - betLose2Fee;

        data.totalWin = data.betWin1WithFee + data.betWin2WithFee;
        data.totalLose = data.betLose1WithFee + data.betLose2WithFee;
        data.minBet = Math.min(data.totalWin, data.totalLose);

        uint256 expectedUser1 = 0;
        uint256 expectedUser2 = 0;
        uint256 expectedUser3 = 0;
        uint256 expectedUser4 = 0;

        // Winning bets (Faction1) — always get 2 * minBet pro-rata + excess refund if winners overbet
        if (data.totalWin > 0) {
            uint256 baseWin1 = (data.betWin1WithFee * 2 * data.minBet) / data.totalWin;
            uint256 baseWin2 = (data.betWin2WithFee * 2 * data.minBet) / data.totalWin;

            expectedUser1 += baseWin1;
            expectedUser2 += baseWin2;

            if (data.totalWin > data.totalLose) {
                uint256 excess = data.totalWin - data.minBet;
                expectedUser1 += (data.betWin1WithFee * excess) / data.totalWin;
                expectedUser2 += (data.betWin2WithFee * excess) / data.totalWin;
            }
        }

        // Losing bets excess refund (only if losers overbet)
        if (data.totalLose > data.totalWin && data.totalLose > 0) {
            uint256 excess = data.totalLose - data.minBet;
            expectedUser3 += (data.betLose1WithFee * excess) / data.totalLose;
            expectedUser4 += (data.betLose2WithFee * excess) / data.totalLose;
        }

        data.expectedUser1 = expectedUser1;
        data.expectedUser2 = expectedUser2;
        data.expectedUser3 = expectedUser3;
        data.expectedUser4 = expectedUser4;

        data.user1BalanceBefore = fragBoxBetting.getUsdc().balanceOf(USER);
        data.user2BalanceBefore = fragBoxBetting.getUsdc().balanceOf(USER2);
        data.user3BalanceBefore = fragBoxBetting.getUsdc().balanceOf(USER3);
        data.user4BalanceBefore = fragBoxBetting.getUsdc().balanceOf(USER4);

        return data;
    }
}
