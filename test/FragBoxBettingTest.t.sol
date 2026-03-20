// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";

contract FragBoxBettingTest is Test {
    FragBoxBetting fragBoxBetting;

    address public USER = makeAddr("user");
    uint256 constant SEND_VALUE = 0.1 ether;
    uint256 constant STARTING_BALANCE = 10 ether;

    string constant MATCHID = "1-d031ff3b-8654-4922-9f90-0bc538e3d6e4";
    string constant PLAYERID = "415c58c9-81cd-435a-be65-fff9d891483b";
    string constant FACTION = "faction1";

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        fragBoxBetting = deployFragBoxBetting.run();
        vm.deal(USER, STARTING_BALANCE);
    }

    function testPlaceBetWithNoBalance() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__BetTooSmall.selector, 0));
        fragBoxBetting.deposit(MATCHID, PLAYERID, FACTION);
        vm.stopPrank();
    }

    function testPlaceBet() public {
        vm.startPrank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__MatchNotReady.selector);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, PLAYERID, FACTION);
        vm.stopPrank();
    }
}
