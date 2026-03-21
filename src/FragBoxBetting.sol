// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract FragBoxBetting is ReentrancyGuard, Ownable, FunctionsClient {
    error FragBoxBetting__MatchAlreadyResolved(bytes32 matchKey);
    error FragBoxBetting__MatchNotResolved(bytes32 matchKey);
    error FragBoxBetting__NoBetsPlaced(bytes32 matchKey);
    error FragBoxBetting__FaceitAPIUnavailable();
    error FragBoxBetting__TimeoutNotReached();
    error FragBoxBetting__MatchNotRequested();
    error FragBoxBetting__BetTooSmall(uint256 amount);
    error FragBoxBetting__AlreadyRequested(bytes32 matchKey);
    error FragBoxBetting__InvalidFaction(string factionStr);
    error FragBoxBetting__FaceitAPIKeyNotSet();
    error FragBoxBetting__MatchNotReady();
    error FragBoxBetting__MatchNotFinished();
    error FragBoxBetting__InvalidRequest(bytes32 requestId);
    error FragBoxBetting__PlayerNotInMatch(string matchId, string playerId);

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant TIMEOUT_DURATION = 24 hours;
    uint256 private constant HOUSE_FEE_PERCENTAGE = 1; // 1 = 1%
    uint256 private constant PERCENTAGE_BASE = 100;
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 private constant MIN_BET_AMOUNT = 0.001 ether;

    // Called ONCE by backend — returns roster + initial status
    string private constant ROSTER_SOURCE_TEMPLATE = "const matchId = args[0];" "const apiKey = args[1];"
        "const res = await Functions.makeHttpRequest({" "  url: `https://open.faceit.com/data/v4/matches/${matchId}`,"
        "  headers: { 'Accept': 'application/json', 'Authorization': `Bearer ${apiKey}` }" "});"
        "if (res.error) throw Error('Faceit API error');" "const data = res.data;" "let f1 = '';" "let f2 = '';"
        "if (data.teams?.faction1?.roster) {" "  f1 = data.teams.faction1.roster.map(p => p.player_id).join(',');" "}"
        "if (data.teams?.faction2?.roster) {" "  f2 = data.teams.faction2.roster.map(p => p.player_id).join(',');" "}"
        "const status = data.status || 'UNKNOWN';" "return Functions.encodeString(JSON.stringify({" "  type: 'roster',"
        "  f1: f1," "  f2: f2," "  status: status" "}));";

    // Called REPEATEDLY by backend — status + winner only
    string private constant STATUS_SOURCE_TEMPLATE = "const matchId = args[0];" "const apiKey = args[1];"
        "const res = await Functions.makeHttpRequest({" "  url: `https://open.faceit.com/data/v4/matches/${matchId}`,"
        "  headers: { 'Accept': 'application/json', 'Authorization': `Bearer ${apiKey}` }" "});"
        "if (res.error) throw Error('Faceit API error');" "const data = res.data;"
        "const status = data.status || 'UNKNOWN';" "let winner = 'unknown';"
        "if (status === 'FINISHED' && data.results && data.results.winner) {" "  winner = data.results.winner;" "}"
        "return Functions.encodeString(JSON.stringify({" "  type: 'status'," "  status: status," "  winner: winner"
        "}));";

    enum Faction {
        Unknown,
        Faction1,
        Faction2,
        Draw
    }

    struct Bet {
        address wallet;
        string playerId; // kept as string (user-controlled, not used as key)
        Faction faction;
        uint256 amount;
    }

    struct MatchBet {
        Bet[] bets;
        Faction winnerFaction; // "" = pending, "faction1"/"faction2"/"draw"
        bool resolved; // this is true when a victor has been set/the match has finished
        bool claimed; // this is true when a match's bets have been paid out
        bytes32 requestId;
        uint256 totalBetAmount;
        uint256 totalFeesCollected;

        mapping(string => Faction) playerToFaction; // playerId => Faction (Unknown = invalid/not present)
        bool rosterValidated; // Has the oracle successfully updated rosters?
        uint256 lastRosterUpdate; // timestamp of last successful update

        string status; // "READY", "ONGOING", "FINISHED"
        uint256 lastStatusUpdate;
    }

    mapping(bytes32 => MatchBet) public matchBets;
    mapping(bytes32 => bytes32) public requestToMatchKey; // requestId => matchKey (bytes32)

    string private faceitApiKey;

    AggregatorV3Interface private immutable I_ETHUSDPRICEFEED;
    address private immutable I_CHAINLINKFUNCTIONSROUTER;
    bytes32 private immutable I_DONID;
    uint64 private immutable I_SUBSCRIPTIONID;
    address private immutable I_LINKTOKEN;

    event BetPlaced(bytes32 indexed matchKey, address indexed better, uint256 amount, Faction faction, string playerId);
    event RequestSent(bytes32 indexed requestId, bytes32 indexed matchKey);
    event RequestFulfilled(bytes32 indexed requestId, bytes32 indexed matchKey, string status, string winnerFaction);
    event EmergencyRefund(bytes32 indexed matchKey);
    event MatchClaimed(bytes32 indexed matchKey);
    event RosterUpdated(bytes32 indexed matchKey, uint256 playerCount);

    /**
     * Converts the match id string into a bytes object for gas savings
     * @param matchIdStr The match id string to convert
     */
    function _getMatchKey(string calldata matchIdStr) internal pure returns (bytes32) {
        return keccak256(bytes(matchIdStr));
    }

    /**
     * Converts a string to the faction enum
     * @param factionStr The string that represents a faction
     */
    function _toFaction(string memory factionStr) internal pure returns (Faction) {
        bytes32 hash = keccak256(bytes(factionStr));
        if (hash == keccak256(bytes("faction1"))) return Faction.Faction1;
        if (hash == keccak256(bytes("faction2"))) return Faction.Faction2;
        if (hash == keccak256(bytes("draw"))) return Faction.Draw;
        return Faction.Unknown;
    }

    /**
     * Compares the equality of 2 strings
     * @param a The first string
     * @param b The second string
     */
    function _compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    /**
     * Lightweight JSON string extractor - perfect for small Chainlink Functions responses
     * @dev Only looks for "key":"value" pattern (no nested objects/arrays needed yet)
     * @param json The response body
     * @param key The value you're looking for
     */
    function _getJsonValue(string memory json, string memory key) internal pure returns (string memory) {
        bytes memory data = bytes(json);
        bytes memory search = bytes(string.concat('"', key, '":"'));

        for (uint256 i = 0; i <= data.length - search.length; i++) {
            if (_memcmp(data, i, search)) {
                uint256 start = i + search.length;
                uint256 end = start;
                while (end < data.length && data[end] != '"') end++;
                bytes memory value = new bytes(end - start);
                for (uint256 k = 0; k < value.length; k++) {
                    value[k] = data[start + k];
                }
                return string(value);
            }
        }
        return "";
    }

    function _memcmp(bytes memory a, uint256 offset, bytes memory b) internal pure returns (bool) {
        if (a.length < offset + b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[offset + i] != b[i]) return false;
        }
        return true;
    }

    function _addPlayersFromCsv(MatchBet storage mb, string memory csv, Faction faction) internal returns (uint256) {
        if (bytes(csv).length == 0) return 0;

        uint256 count = 0;
        bytes memory data = bytes(csv);
        uint256 start = 0;

        for (uint256 i = 0; i <= data.length; i++) {
            if (i == data.length || data[i] == ",") {
                if (i > start) {
                    bytes memory id = new bytes(i - start);
                    for (uint256 j = 0; j < id.length; j++) {
                        id[j] = data[start + j];
                    }
                    string memory playerId = string(id);
                    if (mb.playerToFaction[playerId] == Faction.Unknown) {
                        mb.playerToFaction[playerId] = faction;
                        count++;
                    }
                }
                start = i + 1;
            }
        }
        return count;
    }

    function _cleanInvalidBets(MatchBet storage mb) internal {
        uint256 len = mb.bets.length;
        for (uint256 i = 0; i < len; i++) {
            Bet storage bet = mb.bets[i];
            if (bet.amount > 0) {
                Faction correct = mb.playerToFaction[bet.playerId];
                if (correct == Faction.Unknown || correct != bet.faction) {
                    Address.sendValue(payable(owner()), bet.amount);
                    bet.amount = 0; // ignored forever in claim/refund
                }
            }
        }
    }

    constructor(
        address ethUsdPriceFeed,
        address chainLinkFunctionsRouter,
        bytes32 donId,
        uint64 subscriptionId,
        address linkToken
    ) Ownable(msg.sender) FunctionsClient(chainLinkFunctionsRouter) {
        I_ETHUSDPRICEFEED = AggregatorV3Interface(ethUsdPriceFeed);
        I_CHAINLINKFUNCTIONSROUTER = chainLinkFunctionsRouter;
        I_DONID = donId;
        I_SUBSCRIPTIONID = subscriptionId;
        I_LINKTOKEN = linkToken;
    }

    /**
     * Owner-only setter so the API key is never in the source code on-chain
     * @param _key Faceit Data API Client Key
     */
    function setFaceitApiKey(string calldata _key) external onlyOwner {
        faceitApiKey = _key;
    }

    /**
     * Called ONCE by backend to fetch and store player rosters
     * @param matchIdStr The match Id to check
     */
    function updateMatchRoster(string calldata matchIdStr) external onlyOwner {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.rosterValidated) revert FragBoxBetting__AlreadyRequested(matchKey);
        if (bytes(faceitApiKey).length == 0) revert FragBoxBetting__FaceitAPIKeyNotSet();

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(ROSTER_SOURCE_TEMPLATE);

        string[] memory args = new string[](2);
        args[0] = matchIdStr;
        args[1] = faceitApiKey;
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), I_SUBSCRIPTIONID, CALLBACK_GAS_LIMIT, I_DONID);

        mb.requestId = requestId;
        requestToMatchKey[requestId] = matchKey;
        emit RequestSent(requestId, matchKey);
    }

    /**
     * Called REPEATEDLY by backend to update match status
     * @param matchIdStr The match Id to check
     */
    function updateMatchStatus(string calldata matchIdStr) external onlyOwner {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved || mb.claimed) revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        if (bytes(faceitApiKey).length == 0) revert FragBoxBetting__FaceitAPIKeyNotSet();

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(STATUS_SOURCE_TEMPLATE);

        string[] memory args = new string[](2);
        args[0] = matchIdStr;
        args[1] = faceitApiKey;
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), I_SUBSCRIPTIONID, CALLBACK_GAS_LIMIT, I_DONID);

        mb.requestId = requestId;
        requestToMatchKey[requestId] = matchKey;
        emit RequestSent(requestId, matchKey);
    }

    /**
     * Place Bet on an ongoing faceit match that you are a part of. This is where players pay their deposit fee so that we don't have to calculate fees during payout/resolution
     * @param matchIdStr The id of the match the player is betting on
     * @param playerId The id of the player who is placing the bet
     * @param factionStr The faction of the player who is placing the bet
     */
    function deposit(string calldata matchIdStr, string calldata playerId, string calldata factionStr)
        external
        payable
        nonReentrant
    {
        if (msg.value < MIN_BET_AMOUNT) revert FragBoxBetting__BetTooSmall(msg.value);

        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved || mb.claimed) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }

        Faction chosenFaction = _toFaction(factionStr);
        if (chosenFaction == Faction.Unknown) {
            revert FragBoxBetting__InvalidFaction(factionStr);
        }

        if (!_compareStrings(mb.status, "READY")) {
            revert FragBoxBetting__MatchNotReady();
        }

        // Hard validation - only revert after roster has been fetched at least once (covers both "not present" and "wrong faction")
        if (mb.rosterValidated) {
            Faction actual = mb.playerToFaction[playerId];
            if (actual == Faction.Unknown || actual != chosenFaction) {
                revert FragBoxBetting__PlayerNotInMatch(matchIdStr, playerId);
            }
        }

        // Calculate house fee and actual bet amount
        uint256 fee = (msg.value * HOUSE_FEE_PERCENTAGE) / PERCENTAGE_BASE;
        uint256 betAmount = msg.value - fee;

        // Send fee to owner
        Address.sendValue(payable(owner()), fee);

        // Check for existing bet with SAME WALLET + SAME PLAYER + SAME FACTION ===
        // If found, just increase the amount (top-up). Otherwise push a new Bet entry.
        bool betExists = false;
        uint256 betsLength = mb.bets.length;
        for (uint256 i = 0; i < betsLength; i++) {
            Bet storage bet = mb.bets[i];
            if (
                bet.wallet == msg.sender && _compareStrings(bet.playerId, playerId) // use your existing helper for string comparison
                    && bet.faction == chosenFaction
            ) {
                bet.amount += betAmount;
                betExists = true;
                break;
            }
        }

        if (!betExists) {
            mb.bets.push(Bet({wallet: msg.sender, playerId: playerId, faction: chosenFaction, amount: betAmount}));
        }

        mb.totalBetAmount += betAmount;
        mb.totalFeesCollected += fee;

        emit BetPlaced(matchKey, msg.sender, betAmount, chosenFaction, playerId);
    }

    /**
     * The chainlink functions oracle calls this function when it finishes calling the faceit API
     * @param requestId The Id of the chainlink functions oracle request. Set in updateMatchRoster() and updateMatchStatus
     * @param response The response body of the API request
     * @param err The error message of the API request
     */
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        bytes32 matchKey = requestToMatchKey[requestId];
        MatchBet storage mb = matchBets[matchKey];

        // Request ownership validation (prevents cross-match corruption)
        if (mb.requestId != requestId) {
            revert FragBoxBetting__InvalidRequest(requestId);
        }

        if (err.length > 0) {
            revert FragBoxBetting__FaceitAPIUnavailable();
        }

        string memory json = string(response);

        string memory responseType = _getJsonValue(json, "type");
        string memory status = _getJsonValue(json, "status");
        string memory winner = _getJsonValue(json, "winner");
        string memory f1Csv = _getJsonValue(json, "f1");
        string memory f2Csv = _getJsonValue(json, "f2");

        if (_compareStrings(responseType, "roster")) {
            uint256 playersAdded = _addPlayersFromCsv(mb, f1Csv, Faction.Faction1);
            playersAdded += _addPlayersFromCsv(mb, f2Csv, Faction.Faction2);

            _cleanInvalidBets(mb); // removes invalid bets (sets amount = 0)

            mb.rosterValidated = true;
            mb.status = status;
            mb.lastRosterUpdate = block.timestamp;
            mb.lastStatusUpdate = block.timestamp;

            emit RosterUpdated(matchKey, playersAdded);
        } else if (_compareStrings(responseType, "status")) {
            mb.status = status;
            mb.lastStatusUpdate = block.timestamp;

            if (_compareStrings(status, "FINISHED")) {
                mb.winnerFaction = _toFaction(winner);
                mb.resolved = true;
            }
        }

        emit RequestFulfilled(requestId, matchKey, status, winner);
    }

    /**
     * Checks if a match has completed and pays out based on the victor.
     * Payouts are calculated based on how much each player deposited (wagered).
     * So a player who wagered $20 when their team total is $100 will get 20% of the prize pot
     * @param matchIdStr Match id to check
     */
    function claim(string calldata matchIdStr) external nonReentrant {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (!mb.resolved) {
            revert FragBoxBetting__MatchNotResolved(matchKey);
        }
        if (mb.claimed) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }
        if (!_compareStrings(mb.status, "FINISHED")) {
            revert FragBoxBetting__MatchNotFinished();
        }

        uint256 totalWinningBet = 0;
        uint256 betsLength = mb.bets.length;

        // First pass: calculate total winning bets
        for (uint256 i = 0; i < betsLength; i++) {
            if (mb.bets[i].faction == mb.winnerFaction) {
                totalWinningBet += mb.bets[i].amount;
            }
        }

        if (totalWinningBet == 0 || mb.totalBetAmount == 0) {
            mb.claimed = true;
            emit MatchClaimed(matchKey);
            return;
        }

        uint256 totalPot = mb.totalBetAmount;

        // Second pass: Distribute winnings proportionally
        for (uint256 i = 0; i < betsLength; i++) {
            Bet storage bet = mb.bets[i];

            if (bet.faction == mb.winnerFaction && bet.amount > 0) {
                // Proportional payout: (my bet / total winning bets) * entire pot
                uint256 payout = (bet.amount * totalPot) / totalWinningBet;

                if (payout > 0) {
                    Address.sendValue(payable(bet.wallet), payout);
                }

                bet.amount = 0; // Prevent double payout for this bet
            }
        }

        // Optional: delete the match data
        // delete matchBets[matchKey];

        mb.claimed = true;
        emit MatchClaimed(matchKey);
    }

    /**
     * Refund any bets that haven't completed in 24 hours
     * @param matchIdStr The matchId to check the status of
     */
    function emergencyRefund(string calldata matchIdStr) external nonReentrant {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved || mb.claimed) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }
        if (mb.lastStatusUpdate == 0) {
            revert FragBoxBetting__MatchNotRequested();
        }
        if (block.timestamp <= mb.lastStatusUpdate + TIMEOUT_DURATION) {
            revert FragBoxBetting__TimeoutNotReached();
        }

        // Refund all bets
        uint256 betsLength = mb.bets.length;
        for (uint256 i = 0; i < betsLength; i++) {
            Bet storage bet = mb.bets[i];
            uint256 amount = bet.amount;

            if (amount > 0) {
                Address.sendValue(payable(bet.wallet), amount);
                bet.amount = 0;
            }
        }

        mb.resolved = true;
        mb.claimed = true;

        emit EmergencyRefund(matchKey);
    }

    /**
     * Converts an amount of ETH to its equivalent $ amount using chainlink price feed oracles
     * @param amount The amount of ETH in wei
     * @return uint256 The $ amount equivalent of input parameter amount
     */
    function getUsdValueOfEth(uint256 amount) public view returns (uint256) {
        (, int256 price,,,) = I_ETHUSDPRICEFEED.staleCheckLatestRoundData();
        return (SafeCast.toUint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }
}
