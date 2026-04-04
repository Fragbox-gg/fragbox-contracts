// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";

contract SimulateOracles is Test {
    FragBoxBetting internal fragBoxBettingContract;
    address internal chainLinkFunctionsRouterAddress;

    // ===================================================================
    // PROCESSED RESPONSES (EXACT output of your Chainlink Functions JS templates)
    // ===================================================================
    // These are NOT the raw Faceit JSON files you loaded below.
    // They are the tiny {type, f1, f2, status} or {type, status, winner} objects
    // that your ROSTER_SOURCE_TEMPLATE / STATUS_SOURCE_TEMPLATE actually return.
    string internal PROCESSED_ROSTER_READY_WINNING_PLAYER;
    string internal PROCESSED_ROSTER_READY_LOSING_PLAYER;
    string internal PROCESSED_STATUS_VOTING;
    string internal PROCESSED_STATUS_READY;
    string internal PROCESSED_STATUS_ONGOING;
    string internal PROCESSED_STATUS_FINISHED;
    string internal PROCESSED_STATUS_FINISHED_DRAW;

    string constant MATCHID = "1-a536dd90-4df3-42df-be6e-d158177fdef2";
    string constant WINNING_PLAYERID = "94f98244-169d-478a-a5dd-21dde2e649ca";
    string constant LOSING_PLAYERID = "92f1450e-182b-41db-8f31-53079df20c73";

    function setUpSimulation(address chainLinkFunctionsRouter, FragBoxBetting fragBoxBetting) internal {
        fragBoxBettingContract = fragBoxBetting;
        chainLinkFunctionsRouterAddress = chainLinkFunctionsRouter;

        string memory mode = vm.envOr("FACEIT_TEST_MODE", string("offline"));

        if (keccak256(bytes(mode)) == keccak256(bytes("offline"))) {
            PROCESSED_ROSTER_READY_WINNING_PLAYER = _getProcessedResponse("matchReady.json", WINNING_PLAYERID);
            PROCESSED_ROSTER_READY_LOSING_PLAYER = _getProcessedResponse("matchReady.json", LOSING_PLAYERID);
            PROCESSED_STATUS_VOTING = _getProcessedResponse("matchVoting.json", "");
            PROCESSED_STATUS_READY = _getProcessedResponse("matchReady.json", "");
            PROCESSED_STATUS_ONGOING = _getProcessedResponse("matchOngoing.json", "");
            PROCESSED_STATUS_FINISHED = _getProcessedResponse("matchFinished.json", "");
            PROCESSED_STATUS_FINISHED_DRAW = _getProcessedResponse("matchFinishedDraw.json", "");
        } else {
            PROCESSED_ROSTER_READY_WINNING_PLAYER = _getProcessedResponse(MATCHID, WINNING_PLAYERID);
            PROCESSED_ROSTER_READY_LOSING_PLAYER = _getProcessedResponse(MATCHID, LOSING_PLAYERID);
            PROCESSED_STATUS_VOTING = _getProcessedResponse(MATCHID, "");
            PROCESSED_STATUS_READY = _getProcessedResponse(MATCHID, "");
            PROCESSED_STATUS_ONGOING = _getProcessedResponse(MATCHID, "");
            PROCESSED_STATUS_FINISHED = _getProcessedResponse(MATCHID, "");
            PROCESSED_STATUS_FINISHED_DRAW = _getProcessedResponse(MATCHID, "");
        }
    }

    event RequestSent(bytes32 indexed requestId, bytes32 indexed matchKey);

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
    function _simulateFulfill(bytes32 requestId, string memory jsonResponse, string memory err) internal {
        _simulateFulfill(requestId, bytes(jsonResponse), bytes(err));
    }

    function _simulateFulfill(bytes32 requestId, string memory jsonResponse, bytes memory err) internal {
        _simulateFulfill(requestId, bytes(jsonResponse), err);
    }

    function _simulateFulfill(bytes32 requestId, bytes memory jsonResponse, bytes memory err) internal {
        vm.prank(chainLinkFunctionsRouterAddress);
        fragBoxBettingContract.handleOracleFulfillment(requestId, jsonResponse, err);
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
}
