// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {FragBoxBetting} from "../../src/FragBoxBetting.sol";

contract FragBoxHandler is CommonBase, StdCheats, Test {
    FragBoxBetting public betting;

    address[] public actors;
    string constant MATCH_ID = "1-a536dd90-4df3-42df-be6e-d158177fdef2";
    string constant PLAYER_WIN = "94f98244-169d-478a-a5dd-21dde2e649ca";
    string constant PLAYER_LOSE = "92f1450e-182b-41db-8f31-53079df20c73";

    string[3] public factions = ["faction1", "faction2", "draw"];

    // Ghost variables for powerful invariants
    uint256 public ghost_totalDeposited;

    constructor(FragBoxBetting _betting) {
        betting = _betting;

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("charlie"));
        actors.push(makeAddr("dave"));

        // Fund actors
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 50 ether);
        }
    }

    // ============== FUZZABLE ACTIONS ==============

    function deposit(uint256 actorIdx, uint256 factionIdx, uint256 amount) public {
        address actor = actors[bound(actorIdx, 0, actors.length - 1)];
        string memory factionStr = factions[bound(factionIdx, 0, 2)];
        string memory playerId = factionIdx % 2 == 0 ? PLAYER_WIN : PLAYER_LOSE;

        amount = bound(amount, 0.01 ether, 3 ether); // above min bet

        vm.prank(actor);
        betting.deposit{value: amount}(MATCH_ID, playerId, factionStr);

        ghost_totalDeposited += amount;
    }

    function updateMatchStatus(uint256 /*actorIdx*/) public {
        vm.prank(actors[0]);
        betting.updateMatchStatus(MATCH_ID);
    }

    function claim(uint256 actorIdx) public {
        address actor = actors[bound(actorIdx, 0, actors.length - 1)];
        vm.prank(actor);
        betting.claim(MATCH_ID);
    }

    function emergencyRefund(uint256 /*actorIdx*/) public {
        vm.warp(block.timestamp + 25 hours);
        vm.prank(actors[0]);
        betting.emergencyRefund(MATCH_ID);
    }

    function withdrawWinnings(uint256 actorIdx) public {
        address actor = actors[bound(actorIdx, 0, actors.length - 1)];
        string memory playerId = (actorIdx % 2 == 0) ? PLAYER_WIN : PLAYER_LOSE;
        vm.prank(actor);
        betting.withdraw(playerId); // your contract has this
    }
}