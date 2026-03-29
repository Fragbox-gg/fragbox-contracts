// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ETHReceiver} from "./mocks/ETHReceiver.sol";
import {SimulateFunctionsOracle} from "./SimulateOracles.t.sol";

contract FragBoxBettingTest is SimulateFunctionsOracle {
    FragBoxBetting fragBoxBetting;
    address chainLinkFunctionsRouter;

    address public USER;
    ETHReceiver public receiver;
    uint256 constant SEND_VALUE = 0.1 ether;
    uint256 constant STARTING_BALANCE = 10 ether;

    FragBoxBetting.Faction constant WINNING_FACTION = FragBoxBetting.Faction.Faction1;

    event RosterUpdated(bytes32 indexed matchKey, bytes32 playerId, FragBoxBetting.Faction playerFaction);
    event RequestFulfilled(
        bytes32 indexed requestId,
        bytes32 indexed matchKey,
        FragBoxBetting.MatchStatus status,
        FragBoxBetting.Faction winnerFaction
    );
    event RequestError(bytes32 indexed requestId, bytes32 indexed matchKey, string error);

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        (fragBoxBetting, chainLinkFunctionsRouter) = deployFragBoxBetting.run();

        receiver = new ETHReceiver();
        USER = address(receiver);
        vm.deal(USER, STARTING_BALANCE);

        super.setUpSimulation(chainLinkFunctionsRouter, fragBoxBetting);
    }

    /* -------------------------------------------------------------------------- */
    /*                            INTERNAL TEST HELPERS                           */
    /* -------------------------------------------------------------------------- */
    enum EventLogLevel {
        None, // 0 - Log nothing
        NamesOnly, // 1 - Just event names
        WithIndexed, // 2 - Event names + indexed parameters
        Full // 3 - Everything (default)
    }

    /// @notice Change this constant to set default verbosity for all tests
    EventLogLevel internal constant LOG_LEVEL = EventLogLevel.NamesOnly;

    /// @notice Uses the global LOG_LEVEL constant
    function printDecodedEvents() internal view {
        printDecodedEvents(LOG_LEVEL);
    }

    /// @notice Override level for a single call
    function printDecodedEvents(EventLogLevel level) internal view {
        if (level == EventLogLevel.None) return;

        Vm.Log[] memory logs = vm.getRecordedLogs();

        console.log("\n=== DECODED EVENTS ===");
        console.log("Total events:", logs.length, "- Level:", uint8(level));

        if (logs.length == 0) {
            console.log("(No events emitted)");
            return;
        }

        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            bytes32 sig = log.topics[0];

            console.log("\n--- Event #", i, "---");
            if (level > EventLogLevel.NamesOnly) {
                console.log("Emitter:", log.emitter);
            }

            if (sig == BET_PLACED_SIG) _printBetPlaced(log, level);
            else if (sig == REQUEST_FULFILLED_SIG) _printRequestFulfilled(log, level);
            else if (sig == EMERGENCY_REFUND_SIG) _printEmergencyRefund(log, level);
            else if (sig == MATCH_CLAIMED_SIG) _printMatchClaimed(log, level);
            else if (sig == ROSTER_UPDATED_SIG) _printRosterUpdated(log, level);
            else _printUnknownEvent(log, level);
        }
    }

    /* ----------------------------- TOPIC DECODERS ----------------------------- */
    function topicToAddress(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    function topicToUint256(bytes32 topic) internal pure returns (uint256) {
        return uint256(topic);
    }

    function topicToBytes32(bytes32 topic) internal pure returns (bytes32) {
        return topic;
    }

    /* -------------------------- YOUR EVENT SIGNATURES ------------------------- */
    bytes32 internal constant BET_PLACED_SIG = keccak256("BetPlaced(bytes32,address,uint256,string)");
    bytes32 internal constant REQUEST_FULFILLED_SIG = keccak256("RequestFulfilled(bytes32,bytes32,string,string)");
    bytes32 internal constant EMERGENCY_REFUND_SIG = keccak256("EmergencyRefund(bytes32)");
    bytes32 internal constant MATCH_CLAIMED_SIG = keccak256("MatchClaimed(bytes32)");
    bytes32 internal constant ROSTER_UPDATED_SIG = keccak256("RosterUpdated(bytes32,string,uint8)");

    /* ----------------------------- EVENT DECODERS ----------------------------- */
    function _printBetPlaced(Vm.Log memory log, EventLogLevel level) private pure {
        console.log("-> BetPlaced");
        if (level == EventLogLevel.NamesOnly) return;

        console.log("  MatchKey :");
        console.logBytes32(log.topics[1]);
        console.log("  Better   :", topicToAddress(log.topics[2]));

        if (level == EventLogLevel.WithIndexed) return;

        (uint256 amount, uint8 faction, string memory playerId) = abi.decode(log.data, (uint256, uint8, string));
        console.log("  Amount   :", amount);
        console.log("  Faction  :", faction);
        console.log("  PlayerId :", playerId);
    }

    function _printRequestFulfilled(Vm.Log memory log, EventLogLevel level) private pure {
        console.log("-> RequestFulfilled");
        if (level == EventLogLevel.NamesOnly) return;

        console.log("  RequestId:");
        console.logBytes32(log.topics[1]);
        console.log("  MatchKey :");
        console.logBytes32(log.topics[2]);

        if (level == EventLogLevel.WithIndexed) return;

        (string memory status, string memory winnerFaction) = abi.decode(log.data, (string, string));
        console.log("  Status        :", status);
        console.log("  WinnerFaction :", winnerFaction);
    }

    function _printEmergencyRefund(Vm.Log memory log, EventLogLevel level) private pure {
        console.log("-> EmergencyRefund");
        if (level == EventLogLevel.NamesOnly) return;
        console.log("  MatchKey :");
        console.logBytes32(log.topics[1]);
    }

    function _printMatchClaimed(Vm.Log memory log, EventLogLevel level) private pure {
        console.log("-> MatchClaimed");
        if (level == EventLogLevel.NamesOnly) return;
        console.log("  MatchKey :");
        console.logBytes32(log.topics[1]);
    }

    function _printRosterUpdated(Vm.Log memory log, EventLogLevel level) private pure {
        console.log("-> RosterUpdated");
        if (level == EventLogLevel.NamesOnly) return;

        console.log("  MatchKey    :");
        console.logBytes32(log.topics[1]);

        if (level == EventLogLevel.WithIndexed) return;

        uint256 playerCount = abi.decode(log.data, (uint256));
        console.log("  PlayerCount :", playerCount);
    }

    function _printUnknownEvent(Vm.Log memory log, EventLogLevel level) private pure {
        console.log("-> Unknown Event");
        if (level == EventLogLevel.NamesOnly) return;

        for (uint256 j = 1; j < log.topics.length; ++j) {
            console.log("  Topic", j, ":");
            console.logBytes32(log.topics[j]);
        }
        if (level == EventLogLevel.Full && log.data.length > 0) {
            console.log("  Data (raw):");
            console.logBytes(log.data);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                                DEPOSIT TESTS                               */
    /* -------------------------------------------------------------------------- */
    function testPlaceBetWithNoBalance() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__BetTooSmall.selector, 0));
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID);
        vm.stopPrank();
    }

    function testPlaceBet() public {
        vm.startPrank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        vm.stopPrank();
    }

    function testPausableDeposit() public {
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.pause();

        vm.prank(USER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.unpause();

        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
    }

    function testDepositEnforcesMinBetUSD() public {
        uint256 tooSmallEth = 0.0001 ether; // ~$3 at $3000/ETH
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__BetTooSmall.selector, tooSmallEth));
        fragBoxBetting.deposit{value: tooSmallEth}(MATCHID, WINNING_PLAYERID);
    }

    /* -------------------------------------------------------------------------- */
    /*                    CHAINLINK FUNCTIONS INTEGRATION TESTS                   */
    /* -------------------------------------------------------------------------- */
    function test_FulfillRosterUpdate_Success() public {
        bytes32 matchKey = fragBoxBetting.getKey(MATCHID);

        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = super._captureRequestId();

        bytes memory response = bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER);

        vm.expectEmit(true, true, true, false);
        emit RosterUpdated(matchKey, fragBoxBetting.getKey(WINNING_PLAYERID), WINNING_FACTION);

        super._simulateFulfill(requestId, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assertTrue(
            fragBoxBetting.getPlayerFaction(matchKey, fragBoxBetting.getKey(WINNING_PLAYERID))
                == FragBoxBetting.Faction.Faction1
        );
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Unknown);
        assertEq(mb.lastStatusUpdate, 0);
    }

    function test_FulfillStatusUpdate_Ongoing() public {
        bytes32 matchKey = fragBoxBetting.getKey(MATCHID);

        // 1. Roster first
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 rosterReq = super._captureRequestId();
        super._simulateFulfill(rosterReq, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        vm.warp(block.timestamp + 6 minutes);

        // 2. Status update
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = super._captureRequestId();

        bytes memory response = bytes(PROCESSED_STATUS_ONGOING);
        super._simulateFulfill(statusReq, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Ongoing);
    }

    function test_FulfillStatusUpdate_Finished_SetsWinnerAndResolved() public {
        bytes32 matchKey = fragBoxBetting.getKey(MATCHID);

        // Roster first
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 rosterReq = super._captureRequestId();
        super._simulateFulfill(rosterReq, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        // Finished status (uses "faction2" from your real JSON)
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = super._captureRequestId();

        bytes memory response = bytes(PROCESSED_STATUS_FINISHED);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, FragBoxBetting.MatchStatus.Finished, FragBoxBetting.Faction.Faction1);

        super._simulateFulfill(statusReq, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Finished);
        assertEq(uint256(mb.winnerFaction), uint256(FragBoxBetting.Faction.Faction1));
    }

    function test_FulfillRequest_ErrorPath_FromOracle() public {
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = super._captureRequestId();

        bytes memory err = bytes("Faceit API error");

        vm.expectEmit(true, true, true, true);
        emit RequestError(requestId, fragBoxBetting.getKey(MATCHID), "Faceit API error");

        super._simulateFulfill(requestId, string(""), err);
    }

    function test_FulfillRequest_InvalidRequestId_DoesNotCorruptOtherMatches() public {
        bytes32 fakeRequestId = keccak256("fake");
        super._simulateFulfill(fakeRequestId, bytes(PROCESSED_STATUS_ONGOING), "");
        // No state change, no revert — exactly as intended
    }

    function test_DepositAfterRosterValidated_Succeeds() public {
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = super._captureRequestId();
        super._simulateFulfill(requestId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        vm.startPrank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        vm.stopPrank();

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(fragBoxBetting.getKey(MATCHID));
        assertGt(mb.totalBetAmount, 0);
    }

    function testEmergencyRefundAfterTimeout() public {
        uint256 balBefore = USER.balance;

        // deposit, advance time >24h, call emergencyRefund
        vm.startPrank(USER);
        super._startRequestCapture();
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 rosterId = super._captureRequestId();
        vm.stopPrank();
        // Validate roster
        super._simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusId = super._captureRequestId();
        super._simulateFulfill(statusId, bytes(PROCESSED_STATUS_ONGOING), "");

        vm.prank(fragBoxBetting.owner());
        vm.expectRevert(FragBoxBetting.FragBoxBetting__StatusUpdateTooSoon.selector);
        fragBoxBetting.updateMatchStatus(MATCHID);

        vm.startPrank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__TimeoutNotReached.selector);
        fragBoxBetting.emergencyRefund(MATCHID, WINNING_PLAYERID);
        vm.warp(block.timestamp + 25 hours);
        fragBoxBetting.emergencyRefund(MATCHID, WINNING_PLAYERID);

        // then player calls withdraw() and gets full amount back
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();
        assertEq(USER.balance, balBefore - fee);
    }

    function testNoOneBetOnWinner_AllRefunded() public {
        uint256 balBefore = USER.balance;

        bytes32 matchKey = fragBoxBetting.getKey(MATCHID);

        // deposit only on losing faction
        vm.startPrank(USER);
        super._startRequestCapture();
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, LOSING_PLAYERID);
        bytes32 rosterId = super._captureRequestId();
        vm.stopPrank();
        // fulfill status with winner = other faction
        super._simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_LOSING_PLAYER), "");

        vm.warp(block.timestamp + 6 minutes);

        vm.startPrank(fragBoxBetting.owner());
        super._startRequestCapture();
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = super._captureRequestId();
        vm.stopPrank();

        bytes memory response = bytes(PROCESSED_STATUS_FINISHED);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, FragBoxBetting.MatchStatus.Finished, FragBoxBetting.Faction.Faction1);

        super._simulateFulfill(statusReq, response, "");

        // claim() should refund everyone via playerToWinnings
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);

        // withdraw succeeds
        fragBoxBetting.withdraw(LOSING_PLAYERID);
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        vm.stopPrank();
        assertEq(USER.balance, balBefore - fee);
    }

    function testClaimWithDrawWinnerRefundsAll() public {
        uint256 startingBalance = USER.balance;

        // deposit some on Draw
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 rosterReq = super._captureRequestId();
        super._simulateFulfill(rosterReq, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        // fulfill status with "draw"
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = super._captureRequestId();
        super._simulateFulfill(statusReq, bytes(PROCESSED_STATUS_FINISHED_DRAW), "");

        // claim
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        // assert full refund to winnings (or fix this behavior if not intended)
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        assertEq(USER.balance, startingBalance - fee);
    }

    /* -------------------------------------------------------------------------- */
    /*                                TEST GETTERS                                */
    /* -------------------------------------------------------------------------- */
    function testGetEthUsdPrice() public view {
        fragBoxBetting.getEthUsdPrice();
    }

    function testGetUsdValueOfEth() public view {
        assertEq(uint256(fragBoxBetting.getEthUsdPrice()), fragBoxBetting.getUsdValueOfEth(1e18));
    }

    function testgetKey() public view {
        fragBoxBetting.getKey(MATCHID);
    }

    function testGetMatchBet() public view {
        fragBoxBetting.getMatchBet(fragBoxBetting.getKey(MATCHID));
    }

    function testGetPlayerFaction() public view {
        fragBoxBetting.getPlayerFaction(fragBoxBetting.getKey(MATCHID), fragBoxBetting.getKey(WINNING_PLAYERID));
    }

    function testGetOwnerFees() public {
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.getOwnerFees();

        vm.expectRevert();
        vm.prank(USER);
        fragBoxBetting.getOwnerFees();
    }

    function testCalculateDepositFee() public view {
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        assertEq(
            SEND_VALUE - fee,
            SEND_VALUE - (SEND_VALUE * fragBoxBetting.getHouseFeePercentage()) / fragBoxBetting.getPercentageBase()
        );
    }

    function testGetMinBetAmountInUsd() public view {
        fragBoxBetting.getMinBetAmountInUsd();
    }

    function testGetMaxBetAmountInUsd() public view {
        fragBoxBetting.getMaxBetAmountInUsd();
    }

    function testGetPaused() public view {
        fragBoxBetting.paused();
    }
}
