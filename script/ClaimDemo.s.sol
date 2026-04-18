// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";

contract ClaimDemo is Script {
    function run() external {
        address BETTING_CONTRACT = 0x9f232D0015FAe832E6FC23566dc31B1f797788bb;
        string memory MATCH_ID = "1-80221dfd-646f-49ae-97fa-78f73ffc71e4";

        FragBoxBetting betting = FragBoxBetting(BETTING_CONTRACT);
        uint256 playerPk = vm.envUint("PRIVATE_KEY_PLAYER");

        vm.startBroadcast(playerPk);

        // Claim for every player ID you bet with
        string[] memory myPlayerIds = new string[](4); // add all your player IDs here
        // myPlayerIds[0] = "415c58c9-81cd-435a-be65-fff9d891483b";
        // ... etc

        for (uint256 i = 0; i < myPlayerIds.length; i++) {
            try betting.claim(MATCH_ID, myPlayerIds[i]) {
                console.log("Claimed for:", myPlayerIds[i]);
            } catch {
                console.log("No winnings / already claimed for:", myPlayerIds[i]);
            }
            betting.withdraw(myPlayerIds[i]);
            console.log("Withdrawn for:", myPlayerIds[i]);
        }

        vm.stopBroadcast();
    }
}
