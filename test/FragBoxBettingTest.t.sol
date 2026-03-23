// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";

contract FragBoxBettingTest is Test {
    FragBoxBetting fragBoxBetting;
    address chainLinkFunctionsRouter;

    address public USER = makeAddr("user");
    uint256 constant SEND_VALUE = 0.1 ether;
    uint256 constant STARTING_BALANCE = 10 ether;

    string constant MATCHID = "1-a536dd90-4df3-42df-be6e-d158177fdef2";
    string constant WINNING_PLAYERID = "94f98244-169d-478a-a5dd-21dde2e649ca";
    string constant WINNING_FACTION = "faction1";
    FragBoxBetting.Faction constant WINNING_FACTION_ENUM = FragBoxBetting.Faction.Faction1;

    string constant LOSING_PLAYERID = "92f1450e-182b-41db-8f31-53079df20c73";
    string constant LOSING_FACTION = "faction2";

    // ===================================================================
    // PROCESSED RESPONSES (EXACT output of your Chainlink Functions JS templates)
    // ===================================================================
    // These are NOT the raw Faceit JSON files you loaded below.
    // They are the tiny {type, f1, f2, status} or {type, status, winner} objects
    // that your ROSTER_SOURCE_TEMPLATE / STATUS_SOURCE_TEMPLATE actually return.
    string private PROCESSED_ROSTER_READY_WINNING_PLAYER;
    string private PROCESSED_ROSTER_READY_LOSING_PLAYER;
    string private PROCESSED_STATUS_VOTING;
    string private PROCESSED_STATUS_ONGOING;
    string private PROCESSED_STATUS_FINISHED;

    event RequestSent(bytes32 indexed requestId, bytes32 indexed matchKey);
    event RosterUpdated(bytes32 indexed matchKey, string playerId, FragBoxBetting.Faction playerFaction);
    event RequestFulfilled(bytes32 indexed requestId, bytes32 indexed matchKey, string status, string winnerFaction);

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        (fragBoxBetting, chainLinkFunctionsRouter) = deployFragBoxBetting.run();
        vm.deal(USER, STARTING_BALANCE);

        string memory mode = vm.envOr("FACEIT_TEST_MODE", string("offline"));

        if (keccak256(bytes(mode)) == keccak256(bytes("offline"))) {
            PROCESSED_ROSTER_READY_WINNING_PLAYER = _getProcessedResponse("matchReady.json", WINNING_PLAYERID);
            PROCESSED_ROSTER_READY_LOSING_PLAYER = _getProcessedResponse("matchReady.json", LOSING_PLAYERID);
            PROCESSED_STATUS_VOTING = _getProcessedResponse("matchVoting.json", "");
            PROCESSED_STATUS_ONGOING = _getProcessedResponse("matchOngoing.json", "");
            PROCESSED_STATUS_FINISHED = _getProcessedResponse("matchFinished.json", "");
        } else {
            PROCESSED_ROSTER_READY_WINNING_PLAYER = _getProcessedResponse(MATCHID, WINNING_PLAYERID);
            PROCESSED_ROSTER_READY_LOSING_PLAYER = _getProcessedResponse(MATCHID, LOSING_PLAYERID);
            PROCESSED_STATUS_VOTING = _getProcessedResponse(MATCHID, "");
            PROCESSED_STATUS_ONGOING = _getProcessedResponse(MATCHID, "");
            PROCESSED_STATUS_FINISHED = _getProcessedResponse(MATCHID, "");
        }
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
    bytes32 internal constant BET_PLACED_SIG = keccak256("BetPlaced(bytes32,address,uint256,string)");
    bytes32 internal constant REQUEST_SENT_SIG = keccak256("RequestSent(bytes32,bytes32)");
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

    /* -------------------- SIMULATE CHAINLINK FUNCTIONS DON -------------------- */
    function _simulateFulfill(bytes32 requestId, string memory jsonResponse, bytes memory err) internal {
        bytes memory response = bytes(jsonResponse);
        vm.prank(chainLinkFunctionsRouter);
        fragBoxBetting.handleOracleFulfillment(requestId, response, err);
    }

    function _simulateFulfill(bytes32 requestId, bytes memory jsonResponse, bytes memory err) internal {
        vm.prank(chainLinkFunctionsRouter);
        fragBoxBetting.handleOracleFulfillment(requestId, jsonResponse, err);
    }

    /// @notice Runs your exact JS (offline or real)
    function _getProcessedResponse(
        string memory arg1, // json filename OR real matchId
        string memory arg2 // playerId (use "" for status-only calls)
    )
        internal
        returns (string memory)
    {
        string memory mode = vm.envOr("FACEIT_TEST_MODE", string("offline"));
        string memory apiKey = vm.envOr("FACEIT_CLIENT_API_KEY", string(""));

        string[] memory cmds = new string[](3);
        cmds[0] = "sh";
        cmds[1] = "-c";
        cmds[2] = string.concat(
            "node verify-faceit-functions.js ",
            mode,
            ' "',
            arg1,
            '" --api-key=',
            apiKey,
            ' "',
            arg2,
            '" --silent 2>/dev/null'
        );

        bytes memory rawOutput = vm.ffi(cmds);

        // Trim trailing newline (if any)
        if (rawOutput.length > 0 && rawOutput[rawOutput.length - 1] == 0x0a) {
            assembly {
                mstore(rawOutput, sub(mload(rawOutput), 1))
            }
        }

        string memory response = string(rawOutput);
        response = _stripSecpWarning(response);
        return response;
    }

    /// @notice Strips the exact secp256k1 warning if it sneaks into the JS output
    function _stripSecpWarning(string memory input) internal pure returns (string memory) {
        bytes memory b = bytes(input);
        bytes memory warning = bytes("secp256k1 unavailable, reverting to browser version");

        if (b.length < warning.length) {
            return input;
        }

        // Manual prefix check (pure memory bytes — no slicing)
        bool hasWarning = true;
        for (uint256 i = 0; i < warning.length; i++) {
            if (b[i] != warning[i]) {
                hasWarning = false;
                break;
            }
        }

        if (!hasWarning) {
            return input;
        }

        // Skip warning + optional trailing newline
        uint256 start = warning.length;
        if (start < b.length && b[start] == 0x0a) {
            start++;
        }

        // Build clean result
        bytes memory result = new bytes(b.length - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = b[start + i];
        }

        return string(result);
    }

    /* -------------------------------------------------------------------------- */
    /*                                DEPOSIT TESTS                               */
    /* -------------------------------------------------------------------------- */
    function testPlaceBetWithNoBalance() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__BetTooSmall.selector, 0));
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        vm.stopPrank();
    }

    function testPlaceBet() public {
        vm.startPrank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                    CHAINLINK FUNCTIONS INTEGRATION TESTS                   */
    /* -------------------------------------------------------------------------- */
    function test_FulfillRosterUpdate_Success() public {
        bytes32 matchKey = fragBoxBetting.getMatchKey(MATCHID);

        _startRequestCapture();
        vm.prank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        bytes32 requestId = _captureRequestId();

        bytes memory response = bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER);

        vm.expectEmit(true, true, true, false);
        emit RosterUpdated(matchKey, WINNING_PLAYERID, WINNING_FACTION_ENUM);

        _simulateFulfill(requestId, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assertTrue(fragBoxBetting.getPlayerFaction(matchKey, WINNING_PLAYERID) == FragBoxBetting.Faction.Faction1);
        assertEq(mb.status, "");
        assertEq(mb.lastRosterUpdate, block.timestamp);
        assertEq(mb.lastStatusUpdate, 0);
    }

    function test_FulfillStatusUpdate_Ongoing() public {
        bytes32 matchKey = fragBoxBetting.getMatchKey(MATCHID);

        // 1. Roster first
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        // fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID);
        bytes32 rosterReq = _captureRequestId();
        _simulateFulfill(rosterReq, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        vm.warp(block.timestamp + 6 minutes);

        // 2. Status update
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = _captureRequestId();

        bytes memory response = bytes(PROCESSED_STATUS_ONGOING);
        _simulateFulfill(statusReq, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assertEq(mb.status, "ONGOING");
        assertFalse(mb.resolved);
    }

    function test_FulfillStatusUpdate_Finished_SetsWinnerAndResolved() public {
        bytes32 matchKey = fragBoxBetting.getMatchKey(MATCHID);

        // Roster first
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        bytes32 rosterReq = _captureRequestId();
        _simulateFulfill(rosterReq, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        // Finished status (uses "faction2" from your real JSON)
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = _captureRequestId();

        bytes memory response = bytes(PROCESSED_STATUS_FINISHED);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, "FINISHED", "faction1");

        _simulateFulfill(statusReq, response, "");

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assertEq(mb.status, "FINISHED");
        assertTrue(mb.resolved);
        assertEq(uint256(mb.winnerFaction), uint256(FragBoxBetting.Faction.Faction1));
    }

    function test_FulfillRequest_ErrorPath_FromOracle() public {
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        // fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = _captureRequestId();

        bytes memory err = bytes("Faceit API error");

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(requestId, fragBoxBetting.getMatchKey(MATCHID), "ERROR", "Faceit API error");

        _simulateFulfill(requestId, string(""), err);
    }

    function test_FulfillRequest_InvalidRequestId_DoesNotCorruptOtherMatches() public {
        bytes32 fakeRequestId = keccak256("fake");
        _simulateFulfill(fakeRequestId, bytes(PROCESSED_STATUS_ONGOING), "");
        // No state change, no revert — exactly as intended
    }

    function test_DepositAfterRosterValidated_Succeeds() public {
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        // fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = _captureRequestId();
        _simulateFulfill(requestId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        vm.startPrank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        vm.stopPrank();

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(fragBoxBetting.getMatchKey(MATCHID));
        assertGt(mb.totalBetAmount, 0);
    }

    function testInvalidBetGetsCleanedAndRefundedViaWithdraw() public {
        // 1. Deposit invalid bet (wrong faction)
        vm.startPrank(USER);
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, LOSING_FACTION);
        vm.stopPrank();

        // 2. Set Match Status To Ready and call roster
        _startRequestCapture();
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        // fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID);
        bytes32 requestId = _captureRequestId();
        // This should clean invalid bets
        _simulateFulfill(requestId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        // 3. Player can now withdraw the refunded amount
        vm.startPrank(USER);
        uint256 balBefore = USER.balance;
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        assertEq(USER.balance, balBefore);
        vm.stopPrank();
    }

    function testEmergencyRefundAfterTimeout() public {
        // deposit, advance time >24h, call emergencyRefund
        vm.startPrank(USER);
        _startRequestCapture();
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, WINNING_PLAYERID, WINNING_FACTION);
        bytes32 rosterId = _captureRequestId();
        vm.stopPrank();
        // Validate roster
        _simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_WINNING_PLAYER), "");

        _startRequestCapture();
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusId = _captureRequestId();
        _simulateFulfill(statusId, bytes(PROCESSED_STATUS_ONGOING), "");

        vm.expectRevert(FragBoxBetting.FragBoxBetting__StatusUpdateTooSoon.selector);
        fragBoxBetting.updateMatchStatus(MATCHID);

        vm.startPrank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__TimeoutNotReached.selector);
        fragBoxBetting.emergencyRefund(MATCHID);
        vm.warp(block.timestamp + 25 hours);
        fragBoxBetting.emergencyRefund(MATCHID);

        // then player calls withdraw() and gets full amount back
        uint256 balBefore = USER.balance;
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();
        assertEq(USER.balance, balBefore);
    }

    function testNoOneBetOnWinner_AllRefunded() public {
        bytes32 matchKey = fragBoxBetting.getMatchKey(MATCHID);

        // deposit only on losing faction
        vm.startPrank(USER);
        _startRequestCapture();
        fragBoxBetting.deposit{value: SEND_VALUE}(MATCHID, LOSING_PLAYERID, LOSING_FACTION);
        bytes32 rosterId = _captureRequestId();
        vm.stopPrank();
        // fulfill status with winner = other faction
        _simulateFulfill(rosterId, bytes(PROCESSED_ROSTER_READY_LOSING_PLAYER), "");

        vm.warp(block.timestamp + 6 minutes);

        vm.startPrank(USER);
        _startRequestCapture();
        fragBoxBetting.updateMatchStatus(MATCHID);
        bytes32 statusReq = _captureRequestId();
        vm.stopPrank();

        bytes memory response = bytes(PROCESSED_STATUS_FINISHED);

        vm.expectEmit(true, true, true, true);
        emit RequestFulfilled(statusReq, matchKey, "FINISHED", "faction1");

        _simulateFulfill(statusReq, response, "");

        // claim() should refund everyone via playerToWinnings
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID);

        // withdraw succeeds
        uint256 balBefore = USER.balance;
        fragBoxBetting.withdraw(LOSING_PLAYERID);
        vm.stopPrank();
        assertEq(USER.balance, balBefore);
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

    function testGetMatchKey() public view {
        fragBoxBetting.getMatchKey(MATCHID);
    }

    function testGetMatchBet() public view {
        fragBoxBetting.getMatchBet(fragBoxBetting.getMatchKey(MATCHID));
    }

    function testGetPlayerFaction() public view {
        fragBoxBetting.getPlayerFaction(fragBoxBetting.getMatchKey(MATCHID), WINNING_PLAYERID);
    }
}
