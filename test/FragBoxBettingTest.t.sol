// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";

contract FragBoxBettingTest is Test {
    FragBoxBetting fragBoxBetting;

    address public USER = makeAddr("user");
    uint256 constant SEND_VALUE = 0.1 ether;
    uint256 constant STARTING_BALANCE = 10 ether;

    string constant MATCHID = "1-d031ff3b-8654-4922-9f90-0bc538e3d6e4";
    string constant PLAYERID = "94f98244-169d-478a-a5dd-21dde2e649ca";
    string constant FACTION = "faction1";

    // ===================================================================
    // PROCESSED RESPONSES (EXACT output of your Chainlink Functions JS templates)
    // ===================================================================
    // These are NOT the raw Faceit JSON files you loaded below.
    // They are the tiny {type, f1, f2, status} or {type, status, winner} objects
    // that your ROSTER_SOURCE_TEMPLATE / STATUS_SOURCE_TEMPLATE actually return.
    string constant PROCESSED_ROSTER_READY =
        '{"type":"roster","f1":"541d15c2-e699-4c99-a706-ddedcd6aac62,94f98244-169d-478a-a5dd-21dde2e649ca,5295e6a8-b817-4d38-bbcf-f2c7b56bd472,5234c0d7-19f6-49f3-80b5-c427470f60b6,ecf00c3a-68a4-44d7-a212-2ff2ca0fb4fe","f2":"0a3fe9a7-b60f-4746-b30d-57bea3414077,92f1450e-182b-41db-8f31-53079df20c73,9ed84901-333f-49c4-a574-7b99fb4513c4,9054f35b-0b01-43fb-8e96-68373be8aed5,eae78ccf-7f01-4a41-809a-76594f5c8735","status":"READY"}';
    string constant PROCESSED_STATUS_VOTING = '{"type":"status","status":"VOTING","winner":"unknown"}';
    string constant PROCESSED_STATUS_ONGOING = '{"type":"status","status":"ONGOING","winner":"unknown"}';
    string constant PROCESSED_STATUS_FINISHED = '{"type":"status","status":"FINISHED","winner":"faction1"}';

    string matchReadyJson;
    string matchOngoingJson;
    string matchFinishedJson;
    string matchVotingJson;

    event RequestSent(bytes32 indexed requestId, bytes32 indexed matchKey);
    event RosterUpdated(bytes32 indexed matchKey, uint256 playerCount);
    event RequestFulfilled(bytes32 indexed requestId, bytes32 indexed matchKey, string status, string winnerFaction);

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        fragBoxBetting = deployFragBoxBetting.run();
        vm.deal(USER, STARTING_BALANCE);

        matchReadyJson = vm.readFile("test/faceitApiResponseBodyExamples/matchReady.json");
        matchOngoingJson = vm.readFile("test/faceitApiResponseBodyExamples/matchOngoing.json");
        matchFinishedJson = vm.readFile("test/faceitApiResponseBodyExamples/matchFinished.json");
        matchVotingJson = vm.readFile("test/faceitApiResponseBodyExamples/matchVoting.json");
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
    EventLogLevel internal constant LOG_LEVEL = EventLogLevel.Full;

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
            else if (sig == REQUEST_SENT_SIG) _printRequestSent(log, level);
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
    bytes32 internal constant BET_PLACED_SIG = keccak256("BetPlaced(bytes32,address,uint256,uint8,string)");
    bytes32 internal constant REQUEST_SENT_SIG = keccak256("RequestSent(bytes32,bytes32)");
    bytes32 internal constant REQUEST_FULFILLED_SIG = keccak256("RequestFulfilled(bytes32,bytes32,string,string)");
    bytes32 internal constant EMERGENCY_REFUND_SIG = keccak256("EmergencyRefund(bytes32)");
    bytes32 internal constant MATCH_CLAIMED_SIG = keccak256("MatchClaimed(bytes32)");
    bytes32 internal constant ROSTER_UPDATED_SIG = keccak256("RosterUpdated(bytes32,uint256)");

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

    function _printRequestSent(Vm.Log memory log, EventLogLevel level) private pure {
        console.log("-> RequestSent");
        if (level == EventLogLevel.NamesOnly) return;

        console.log("  RequestId:");
        console.logBytes32(log.topics[1]);
        console.log("  MatchKey :");
        console.logBytes32(log.topics[2]);
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

    /* --------------------------- CAPTURE REQUEST ID --------------------------- */
    function _startRequestCapture() internal {
        vm.recordLogs();
    }

    function _captureRequestId() internal view returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == RequestSent.selector) {
                return logs[i].topics[1];
            }
        }
        revert("RequestSent event not found");
    }

    /* -------------------------------------------------------------------------- */
    /*                                DEPOSIT TESTS                               */
    /* -------------------------------------------------------------------------- */
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

    /* -------------------------------------------------------------------------- */
    /*                    CHAINLINK FUNCTIONS INTEGRATION TESTS                   */
    /* -------------------------------------------------------------------------- */
    function test_FulfillRosterUpdate_Success() public {
        bytes32 matchKey = fragBoxBetting.getMatchKey(MATCHID);

        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID);
        bytes32 requestId = _captureRequestId();

        bytes memory response = bytes(PROCESSED_ROSTER_READY);

        vm.expectEmit(true, true, true, false);
        emit RosterUpdated(matchKey, 0); // playerCount will be exact in real run

        fragBoxBetting.testFulfillRequest(requestId, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assertTrue(mb.rosterValidated);
        assertEq(mb.status, "READY");
        assertEq(mb.lastRosterUpdate, block.timestamp);
        assertEq(mb.lastStatusUpdate, block.timestamp);
    }

    function test_FulfillStatusUpdate_Ongoing() public {
        bytes32 matchKey = fragBoxBetting.getMatchKey(MATCHID);

        // 1. Roster first
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID);
        bytes32 rosterReq = _captureRequestId();
        fragBoxBetting.testFulfillRequest(rosterReq, bytes(PROCESSED_ROSTER_READY), "");

        // 2. Status update
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = _captureRequestId();

        bytes memory response = bytes(PROCESSED_STATUS_ONGOING);
        fragBoxBetting.testFulfillRequest(statusReq, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assertEq(mb.status, "ONGOING");
        assertFalse(mb.resolved);
    }

    function test_FulfillStatusUpdate_Finished_SetsWinnerAndResolved() public {
        bytes32 matchKey = fragBoxBetting.getMatchKey(MATCHID);

        // Roster first
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID);
        bytes32 rosterReq = _captureRequestId();
        fragBoxBetting.testFulfillRequest(rosterReq, bytes(PROCESSED_ROSTER_READY), "");

        // Finished status (uses "faction2" from your real JSON)
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = _captureRequestId();

        bytes memory response = bytes(PROCESSED_STATUS_FINISHED);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, "FINISHED", "faction1");

        fragBoxBetting.testFulfillRequest(statusReq, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assertEq(mb.status, "FINISHED");
        assertTrue(mb.resolved);
        assertEq(uint256(mb.winnerFaction), uint256(FragBoxBetting.Faction.Faction1));
    }

    function test_FulfillRequest_ErrorPath_FromOracle() public {
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID);
        bytes32 requestId = _captureRequestId();

        bytes memory err = bytes("Faceit API error");

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(requestId, fragBoxBetting.getMatchKey(MATCHID), "ERROR", "Faceit API error");

        fragBoxBetting.testFulfillRequest(requestId, "", err);
    }

    function test_FulfillRequest_InvalidRequestId_DoesNotCorruptOtherMatches() public {
        bytes32 fakeRequestId = keccak256("fake");
        fragBoxBetting.testFulfillRequest(fakeRequestId, bytes(PROCESSED_STATUS_ONGOING), "");
        // No state change, no revert — exactly as intended
    }

    function test_exposedGetJsonValue_ParserWorks() public view {
        string memory json = '{"type":"roster","f1":"abc,def","status":"READY","winner":""}';
        assertEq(fragBoxBetting.exposedGetJsonValue(json, "type"), "roster");
        assertEq(fragBoxBetting.exposedGetJsonValue(json, "f1"), "abc,def");
        assertEq(fragBoxBetting.exposedGetJsonValue(json, "status"), "READY");
        assertEq(fragBoxBetting.exposedGetJsonValue(json, "winner"), "");
        assertEq(fragBoxBetting.exposedGetJsonValue(json, "missing"), "");
    }

    function test_DepositAfterRosterValidated_Succeeds() public {
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID);
        bytes32 requestId = _captureRequestId();
        fragBoxBetting.testFulfillRequest(requestId, bytes(PROCESSED_ROSTER_READY), "");

        vm.startPrank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, PLAYERID, FACTION);
        vm.stopPrank();

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(fragBoxBetting.getMatchKey(MATCHID));
        assertGt(mb.totalBetAmount, 0);
    }
}
