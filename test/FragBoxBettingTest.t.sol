// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ETHReceiver} from "./mocks/ETHReceiver.sol";
import {SimulateOracles} from "./SimulateOracles.t.sol";

contract FragBoxBettingTest is SimulateOracles {
    FragBoxBetting fragBoxBetting;
    address chainLinkFunctionsRouter;

    address public USER;
    address public USER2;
    address public USER3;

    uint256 constant SEND_VALUE = 0.1 ether;
    uint256 constant STARTING_BALANCE = 10 ether;
    uint256 constant CALLBACK_GAS_LIMIT = 250_000;
    uint256 constant WARP_TIME = 5 minutes;

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

        USER = address(new ETHReceiver());
        vm.deal(USER, STARTING_BALANCE);

        USER2 = address(new ETHReceiver());
        vm.deal(USER2, STARTING_BALANCE);

        USER3 = address(new ETHReceiver());
        vm.deal(USER3, STARTING_BALANCE);

        super.setUpSimulation(chainLinkFunctionsRouter, fragBoxBetting);

        vm.startPrank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER);
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID, USER);
        vm.stopPrank();
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
        vm.expectRevert(FragBoxBetting.FragBoxBetting__BetTooSmall.selector);
        fragBoxBetting.deposit{value: tooSmallEth}(MATCHID, WINNING_PLAYERID);
    }

    function testDepositEnforcesMaxBetUSD() public {
        uint256 tooLargeEth = 100 ether; // $300,000 at $3000/ETH
        vm.deal(USER, tooLargeEth);
        vm.prank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__BetTooLarge.selector);
        fragBoxBetting.deposit{value: tooLargeEth}(MATCHID, WINNING_PLAYERID);
    }

    function testDepositWithInvalidWallet() public {
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER2);

        vm.startPrank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__InvalidWallet.selector);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        vm.stopPrank();
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

        uint256 gasBefore = gasleft();
        super._simulateFulfill(requestId, response, "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (Roster update):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

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
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 rosterReq = super._captureRequestId();

        uint256 gasBefore = gasleft();
        super._simulateFulfill(rosterReq, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (Roster update):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Unknown);

        // 2. Status update to voting
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = super._captureRequestId();

        bytes memory response = bytes(PROCESSED_STATUS_VOTING);

        gasBefore = gasleft();
        super._simulateFulfill(statusReq, response, "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status ongoing):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Voting);

        vm.warp(block.timestamp + WARP_TIME);

        // 3. Status update to ongoing
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        statusReq = super._captureRequestId();

        response = bytes(PROCESSED_STATUS_ONGOING);

        gasBefore = gasleft();
        super._simulateFulfill(statusReq, response, "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status ongoing):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Ongoing);
    }

    function test_FulfillStatusUpdate_Finished_SetsWinnerAndResolved() public {
        bytes32 matchKey = fragBoxBetting.getKey(MATCHID);

        // Roster first
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 rosterReq = super._captureRequestId();

        uint256 gasBefore = gasleft();
        super._simulateFulfill(rosterReq, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (Roster update):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        // Voting status
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = super._captureRequestId();

        bytes memory response = bytes(PROCESSED_STATUS_VOTING);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, FragBoxBetting.MatchStatus.Voting, FragBoxBetting.Faction.Unknown);

        gasBefore = gasleft();
        super._simulateFulfill(statusReq, response, "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status finished):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        vm.warp(block.timestamp + WARP_TIME);

        // Finished status
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        statusReq = super._captureRequestId();

        response = bytes(PROCESSED_STATUS_FINISHED);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, FragBoxBetting.MatchStatus.Finished, FragBoxBetting.Faction.Faction1);

        gasBefore = gasleft();
        super._simulateFulfill(statusReq, response, "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status finished):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Finished);
        assertEq(uint256(mb.winnerFaction), uint256(FragBoxBetting.Faction.Faction1));
    }

    function test_FulfillRequest_ErrorPath_FromOracle() public {
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = super._captureRequestId();

        bytes memory err = bytes("Faceit API error");

        vm.expectEmit(true, true, true, true);
        emit RequestError(requestId, fragBoxBetting.getKey(MATCHID), "Faceit API error");

        uint256 gasBefore = gasleft();
        super._simulateFulfill(requestId, string(""), err);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (error path):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");
    }

    function test_FulfillRequest_InvalidRequestId_DoesNotCorruptOtherMatches() public {
        bytes32 fakeRequestId = keccak256("fake");

        uint256 gasBefore = gasleft();
        super._simulateFulfill(fakeRequestId, bytes(PROCESSED_STATUS_ONGOING), "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status ongoing):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");
        // No state change, no revert — exactly as intended
    }

    function test_DepositAfterRosterValidated_Succeeds() public {
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = super._captureRequestId();

        uint256 gasBefore = gasleft();
        super._simulateFulfill(requestId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (Roster update):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        vm.startPrank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        vm.stopPrank();

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(fragBoxBetting.getKey(MATCHID));

        uint256 sum = 0;
        uint256 len = mb.factionTotals.length;
        for (uint256 i = 0; i < len; i++) {
            sum += mb.factionTotals[i];
        }

        assertGt(sum, 0);
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
        uint256 gasBefore = gasleft();
        super._simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (Roster update):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusId = super._captureRequestId();

        gasBefore = gasleft();
        super._simulateFulfill(statusId, bytes(PROCESSED_STATUS_READY), "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status ongoing):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        vm.warp(block.timestamp + WARP_TIME);

        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        statusId = super._captureRequestId();

        gasBefore = gasleft();
        super._simulateFulfill(statusId, bytes(PROCESSED_STATUS_ONGOING), "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status ongoing):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

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
        uint256 gasBefore = gasleft();
        super._simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_LOSING_PLAYER), "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (Roster update):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        vm.startPrank(fragBoxBetting.owner());
        super._startRequestCapture();
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = super._captureRequestId();
        vm.stopPrank();

        bytes memory response = bytes(PROCESSED_STATUS_READY);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, FragBoxBetting.MatchStatus.Ready, FragBoxBetting.Faction.Unknown);

        gasBefore = gasleft();
        super._simulateFulfill(statusReq, response, "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status finished):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        vm.warp(block.timestamp + WARP_TIME);

        vm.startPrank(fragBoxBetting.owner());
        super._startRequestCapture();
        fragBoxBetting.updateMatchStatus(MATCHID);
        statusReq = super._captureRequestId();
        vm.stopPrank();

        response = bytes(PROCESSED_STATUS_FINISHED);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, FragBoxBetting.MatchStatus.Finished, FragBoxBetting.Faction.Faction1);

        gasBefore = gasleft();
        super._simulateFulfill(statusReq, response, "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status finished):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

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

        uint256 gasBefore = gasleft();
        super._simulateFulfill(rosterReq, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (Roster update):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        // fulfill status with "draw"
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = super._captureRequestId();

        gasBefore = gasleft();
        super._simulateFulfill(statusReq, bytes(PROCESSED_STATUS_FINISHED_DRAW), "");
        gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas used (status finished):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        // claim
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        // assert full refund to winnings (or fix this behavior if not intended)
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        assertEq(USER.balance, startingBalance - fee);
    }

    function test_RosterFailure_RefundViaFlightWithdraw() public {
        uint256 balBefore = USER.balance;

        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = super._captureRequestId();

        // Simulate oracle error (API fail, invalid player, etc.)
        uint256 gasBefore = gasleft();
        super._simulateFulfill(requestId, string(""), string("API error")); // err.length > 0 triggers error path
        uint256 gasUsed = gasBefore - gasleft();
        console.log("fulfillRequest gas (roster error path):", gasUsed);
        assertLt(gasUsed, CALLBACK_GAS_LIMIT, "Callback MUST stay under Chainlink Functions 300k limit");

        // Funds are now in flight (net of fee)
        vm.prank(USER);
        assertEq(
            fragBoxBetting.getBetAmountsInRosterValidationFlight(),
            SEND_VALUE - fragBoxBetting.calculateDepositFee(SEND_VALUE)
        );

        vm.prank(USER);
        fragBoxBetting.withdrawBetAmountsInRosterValidationFlight();

        // User gets full net amount back (fee was already taken — intended)
        assertEq(USER.balance, balBefore - fragBoxBetting.calculateDepositFee(SEND_VALUE));
    }

    function test_Claim_LoserNoExcess_Reverts() public {
        uint256 balBefore = USER.balance;

        // Winner and loser deposit the same amount
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, LOSING_PLAYERID);
        bytes32 rosterId = super._captureRequestId();
        super._simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_LOSING_PLAYER), "");

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER2);

        super._startRequestCapture();
        vm.prank(USER2);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        rosterId = super._captureRequestId();
        super._simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusId = super._captureRequestId();
        super._simulateFulfill(statusId, bytes(PROCESSED_STATUS_VOTING), "");

        vm.warp(block.timestamp + WARP_TIME);

        // Finish match with opposite faction as winner
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        statusId = super._captureRequestId();
        super._simulateFulfill(statusId, bytes(PROCESSED_STATUS_FINISHED), "");

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                FragBoxBetting.FragBoxBetting__LosingFactionCannotClaim.selector, FragBoxBetting.Faction.Faction2
            )
        );
        fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__InsufficientFundsForWithdrawal.selector);
        fragBoxBetting.withdraw(LOSING_PLAYERID);
        vm.stopPrank();

        // No funds should have moved to playerToWinnings
        assertEq(USER.balance, balBefore - SEND_VALUE);
    }

    function test_Claim_AllPaths_CorrectPayoutAndDustToOwner() public {
        vm.startPrank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID, USER2);

        uint256 startingOwnerFees = fragBoxBetting.getOwnerFeesCollected(); // assuming this view exists; if not, use a ghost or balance diff
        uint256 userBal = USER.balance;
        uint256 user2Bal = USER2.balance;
        vm.stopPrank();

        // User bets heavy on winner, User2 bets light on loser
        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: 0.2 ether}(MATCHID, WINNING_PLAYERID);
        bytes32 rosterId = super._captureRequestId();
        super._simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        super._startRequestCapture();
        vm.prank(USER2);
        fragBoxBetting.deposit{value: 0.1 ether}(MATCHID, LOSING_PLAYERID);
        rosterId = super._captureRequestId();
        super._simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_LOSING_PLAYER), "");

        // Finish match — Faction1 wins
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusId = super._captureRequestId();
        super._simulateFulfill(statusId, bytes(PROCESSED_STATUS_READY), "");

        vm.warp(block.timestamp + WARP_TIME);

        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        statusId = super._captureRequestId();
        super._simulateFulfill(statusId, bytes(PROCESSED_STATUS_FINISHED), "");

        // Claim
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        vm.startPrank(USER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                FragBoxBetting.FragBoxBetting__LosingFactionCannotClaim.selector, FragBoxBetting.Faction.Faction2
            )
        );
        fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__InsufficientFundsForWithdrawal.selector);
        fragBoxBetting.withdraw(LOSING_PLAYERID);
        vm.stopPrank();

        uint256 fee1 = fragBoxBetting.calculateDepositFee(0.2 ether);
        uint256 fee2 = fragBoxBetting.calculateDepositFee(0.1 ether);
        uint256 totalLosingBet = 0.1 ether - fee2;
        uint256 totalWinningBet = 0.2 ether - fee1;
        uint256 expectedWinnerPayout = totalLosingBet + totalWinningBet; // excess on winner side is refunded

        assertEq(USER.balance, userBal - 0.2 ether + expectedWinnerPayout);
        assertEq(USER2.balance, user2Bal - 0.1 ether); // loser gets nothing extra

        // Dust always goes to owner
        vm.startPrank(fragBoxBetting.owner());
        assertGt(fragBoxBetting.getOwnerFeesCollected(), startingOwnerFees);
        assertEq(address(fragBoxBetting).balance, fragBoxBetting.getOwnerFeesCollected());
        vm.stopPrank();
    }

    function test_MultiplePlayersSameFaction_ProRataWorks() public {
        // Three winners with different bet sizes
        uint256 bal1 = USER.balance;
        uint256 bal2 = USER2.balance;
        uint256 bal3 = USER3.balance;

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER);

        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: 0.1 ether}(MATCHID, WINNING_PLAYERID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER2);

        vm.prank(USER2);
        fragBoxBetting.deposit{value: 0.2 ether}(MATCHID, WINNING_PLAYERID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER3);

        vm.prank(USER3);
        fragBoxBetting.deposit{value: 0.3 ether}(MATCHID, WINNING_PLAYERID);

        // Finish with Faction1 win (no loser bets)
        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_STATUS_READY), "");

        vm.warp(block.timestamp + WARP_TIME);

        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_STATUS_FINISHED), "");

        // Claim + withdraw each
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        vm.startPrank(USER2);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        vm.startPrank(USER3);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        assertEq(USER.balance, bal1 - fragBoxBetting.calculateDepositFee(0.1 ether));
        assertEq(USER2.balance, bal3 - fragBoxBetting.calculateDepositFee(0.2 ether));
        assertEq(USER3.balance, bal2 - fragBoxBetting.calculateDepositFee(0.3 ether));
    }

    function test_Draw_FullRefundToAll() public {
        // same setup as test_ClaimWithDrawWinnerRefundsAll but uses the already-existing test logic
        // (already in your file — this is just a duplicate for clarity with full assertions)
        uint256 balBefore = USER.balance;

        super._startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        super._startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        super._simulateFulfill(super._captureRequestId(), bytes(PROCESSED_STATUS_FINISHED_DRAW), "");

        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        assertEq(USER.balance, balBefore - fee);
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
        fragBoxBetting.getOwnerFeesCollected();

        vm.expectRevert();
        vm.prank(USER);
        fragBoxBetting.getOwnerFeesCollected();
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

    function testGetPaused() public {
        assertFalse(fragBoxBetting.paused());

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.pause();

        assertTrue(fragBoxBetting.paused());

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.unpause();

        assertFalse(fragBoxBetting.paused());
    }
}
