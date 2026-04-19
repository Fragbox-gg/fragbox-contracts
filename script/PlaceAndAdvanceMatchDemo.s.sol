// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PlaceBetsAndAdvanceMatchDemo is Script {
    uint256 private constant BET_AMOUNT = 5_000_000; // 5 USDC
    uint8 private constant TIER_ID = 1;

    struct MatchInfo {
        string matchId;
        string[] faction1Players;
        string[] faction2Players;
    }

    MatchInfo[] private matches;

    function _toDynamic(string[5] memory arr) private pure returns (string[] memory) {
        string[] memory dyn = new string[](5);
        for (uint256 i = 0; i < 5; i++) {
            dyn[i] = arr[i];
        }
        return dyn;
    }

    function _toDynamic(string[4] memory arr) private pure returns (string[] memory) {
        string[] memory dyn = new string[](4);
        for (uint256 i = 0; i < 4; i++) {
            dyn[i] = arr[i];
        }
        return dyn;
    }

    string private constant MY_PLAYER_ID = "415c58c9-81cd-435a-be65-fff9d891483b";

    function run() external {
        // ====================== CONFIG ======================
        FragBoxBetting betting = FragBoxBetting(address(0x9f232D0015FAe832E6FC23566dc31B1f797788bb));
        IERC20 usdc = IERC20(betting.getUsdc());

        matches.push(
            MatchInfo({
                matchId: "1-206359b8-22c5-426a-afe9-80ef6b3ae879",
                faction1Players: _toDynamic(
                    [
                        "291e4082-5f46-46f6-b424-a63d9b8bdee9",
                        "6f45ca65-f974-4fee-a1ed-52a958e497b5",
                        "5d44f998-ef1f-4190-93fa-56ebfaa044c6",
                        "64961595-7282-41bf-8e32-29b717e854a7",
                        "1d529d28-a1b5-41e5-8027-dedba2ee7d63"
                    ]
                ),
                faction2Players: _toDynamic(
                    [
                        "24ea90e6-8f99-43a0-b209-17aa01a4facd",
                        "d54f9694-1e25-4241-ac0e-3467c5b2aa87",
                        "e58e3931-29f4-4640-8bfd-8dbdc4ec7886",
                        "ac3f355a-3220-4def-b954-6467a8af57f9"
                    ]
                )
            })
        );

        // Approve USDC once
        usdc.approve(address(betting), type(uint256).max);

        for (uint256 j = 0; j < matches.length; j++) {
            string memory matchId = matches[j].matchId;

            string[] memory team1Players = matches[j].faction1Players;
            string[] memory team2Players = matches[j].faction2Players;

            vm.startBroadcast();

            // 1. Register every player ID to your MetaMask wallet and place bets on both sides
            for (uint256 i = 0; i < team1Players.length; i++) {
                betting.registerPlayerWallet(team1Players[i], msg.sender);
                console.log("Registered (team1):", team1Players[i]);

                betting.deposit(matchId, team1Players[i], BET_AMOUNT, TIER_ID);
                console.log("Bet placed (team1):", team1Players[i], BET_AMOUNT / 1e6, "USDC");
            }
            for (uint256 i = 0; i < team2Players.length; i++) {
                betting.registerPlayerWallet(team2Players[i], msg.sender);
                console.log("Registered (team2):", team2Players[i]);

                betting.deposit(matchId, team2Players[i], BET_AMOUNT, TIER_ID);
                console.log("Bet placed (team2):", team2Players[i], BET_AMOUNT / 1e6, "USDC");
            }

            // 2. Update rosters (owner only)
            // for (uint256 i = 0; i < team1Players.length; i++) {
            //     betting.updateMatchRoster(matchId, team1Players[i], msg.sender, FragBoxBetting.Faction.Faction1);
            // }
            // for (uint256 i = 0; i < team2Players.length; i++) {
            //     betting.updateMatchRoster(matchId, team2Players[i], msg.sender, FragBoxBetting.Faction.Faction2);
            // }

            // 3. First status MUST be Ready or Voting (owner only)
            betting.updateMatchStatus(matchId, FragBoxBetting.MatchStatus.Ready);
            console.log("Match set to Ready -> cron job will finish it in ~6 min");
            console.log("Match ID:", matchId);

            // 4. transfer ownership back to the CDP server wallet that our cron job/web server uses
            betting.transferOwnership(address(0x1fEb79756f4497b07a2059FE6AAF59fA67fb68D1));

            vm.stopBroadcast();
        }
    }
}
