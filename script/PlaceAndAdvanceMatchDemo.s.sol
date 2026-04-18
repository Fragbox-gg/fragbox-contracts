// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PlaceAndAdvanceMatchDemo is Script {
    function run() external {
        // ====================== CONFIG ======================
        // Replace these or pull from env if you prefer
        address BETTING_CONTRACT = 0x9f232D0015FAe832E6FC23566dc31B1f797788bb;

        string memory MATCH_ID = "1-80221dfd-646f-49ae-97fa-78f73ffc71e4";
        uint8 TIER_ID = 1; // default tier

        // ====================== PLAYER IDS & BETS ======================
        // Fill these arrays yourself (real Faceit player IDs from the match)
        string[] memory team1Players = new string[](2); // Faction1
        team1Players[0] = "415c58c9-81cd-435a-be65-fff9d891483b"; // your player ID
        team1Players[1] = "OTHER_REAL_PLAYER_ID_FROM_MATCH_1"; // add more

        uint256[] memory team1Bets = new uint256[](2); // 6 decimals (e.g. 25 USDC = 25_000_000)
        team1Bets[0] = 25_000_000;
        team1Bets[1] = 15_000_000;

        string[] memory team2Players = new string[](2); // Faction2
        team2Players[0] = "OTHER_REAL_PLAYER_ID_FROM_MATCH_2";
        team2Players[1] = "OTHER_REAL_PLAYER_ID_FROM_MATCH_3";

        uint256[] memory team2Bets = new uint256[](2);
        team2Bets[0] = 20_000_000;
        team2Bets[1] = 10_000_000;
        // =====================================================

        FragBoxBetting betting = FragBoxBetting(BETTING_CONTRACT);
        IERC20 usdc = IERC20(betting.getUsdc());

        uint256 ownerPk = vm.envUint("PRIVATE_KEY_OWNER");
        uint256 playerPk = vm.envUint("PRIVATE_KEY_PLAYER");
        address playerWallet = vm.addr(playerPk);

        // 1. OWNER: Register all player IDs to the same player wallet (works perfectly)
        vm.startBroadcast(ownerPk);
        for (uint256 i = 0; i < team1Players.length; i++) {
            betting.registerPlayerWallet(team1Players[i], playerWallet);
            console.log("Registered (team1):", team1Players[i]);
        }
        for (uint256 i = 0; i < team2Players.length; i++) {
            betting.registerPlayerWallet(team2Players[i], playerWallet);
            console.log("Registered (team2):", team2Players[i]);
        }
        vm.stopBroadcast();

        // 2. PLAYER: Approve + place bets on both sides
        vm.startBroadcast(playerPk);
        // Approve once for total amount
        uint256 totalBet = 0;
        for (uint256 i = 0; i < team1Bets.length; i++) {
            totalBet += team1Bets[i];
        }
        for (uint256 i = 0; i < team2Bets.length; i++) {
            totalBet += team2Bets[i];
        }
        usdc.approve(address(betting), totalBet);

        // Team 1 bets
        for (uint256 i = 0; i < team1Players.length; i++) {
            betting.deposit(MATCH_ID, team1Players[i], team1Bets[i], TIER_ID);
            console.log("Bet placed (team1):", team1Players[i], team1Bets[i]);
        }
        // Team 2 bets
        for (uint256 i = 0; i < team2Players.length; i++) {
            betting.deposit(MATCH_ID, team2Players[i], team2Bets[i], TIER_ID);
            console.log("Bet placed (team2):", team2Players[i], team2Bets[i]);
        }
        vm.stopBroadcast();

        // 3. OWNER: Update rosters + set initial status to Ready
        vm.startBroadcast(ownerPk);
        // Team 1 → Faction1
        for (uint256 i = 0; i < team1Players.length; i++) {
            betting.updateMatchRoster(MATCH_ID, team1Players[i], playerWallet, FragBoxBetting.Faction.Faction1);
        }
        // Team 2 → Faction2
        for (uint256 i = 0; i < team2Players.length; i++) {
            betting.updateMatchRoster(MATCH_ID, team2Players[i], playerWallet, FragBoxBetting.Faction.Faction2);
        }

        // First status MUST be Ready or Voting (otherwise Invalid)
        betting.updateMatchStatus(MATCH_ID, FragBoxBetting.MatchStatus.Ready);
        console.log("Match set to Ready. Cron job will now finish it.");
        vm.stopBroadcast();
    }
}
