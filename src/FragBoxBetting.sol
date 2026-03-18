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
    error FragBoxBetting__MatchAlreadyResolved(string matchId);
    error FragBoxBetting__NoBetsPlaced(string matchId);
    error FragBoxBetting__FaceitAPIUnavailable();

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
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
        string playerId;
        string faction; // "faction1" or "faction2"
        uint256 amount;
    }

    struct MatchBet {
        Bet[] bets;
        string winnerFaction; // "" = pending, "faction1"/"faction2"/"draw"
        bool resolved;
        bytes32 requestId;
        uint256 requestTimestamp;
    }

    mapping(string => MatchBet) public matchBets;
    mapping(bytes32 => string) public requestToMatchId;

    AggregatorV3Interface private immutable I_ETHUSDPRICEFEED;
    address private immutable I_CHAINLINKFUNCTIONSROUTER;
    bytes32 private immutable I_DONID;
    uint64 private immutable I_SUBSCRIPTIONID;
    address private immutable I_LINKTOKEN;

    event RequestSent(bytes32 indexed requestId, string matchId);
    event RequestFulfilled(bytes32 indexed requestId, string winnerFaction);
    event EmergencyRefund(string matchId);

    modifier moreThanZero(uint256 amount) {
        _moreThanZero(amount);
        _;
    }

    function _moreThanZero(uint256 amount) internal pure {
        if (amount <= 0) {
            revert FragBoxBetting__NeedsMoreThanZero();
        }
    }

    constructor(
        address ethUsdPriceFeed,
        address chainLinkFunctionsRouter,
        bytes32 donId,
        uint64 subscriptionId,
        address linkToken
    ) Ownable(msg.sender) FunctionsClient(msg.sender) {
        I_ETHUSDPRICEFEED = AggregatorV3Interface(ethUsdPriceFeed);
        I_CHAINLINKFUNCTIONSROUTER = chainLinkFunctionsRouter;
        I_DONID = donId;
        I_SUBSCRIPTIONID = subscriptionId;
        I_LINKTOKEN = linkToken;
    }

    function deposit(string calldata matchId, string calldata playerId, string calldata faction)
        external
        payable
        nonReentrant
        moreThanZero(msg.value)
    {
        MatchBet storage mb = matchBets[matchId];

        if (bytes(mb.winnerFaction).length != 0) {
            revert FragBoxBetting__MatchAlreadyResolved(matchId);
        }

        mb.bets.push(Bet({wallet: msg.sender, playerId: playerId, faction: faction, amount: msg.value}));
    }

    function requestResolution(string calldata matchId) external {
        MatchBet storage mb = matchBets[matchId];

        if (bytes(mb.winnerFaction).length != 0) {
            revert FragBoxBetting__MatchAlreadyResolved(matchId);
        }

        if (mb.bets.length == 0) {
            revert FragBoxBetting__NoBetsPlaced(matchId);
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(SOURCE);
        string[] memory args = new string[](1);
        args[0] = matchId;
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), I_SUBSCRIPTIONID, CALLBACK_GAS_LIMIT, I_DONID);

        mb.requestId = requestId;
        mb.requestTimestamp = block.timestamp;
        requestToMatchId[requestId] = matchId;

        emit RequestSent(requestId, matchId);
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        string memory matchId = requestToMatchId[requestId];

        if (err.length > 0) {
            // Faceit API down or match not finished → revert the callback (no state change)
            revert FragBoxBetting__FaceitAPIUnavailable();
        }

        string memory winnerFaction = string(response);

        MatchBet storage mb = matchBets[matchId];
        mb.winnerFaction = winnerFaction;
        mb.resolved = true;

        emit RequestFulfilled(requestId, winnerFaction);
    }

    function claim(string calldata matchId) external nonReentrant {
        // ... (same payout logic you had before — winners get pot, losers 0, draw = refund)
        // I can paste the full claim if you want, just let me know
    }

    function emergencyRefund(string calldata matchId) external {
        MatchBet storage mb = matchBets[matchId];
        require(!mb.resolved, "Already resolved");
        require(block.timestamp > mb.requestTimestamp + 24 hours, "Timeout not reached");

        // Refund all bets
        for (uint256 i = 0; i < mb.bets.length; i++) {
            //payable(mb.bets[i].wallet).transfer(mb.bets[i].amount);
            Address.sendValue(payable(mb.bets[i].wallet), mb.bets[i].amount);
            mb.bets[i].amount = 0;
        }
        mb.resolved = true;
        emit EmergencyRefund(matchId);
    }

    function getUsdValueOfEth(uint256 amount) public view returns (uint256) {
        (, int256 price,,,) = I_ETHUSDPRICEFEED.staleCheckLatestRoundData();

        // 1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8

        return (SafeCast.toUint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }
}
