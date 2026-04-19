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

    function _toDynamic(string[2] memory arr) private pure returns (string[] memory) {
        string[] memory dyn = new string[](2);
        for (uint256 i = 0; i < 2; i++) {
            dyn[i] = arr[i];
        }
        return dyn;
    }

    function _toDynamic(string[3] memory arr) private pure returns (string[] memory) {
        string[] memory dyn = new string[](3);
        for (uint256 i = 0; i < 3; i++) {
            dyn[i] = arr[i];
        }
        return dyn;
    }

    string private constant MY_PLAYER_ID = "415c58c9-81cd-435a-be65-fff9d891483b";

    function run() external {
        // ====================== CONFIG ======================
        FragBoxBetting betting = FragBoxBetting(address(0x9f232D0015FAe832E6FC23566dc31B1f797788bb));
        IERC20 usdc = IERC20(betting.getUsdc());

        // matches.push(
        //     MatchInfo({
        //         matchId: "1-80221dfd-646f-49ae-97fa-78f73ffc71e4",
        //         faction1Players: _toDynamic(
        //             ["308f48cc-f295-4a81-ab7a-bb0d87f1aa13", "24ea90e6-8f99-43a0-b209-17aa01a4facd"]
        //         ),
        //         faction2Players: _toDynamic(
        //             [
        //                 "a53eb25c-a4b6-4400-9b91-4cea9634bc4a",
        //                 "c6649075-a591-4a3d-8bde-22e59e3e637f",
        //                 "25518de8-4f33-4b23-856f-cad03c72df0f"
        //             ]
        //         )
        //     })
        // );

        matches.push(
            MatchInfo({
                matchId: "1-660accbe-46da-4d22-8c2e-c7d2ac585c22",
                faction1Players: _toDynamic(
                    ["d54f9694-1e25-4241-ac0e-3467c5b2aa87", "24ea90e6-8f99-43a0-b209-17aa01a4facd"]
                ),
                faction2Players: _toDynamic(
                    [
                        "3f73761a-6f93-46e4-a944-94be58dc1bd3",
                        "faea4e59-670b-4663-960d-2bb2734c552d",
                        "fd28d84e-6f61-4f77-ba44-9cc4de25e220"
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
