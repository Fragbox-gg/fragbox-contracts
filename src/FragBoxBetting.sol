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
    error FragBoxBetting__MatchNotResolved(bytes32 matchKey);
    error FragBoxBetting__NoBetsPlaced(bytes32 matchKey);
    error FragBoxBetting__FaceitAPIUnavailable();
    error FragBoxBetting__TimeoutNotReached();

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant TIMEOUT_DURATION = 24 hours;
    uint256 private constant DEPOSIT_FEE_PERCENTAGE = 1; // 1 = 1%
    uint256 private constant PERCENTAGE_BASE = 100;
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
        bool resolved; // this is true when a victor has been set/the match has finished
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
    event Claim(bytes32 indexed matchKey);

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

    /**
     * Compares the equality of 2 strings
     * @param a The first string
     * @param b The second string
     */
    function _compareStrings(string memory a, string memory b) internal view returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
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
     * Place Bet on an ongoing faceit match that you are a part of. This is where players pay their deposit fee so that we don't have to calculate fees during payout/resolution
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

        if (bytes(mb.winnerFaction).length != 0 || mb.resolved) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }

        uint256 fee = (msg.value * DEPOSIT_FEE_PERCENTAGE) / PERCENTAGE_BASE;
        uint256 depositAmount = msg.value - fee;
        Address.sendValue(payable(owner()), msg.value / DEPOSIT_FEE_PERCENTAGE);

        mb.bets.push(Bet({wallet: msg.sender, playerId: playerId, faction: faction, amount: depositAmount}));
    }

    /**
     * Ask the chainlink functions oracle to check the API status of a match
     * @param matchIdStr The matchId of the faceit match you want to check
     */
    function requestResolution(string calldata matchIdStr) external {
        bytes32 matchKey = _getMatchKey(matchIdStr);

        MatchBet storage mb = matchBets[matchKey];

        if (bytes(mb.winnerFaction).length != 0 || mb.resolved) {
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

        uint256 betsLength = mb.bets.length;
        uint256 losingFactionBetSum = 0;
        uint256 winningFactionBetSum = 0;
        payable[] memory winningWallets;
        for (uint256 i = 0; i < betsLength; i++) {
            Bet storage bet = mb.bets[i];
            if (_compareStrings(bet.faction, "faction1")) {
                if (_compareStrings(bet.winnerFaction, "faction1")) {
                    winningWallets.push(payable(bet.wallet));
                    winningFactionBetSum += bet.amount;
                } else if (_compareStrings(bet.winnerFaction, "faction2")) {
                    losingFactionBetSum += bet.amount;
                }
            }
            else if (_compareStrings(bet.faction, "faction2")) {
                if (_compareStrings(bet.winnerFaction, "faction2")) {
                    winningWallets.push(payable(bet.wallet));
                    winningFactionBetSum += bet.amount;
                } else if (_compareStrings(bet.winnerFaction, "faction1")) {
                    losingFactionBetSum += bet.amount;
                }
            }
        }

        uint256 winningWalletsLength = winningWallets.length;
        for (uint256 i = 0; i < winningWalletsLength; i++) {
            Address.sendValue(winningWallets[i], faction1BetSum / winningWalletsLength)
        }

        // Refund rest of funds stored for this match
        for (uint256 i = 0; i < betsLength; i++) {
            Address.sendValue(payable(mb.bets[i].wallet), mb.bets[i].amount);
            mb.bets[i].amount = 0;
        }

        emit Claim(matchKey);
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
