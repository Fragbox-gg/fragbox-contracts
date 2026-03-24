// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {ETHReceiver} from "./mocks/ETHReceiver.sol";

contract FragBoxBettingFuzzTest is Test {
    FragBoxBetting fragBoxBetting;
    address chainLinkFunctionsRouter;

    address public USER;
    ETHReceiver public receiver;
    uint256 constant SEND_VALUE = 0.1 ether;
    uint256 constant STARTING_BALANCE = 10 ether;

    string constant MATCHID = "1-a536dd90-4df3-42df-be6e-d158177fdef2";
    string constant WINNING_PLAYERID = "94f98244-169d-478a-a5dd-21dde2e649ca";
    string constant WINNING_FACTION = "faction1";
    FragBoxBetting.Faction constant WINNING_FACTION_ENUM = FragBoxBetting.Faction.Faction1;

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        (fragBoxBetting, chainLinkFunctionsRouter) = deployFragBoxBetting.run();

        receiver = new ETHReceiver();
        USER = address(receiver);
        vm.deal(USER, STARTING_BALANCE);
    }

    function testFuzz_DepositAndTopUp(uint256 bet1, uint256 bet2) public {
        bet1 = bound(bet1, 0.01 ether, 1.2 ether);
        bet2 = bound(bet2, 0.01 ether, 1.2 ether);

        // (your existing mock setup for roster + status would go here)
        vm.prank(USER);
        fragBoxBetting.deposit{value: bet1}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        vm.prank(USER);
        fragBoxBetting.deposit{value: bet2}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);

        FragBoxBetting.MatchBetView memory vw = fragBoxBetting.getMatchBet(fragBoxBetting.getMatchKey(MATCHID));
        uint256 bet1Fee = fragBoxBetting.calculateDepositFee(bet1);
        uint256 bet2Fee = fragBoxBetting.calculateDepositFee(bet2);
        uint256 betSum = (bet1 - bet1Fee) + (bet2 - bet2Fee);
        assertEq(vw.totalBetAmount, betSum); // after 1% fee
    }
}