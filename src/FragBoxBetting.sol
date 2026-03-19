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
    error FragBoxBetting__NeedsMoreThanZero();
    error FragBoxBetting__MatchAlreadyResolved(bytes32 matchKey);
    error FragBoxBetting__NoBetsPlaced(bytes32 matchKey);
    error FragBoxBetting__FaceitAPIUnavailable();
    error FragBoxBetting__TimeoutNotReached();

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant TIMEOUT_DURATION = 24 hours;
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;

    // Faceit API protection (if API is down or match not finished)
    string private constant SOURCE = "const matchId = args[0];" "const res = await Functions.makeHttpRequest({"
        "  url: `https://open.faceit.com/data/v4/matches/${matchId}`" "});"
        "if (res.error) throw Error('Faceit API unavailable');" "const data = res.data;"
        "if (data.status !== 'finished') throw Error('Match not finished');"
        "let winner = data.results.winner || 'draw';"
        "if (data.results.score.faction1 === data.results.score.faction2) winner = 'draw';"
        "return Functions.encodeString(winner);";

    struct Bet {
        address wallet;
        string playerId; // kept as string (user-controlled, not used as key)
        string faction; // "faction1", "faction2", or "draw"
        uint256 amount;
    }

    struct MatchBet {
        Bet[] bets;
        string winnerFaction; // "" = pending, "faction1"/"faction2"/"draw"
        bool resolved;
        bytes32 requestId;
        uint256 requestTimestamp;
    }

    mapping(bytes32 => MatchBet) public matchBets;
    mapping(bytes32 => bytes32) public requestToMatchKey; // requestId => matchKey (bytes32)

    AggregatorV3Interface private immutable I_ETHUSDPRICEFEED;
    address private immutable I_CHAINLINKFUNCTIONSROUTER;
    bytes32 private immutable I_DONID;
    uint64 private immutable I_SUBSCRIPTIONID;
    address private immutable I_LINKTOKEN;

    event RequestSent(bytes32 indexed requestId, bytes32 indexed matchKey);
    event RequestFulfilled(bytes32 indexed requestId, string winnerFaction);
    event EmergencyRefund(bytes32 indexed matchKey);

    modifier moreThanZero(uint256 amount) {
        _moreThanZero(amount);
        _;
    }

    function _moreThanZero(uint256 amount) internal pure {
        if (amount <= 0) {
            revert FragBoxBetting__NeedsMoreThanZero();
        }
    }

    /**
     * Converts the match id string into a bytes object for gas savings
     * @param matchIdStr The match id string to convert
     */
    function _getMatchKey(string calldata matchIdStr) internal pure returns (bytes32) {
        return keccak256(bytes(matchIdStr));
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
     * Place Bet on an ongoing faceit match that you are a part of
     * @param matchIdStr The id of the match the player is betting on
     * @param playerId The id of the player who is placing the bet
     * @param faction The faction of the player who is placing the bet
     */
    function deposit(string calldata matchIdStr, string calldata playerId, string calldata faction)
        external
        payable
        nonReentrant
        moreThanZero(msg.value)
    {
        bytes32 matchKey = _getMatchKey(matchIdStr);

        MatchBet storage mb = matchBets[matchKey];

        if (bytes(mb.winnerFaction).length != 0) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }

        mb.bets.push(Bet({wallet: msg.sender, playerId: playerId, faction: faction, amount: msg.value}));
    }

    /**
     * Ask the chainlink functions oracle to check the API status of a match
     * @param matchIdStr The matchId of the faceit match you want to check
     */
    function requestResolution(string calldata matchIdStr) external {
        bytes32 matchKey = _getMatchKey(matchIdStr);

        MatchBet storage mb = matchBets[matchKey];

        if (bytes(mb.winnerFaction).length != 0) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }
        if (mb.bets.length == 0) {
            revert FragBoxBetting__NoBetsPlaced(matchKey);
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(SOURCE);

        string[] memory args = new string[](1);
        args[0] = matchIdStr; // Chainlink Functions still expects string
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), I_SUBSCRIPTIONID, CALLBACK_GAS_LIMIT, I_DONID);

        mb.requestId = requestId;
        mb.requestTimestamp = block.timestamp;
        requestToMatchKey[requestId] = matchKey;

        emit RequestSent(requestId, matchKey);
    }

    /**
     * The chainlink functions oracle calls this function when it finishes calling the faceit API
     * @param requestId The Id of the chainlink functions oracle request. Set in requestResolution()
     * @param response The response body of the API request
     * @param err The error message of the API request
     */
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        bytes32 matchKey = requestToMatchKey[requestId];

        if (err.length > 0) {
            revert FragBoxBetting__FaceitAPIUnavailable();
        }

        string memory winnerFaction = string(response);

        MatchBet storage mb = matchBets[matchKey];
        mb.winnerFaction = winnerFaction;
        mb.resolved = true;

        emit RequestFulfilled(requestId, winnerFaction);
    }

    // Placeholder for claim — let me know if you want this refactored too
    function claim(string calldata matchIdStr) external nonReentrant {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        // ... your payout logic using matchId ...
    }

    /**
     * Refund any bets that haven't completed in 24 hours
     * @param matchIdStr The matchId to check the status of
     */
    function emergencyRefund(string calldata matchIdStr) external {
        bytes32 matchKey = _getMatchKey(matchIdStr);

        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }
        if (block.timestamp <= mb.requestTimestamp + TIMEOUT_DURATION) {
            revert FragBoxBetting__TimeoutNotReached();
        }

        // Refund all bets
        for (uint256 i = 0; i < mb.bets.length; i++) {
            Address.sendValue(payable(mb.bets[i].wallet), mb.bets[i].amount);
            mb.bets[i].amount = 0;
        }
        mb.resolved = true;
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

    /**
     * Gets the match bet information for a given match id
     * @param matchKey The id of the match in the faceit data API
     */
    function getMatchBet(bytes32 matchKey) external view returns (MatchBet memory) {
        return matchBets[matchKey];
    }

    /**
     * Gets the match bet information for a given match id
     * @param matchIdStr The id of the match in the faceit data API
     */
    function getMatchBet(string calldata matchIdStr) external view returns (MatchBet memory) {
        return matchBets[_getMatchKey(matchIdStr)];
    }
}
