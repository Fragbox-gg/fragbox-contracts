// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract FragBoxBetting is ReentrancyGuard, Ownable, FunctionsClient, Pausable {
    error FragBoxBetting__MatchAlreadyResolved(bytes32 matchKey);
    error FragBoxBetting__MatchNotResolved(bytes32 matchKey);
    error FragBoxBetting__NoBetsPlaced(bytes32 matchKey);
    error FragBoxBetting__TimeoutNotReached();
    error FragBoxBetting__MatchNotRequested();
    error FragBoxBetting__BetTooSmall(uint256 amount);
    error FragBoxBetting__BetTooLarge(uint256 amount);
    error FragBoxBetting__RosterAlreadyRequested(bytes32 matchKey, string playerId);
    error FragBoxBetting__InvalidFaction(string factionStr);
    error FragBoxBetting__MatchIsFinishedOrOngoing();
    error FragBoxBetting__MatchNotFinished();
    error FragBoxBetting__InvalidRequest(bytes32 requestId);
    error FragBoxBetting__PlayerNotInMatch(string matchId, string playerId);
    error FragBoxBetting__SecretsNotSet();
    error FragBoxBetting__NoWinnings();
    error FragBoxBetting__StatusUpdateTooSoon();
    error FragBoxBetting__RosterUpdateTooSoon();
    error FragBoxBetting__NonOwnerFeeRequired(uint256 fee);

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant TIMEOUT_DURATION = 24 hours;
    uint256 private constant HOUSE_FEE_PERCENTAGE = 1; // 1 = 1%
    uint256 private constant PERCENTAGE_BASE = 100;
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 private constant MIN_BET_AMOUNT_IN_USD = 3 ether;
    uint256 private constant MAX_BET_AMOUNT_IN_USD = 3000 ether;
    uint256 private constant STATUS_UPDATE_COOLDOWN = 5 minutes;
    uint256 private constant ROSTER_UPDATE_COOLDOWN = 10 minutes;
    uint256 public constant MIN_STATUS_UPDATE_FEE_USD = 20 ether;

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

        // === GAS OPTIMIZATIONS ===
        uint256[4] factionTotals; // 1 = Faction1 total, 2 = Faction2, 3 = Draw
        mapping(bytes32 => uint256) betIndex; // keccak256(wallet, playerId, factionId) => index+1 in bets[]

        Faction winnerFaction; // "" = pending, "faction1"/"faction2"/"draw"
        bool resolved; // this is true when a victor has been set/the match has finished
        bool claimed; // this is true when a match's bets have been paid out
        bytes32 statusRequestId;
        uint256 totalBetAmount;

        mapping(string playerId => Faction playerFaction) playerToFaction; // playerId => Faction (Unknown = invalid/not present)
        mapping(string playerId => uint256 lastRosterUpdate) playerToLastRosterUpdate;
        uint256 lastRosterUpdate; // timestamp of last successful update

        string status; // "READY", "ONGOING", "FINISHED"
        uint256 lastStatusUpdate;
    }

    /* ---------- VIEW STRUCT (no mapping -> can be returned in memory) ---------- */
    struct MatchBetView {
        Bet[] bets;
        Faction winnerFaction;
        bool resolved;
        bool claimed;
        bytes32 statusRequestId;
        uint256 totalBetAmount;
        uint256 lastRosterUpdate;
        string status;
        uint256 lastStatusUpdate;
    }

    mapping(bytes32 matchKey => MatchBet matchBet) private matchBets;
    mapping(bytes32 requestId => bytes32 matchKey) private requestToMatchKey;
    mapping(string playerId => mapping(address wallet => uint256 winnings)) private playerToWinnings;

    AggregatorV3Interface private immutable I_ETHUSDPRICEFEED;
    address private immutable I_CHAINLINKFUNCTIONSROUTER;
    bytes32 private immutable I_DONID;
    uint64 private immutable I_SUBSCRIPTIONID;
    string private I_GETROSTER;
    string private I_GETSTATUS;

    event BetPlaced(bytes32 indexed matchKey, address indexed better, uint256 amount, string playerId);
    event RequestSent(bytes32 indexed requestId, bytes32 indexed matchKey);
    event RequestFulfilled(bytes32 indexed requestId, bytes32 indexed matchKey, string status, string winnerFaction);
    event EmergencyRefund(bytes32 indexed matchKey);
    event MatchClaimed(bytes32 indexed matchKey);
    event RosterUpdated(bytes32 indexed matchKey, string playerId, Faction playerFaction);
    event WinningsWithdrawn(string indexed playerId, address wallet, uint256 amount);

    uint8 private donHostedSecretsSlotId;
    uint64 private donHostedSecretsVersion;
    uint256 private ownerFeesCollected;

    /**
     * Specifies the necessary parameters to use chainlink functions DON-hosted secrets (faceit API key)
     * @param _slotId The slotId associated with the secret
     * @param _version The version of the secret
     */
    function updateDonSecrets(uint8 _slotId, uint64 _version) external onlyOwner {
        donHostedSecretsSlotId = _slotId;
        donHostedSecretsVersion = _version;
    }

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
     * @dev Extracts the raw value for a key (works for both "string" and 123 values)
     * @param json The response body
     * @param key The value you're looking for
     * @return The value associated with the key inside of the json
     */
    function _extractRawJsonValue(string memory json, string memory key) internal pure returns (string memory) {
        bytes memory data = bytes(json);
        bytes memory prefix = bytes(string.concat('"', key, '":'));

        for (uint256 i = 0; i <= data.length - prefix.length; i++) {
            if (_memcmp(data, i, prefix)) {
                uint256 start = i + prefix.length;
                uint256 end = start;

                if (end < data.length && data[end] == '"') {
                    // String value → skip opening quote
                    start = end + 1;
                    end = start;
                    while (end < data.length && data[end] != '"') end++;
                } else {
                    // Number, boolean, or null → stop at , } or ]
                    while (end < data.length && data[end] != "," && data[end] != "}" && data[end] != "]") end++;
                }

                bytes memory value = new bytes(end - start);
                for (uint256 k = 0; k < value.length; k++) {
                    value[k] = data[start + k];
                }
                return string(value);
            }
        }
        return "";
    }

    /**
     * @notice Compares a slice of `a` starting at `offset` with the full contents of `b` for exact byte equality.
     * @dev Behaves like a lightweight `memcmp` on a subarray. Returns `false` immediately if the slice would
     *      overrun `a`. Pure function – no state reads/writes.
     * @param a The source byte array to read from
     * @param offset Zero-based index in `a` where the comparison should begin
     * @param b The byte array to compare against (its full length is used)
     * @return bool `true` if every byte matches and the slice fits inside `a`; otherwise `false`
     */
    function _memcmp(bytes memory a, uint256 offset, bytes memory b) internal pure returns (bool) {
        if (a.length < offset + b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[offset + i] != b[i]) return false;
        }
        return true;
    }

    /**
     * Wrapper function for extracting string parameters in a JSON string
     * @param json The response body
     * @param key The value you're looking for
     * @return The string value associated with the key inside of the json
     */
    function _getJsonString(string memory json, string memory key) internal pure returns (string memory) {
        return _extractRawJsonValue(json, key);
    }

    /**
     * Wrapper function for extracting integer parameters in a JSON string
     * @param json The response body
     * @param key The value you're looking for
     * @return The integer value associated with the key inside of the json if it exists
     */
    function _getJsonUint(string memory json, string memory key) internal pure returns (uint256) {
        string memory raw = _extractRawJsonValue(json, key);
        if (bytes(raw).length == 0) return 0;

        (bool success, uint256 value) = Strings.tryParseUint(raw);
        if (!success) {
            return 0;
        }
        return value;
    }

    /**
     * Wrapper function for extracting boolean parameters in a JSON string
     * @param json The response body
     * @param key The value you're looking for
     * @return The boolean value associated with the key inside of the json if it exists
     */
    function _getJsonBool(string memory json, string memory key) internal pure returns (bool) {
        string memory raw = _extractRawJsonValue(json, key);
        if (bytes(raw).length == 0) return false;

        bytes32 h = keccak256(bytes(raw));
        return h == keccak256("true") || h == keccak256("1");
    }

    /**
     * Creates a composite key for fast O(1) bet lookup/top-up/cleanup
     * Format: keccak256(wallet, playerId, factionId)
     * @param wallet The wallet associated with the bet
     * @param playerId The playerId associated with the bet
     * @param factionId The faction associated with the bet
     */
    function _getBetKey(address wallet, string calldata playerId, uint8 factionId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(wallet, playerId, factionId));
    }

    /**
     * Creates a composite key for fast O(1) bet lookup/top-up/cleanup
     * Format: keccak256(wallet, playerId, factionId)
     * @param wallet The wallet associated with the bet
     * @param playerId The playerId associated with the bet
     * @param factionId The faction associated with the bet
     */
    function _getBetKey(address wallet, string storage playerId, uint8 factionId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(wallet, playerId, factionId));
    }

    /**
     * Performs all the necessary steps to remove a Bet from its parent MatchBet object and refund it to the original bettor
     * @param mb The parent match bet object
     * @param index The index of the bet object to remove and refund
     * @param shouldRefundToBettor Should the original bet amount be allocated to the original bettors winnings?
     */
    function _removeBet(MatchBet storage mb, uint256 index, bool shouldRefundToBettor) internal {
        Bet storage bet = mb.bets[index];
        uint256 betAmount = bet.amount;

        if (betAmount == 0) {
            delete mb.betIndex[_getBetKey(bet.wallet, bet.playerId, uint8(bet.faction))];
            return;
        }

        uint8 fId = uint8(bet.faction);
        bytes32 betKey = _getBetKey(bet.wallet, bet.playerId, fId);

        mb.factionTotals[fId] -= betAmount;
        mb.totalBetAmount -= betAmount;

        // Refund logic
        if (shouldRefundToBettor) {
            playerToWinnings[bet.playerId][bet.wallet] += betAmount;
        }

        // Cleanup
        delete mb.betIndex[betKey];
        delete mb.bets[index]; // zero the slot before swap

        // Swap-and-pop to keep array tight
        uint256 lastIndex = mb.bets.length - 1;
        if (index != lastIndex) {
            mb.bets[index] = mb.bets[lastIndex];
            // Update the moved bet's index in the mapping
            bytes32 movedKey = _getBetKey(mb.bets[index].wallet, mb.bets[index].playerId, uint8(mb.bets[index].faction));
            mb.betIndex[movedKey] = index + 1; // 1-based
        }
        mb.bets.pop();

        // Zero the original bet (already done by pop)
    }

    /**
     * Refunds bets that have invalid parameters, such as a player not belonging to the correct faction based on the data from the faceit API
     * @param mb The match bet to clean
     */
    function _cleanInvalidBets(MatchBet storage mb) internal {
        uint256 i = mb.bets.length;
        while (i > 0) {
            i--;
            Bet storage bet = mb.bets[i];

            // Ignore players that haven't been validated yet
            if (mb.playerToLastRosterUpdate[bet.playerId] == 0) continue;

            Faction correct = mb.playerToFaction[bet.playerId];
            if (correct == Faction.Unknown || correct != bet.faction) {
                _removeBet(mb, i, true); // safe because we go backwards
            }
        }
    }

    constructor(
        address ethUsdPriceFeed,
        address chainLinkFunctionsRouter,
        bytes32 donId,
        uint64 subscriptionId,
        string memory getRoster,
        string memory getStatus
    ) Ownable(msg.sender) FunctionsClient(chainLinkFunctionsRouter) {
        I_ETHUSDPRICEFEED = AggregatorV3Interface(ethUsdPriceFeed);
        I_CHAINLINKFUNCTIONSROUTER = chainLinkFunctionsRouter;
        I_DONID = donId;
        I_SUBSCRIPTIONID = subscriptionId;
        I_GETROSTER = getRoster;
        I_GETSTATUS = getStatus;
    }

    /**
     * Called on first player deposit for a match
     * @notice This sends a request to chainlink functions to verify that the playerid and faction are valid (in the match and on the right team)
     * @param matchIdStr The match Id to check
     */
    function updateMatchRoster(string calldata matchIdStr, string calldata playerId) internal whenNotPaused {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.playerToFaction[playerId] != Faction.Unknown) {
            revert FragBoxBetting__RosterAlreadyRequested(matchKey, playerId);
        }
        if (donHostedSecretsVersion == 0) revert FragBoxBetting__SecretsNotSet();

        if (block.timestamp - ROSTER_UPDATE_COOLDOWN < mb.playerToLastRosterUpdate[playerId] + ROSTER_UPDATE_COOLDOWN) {
            revert FragBoxBetting__RosterUpdateTooSoon();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(I_GETROSTER);

        string[] memory args = new string[](2);
        args[0] = matchIdStr;
        args[1] = playerId;
        req.setArgs(args);

        req.addDONHostedSecrets(donHostedSecretsSlotId, donHostedSecretsVersion);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), I_SUBSCRIPTIONID, CALLBACK_GAS_LIMIT, I_DONID);

        requestToMatchKey[requestId] = matchKey;
        emit RequestSent(requestId, matchKey);
    }

    modifier costsFeeOrOwner() {
        if (msg.sender != owner()) {
            // Require some ETH is sent (basic protection)
            if (msg.value == 0) revert FragBoxBetting__NonOwnerFeeRequired(MIN_STATUS_UPDATE_FEE_USD);

            uint256 usdValueWei = getUsdValueOfEth(msg.value);
            if (usdValueWei < MIN_STATUS_UPDATE_FEE_USD) {
                revert FragBoxBetting__NonOwnerFeeRequired(MIN_STATUS_UPDATE_FEE_USD);
            }

            // Accumulate the fee (you could also send to owner instantly, but accumulating is fine)
            ownerFeesCollected += msg.value;
        }
        // No refund logic here — we accept exact or overpayment (common pattern)
        _;
    }

    /**
     * Called REPEATEDLY by backend to update match status
     * @notice Need to setup a CRON job or Chainlink automation to routinely call this based on active matchIds that users bet on
     * @param matchIdStr The match Id to check
     */
    function updateMatchStatus(string calldata matchIdStr) external payable whenNotPaused costsFeeOrOwner {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved || mb.claimed) revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        if (donHostedSecretsVersion == 0) revert FragBoxBetting__SecretsNotSet();

        if (block.timestamp - STATUS_UPDATE_COOLDOWN < mb.lastStatusUpdate + STATUS_UPDATE_COOLDOWN) {
            revert FragBoxBetting__StatusUpdateTooSoon();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(I_GETSTATUS);

        string[] memory args = new string[](1);
        args[0] = matchIdStr;
        req.setArgs(args);

        req.addDONHostedSecrets(donHostedSecretsSlotId, donHostedSecretsVersion);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), I_SUBSCRIPTIONID, CALLBACK_GAS_LIMIT, I_DONID);

        mb.statusRequestId = requestId;
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
        whenNotPaused
    {
        uint256 usdValueOfEth = getUsdValueOfEth(msg.value);
        if (usdValueOfEth < MIN_BET_AMOUNT_IN_USD) revert FragBoxBetting__BetTooSmall(msg.value);
        if (usdValueOfEth > MAX_BET_AMOUNT_IN_USD) revert FragBoxBetting__BetTooLarge(msg.value);

        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved || mb.claimed) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }

        Faction chosenFaction = _toFaction(factionStr);
        if (chosenFaction == Faction.Unknown) {
            revert FragBoxBetting__InvalidFaction(factionStr);
        }

        if (_compareStrings(mb.status, "ONGOING") || _compareStrings(mb.status, "FINISHED")) {
            revert FragBoxBetting__MatchIsFinishedOrOngoing();
        }

        // Hard validation - only revert after roster has been fetched at least once. If faction is wrong this bet will be destroyed later in fulfillRequest
        Faction actual = mb.playerToFaction[playerId];
        bool rosterHasBeenValidated = true;
        if (actual == Faction.Unknown) {
            rosterHasBeenValidated = false;
        } else if (actual != chosenFaction) {
            revert FragBoxBetting__PlayerNotInMatch(matchIdStr, playerId);
        }

        // Calculate house fee and actual bet amount
        uint256 fee = (msg.value * HOUSE_FEE_PERCENTAGE) / PERCENTAGE_BASE;
        uint256 betAmount = msg.value - fee;

        // Send fee to owner
        ownerFeesCollected += fee;

        // O(1) lookup for top-up (much cheaper than nested mapping)
        uint8 fId = uint8(chosenFaction);
        bytes32 betKey = _getBetKey(msg.sender, playerId, fId);
        uint256 existingIdx = mb.betIndex[betKey];

        if (existingIdx > 0) {
            // Top-up existing bet
            mb.bets[existingIdx - 1].amount += betAmount;
        } else {
            // New bet
            mb.bets.push(Bet({wallet: msg.sender, playerId: playerId, faction: chosenFaction, amount: betAmount}));
            mb.betIndex[betKey] = mb.bets.length; // 1-based index
        }

        // Update totals
        mb.factionTotals[fId] += betAmount;
        mb.totalBetAmount += betAmount;

        emit BetPlaced(matchKey, msg.sender, betAmount, playerId);

        if (!rosterHasBeenValidated) {
            updateMatchRoster(matchIdStr, playerId);
        }
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

        if (err.length > 0) {
            emit RequestFulfilled(requestId, matchKey, "ERROR", string(err));
            return;
        }

        string memory json = string(response);
        string memory responseType = _getJsonString(json, "type");

        // Request ownership validation (prevents stale data corruption)
        if (_compareStrings(responseType, "status")) {
            if (mb.statusRequestId != requestId) {
                emit RequestFulfilled(requestId, matchKey, "ERROR", "Stale Status Request Id");
                return;
            }
        }

        if (_compareStrings(responseType, "roster")) {
            string memory playerId = _getJsonString(json, "playerId");
            bool playerValid = _getJsonBool(json, "valid");

            mb.playerToLastRosterUpdate[playerId] = block.timestamp;

            if (!playerValid) {
                emit RequestFulfilled(requestId, matchKey, "ERROR", string.concat("Invalid player id ", playerId));
                return;
            }

            uint256 playerFactionRaw = _getJsonUint(json, "faction");
            Faction playerFaction = Faction(SafeCast.toUint8(playerFactionRaw));

            mb.playerToFaction[playerId] = playerFaction;
            mb.lastRosterUpdate = block.timestamp;

            emit RosterUpdated(matchKey, playerId, playerFaction);
        } else if (_compareStrings(responseType, "status")) {
            string memory status = _getJsonString(json, "status");
            string memory winner = _getJsonString(json, "winner");

            mb.status = status;
            mb.lastStatusUpdate = block.timestamp;

            if (_compareStrings(status, "FINISHED")) {
                mb.winnerFaction = _toFaction(winner);
                mb.resolved = true;
            }

            emit RequestFulfilled(requestId, matchKey, status, winner);
        }
    }

    /**
     * Checks if a match has completed and pays out based on the victor.
     * Payouts are calculated based on how much each player deposited (wagered).
     * So a player who wagered $20 when their team total is $100 will get 20% of the prize pot
     * @param matchIdStr Match id to check
     */
    function claim(string calldata matchIdStr) external nonReentrant whenNotPaused {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (!mb.resolved) revert FragBoxBetting__MatchNotResolved(matchKey);
        if (mb.claimed) revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        if (mb.lastRosterUpdate == 0 || mb.lastStatusUpdate == 0) revert FragBoxBetting__MatchNotRequested();
        if (!_compareStrings(mb.status, "FINISHED")) revert FragBoxBetting__MatchNotFinished();

        _cleanInvalidBets(mb); // one pass to clean invalids

        uint256 totalWinningBet = (mb.winnerFaction == Faction.Unknown || mb.winnerFaction == Faction.Draw)
            ? 0
            : mb.factionTotals[uint8(mb.winnerFaction)];

        uint256 totalPot = mb.totalBetAmount;

        uint256 i = 0;
        if (totalWinningBet == 0) {
            // No one bet on winner -> refund everyone (loop backwards)
            i = mb.bets.length;
            while (i > 0) {
                i--;
                _removeBet(mb, i, true);
            }
            mb.claimed = true;
            emit MatchClaimed(matchKey);
            return;
        }

        if (totalPot == 0) {
            mb.claimed = true;
            emit MatchClaimed(matchKey);
            return;
        }

        // Single pass payout + cleanup
        uint256 remainder = totalPot;
        i = mb.bets.length;
        while (i > 0) {
            i--;
            Bet storage bet = mb.bets[i];

            if (bet.faction != mb.winnerFaction || bet.amount == 0) {
                // non-winner or already zeroed -> remove it
                _removeBet(mb, i, false);
                continue;
            }

            // Winner bet -> proportional payout
            uint256 payout = (bet.amount * totalPot) / totalWinningBet;
            if (payout > 0) {
                playerToWinnings[bet.playerId][bet.wallet] += payout;
                remainder -= payout;
            }
            _removeBet(mb, i, false); // this also zeros and removes from array
        }

        if (remainder > 0) {
            ownerFeesCollected += remainder;
        }

        mb.claimed = true;
        emit MatchClaimed(matchKey);
    }

    /**
     * Refund any bets that haven't completed in 24 hours
     * @param matchIdStr The matchId to check the status of
     */
    function emergencyRefund(string calldata matchIdStr) external nonReentrant whenNotPaused {
        bytes32 matchKey = _getMatchKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved || mb.claimed) {
            revert FragBoxBetting__MatchAlreadyResolved(matchKey);
        }
        if (mb.lastRosterUpdate == 0 || mb.lastStatusUpdate == 0) {
            revert FragBoxBetting__MatchNotRequested();
        }
        if (block.timestamp <= mb.lastStatusUpdate + TIMEOUT_DURATION) {
            revert FragBoxBetting__TimeoutNotReached();
        }

        // Refund all bets
        uint256 i = mb.bets.length;
        while (i > 0) {
            i--;
            _removeBet(mb, i, true);
        }

        mb.resolved = true;
        mb.claimed = true;

        emit EmergencyRefund(matchKey);
    }

    /**
     * Allows a player to withdraw their winnings from the contract
     * @param playerId The player id the sender wallet is associated with
     */
    function withdraw(string memory playerId) external nonReentrant whenNotPaused {
        uint256 winningsAmount = playerToWinnings[playerId][msg.sender];
        if (winningsAmount == 0) {
            revert FragBoxBetting__NoWinnings();
        }
        playerToWinnings[playerId][msg.sender] -= winningsAmount;
        Address.sendValue(payable(msg.sender), winningsAmount);
        emit WinningsWithdrawn(playerId, msg.sender, winningsAmount);
    }

    /**
     * Allows the owner to withdraw collected deposit fees
     */
    function withdrawOwnerFees() external onlyOwner {
        uint256 amount = ownerFeesCollected;
        ownerFeesCollected = 0;
        Address.sendValue(payable(owner()), amount);
    }

    /* -------------------------------- PAUSABLE -------------------------------- */
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /* -------------------------------------------------------------------------- */
    /*                                   GETTERS                                  */
    /* -------------------------------------------------------------------------- */

    /**
     * Gets the price of ETH in USD
     * @return The price of ETH in USD wei
     */
    function getEthUsdPrice() public view returns (uint256) {
        (, int256 price,,,) = I_ETHUSDPRICEFEED.staleCheckLatestRoundData();
        return SafeCast.toUint256(price) * ADDITIONAL_FEED_PRECISION;
    }

    /**
     * Converts an amount of ETH to its equivalent $ amount using chainlink price feed oracles
     * @param amount The amount of ETH in wei
     * @return uint256 The $ amount equivalent of input parameter amount
     */
    function getUsdValueOfEth(uint256 amount) public view returns (uint256) {
        return (getEthUsdPrice() * amount) / PRECISION;
    }

    /**
     * Converts the match id string into a bytes object for gas savings
     * @param matchIdStr The match id string to convert
     * @return The match key
     */
    function getMatchKey(string memory matchIdStr) external pure returns (bytes32) {
        return keccak256(bytes(matchIdStr));
    }

    /**
     * Returns all non-mapping data for a match in one clean struct
     * @param matchKey The match id to get data for
     * @return A MatchBetView struct which contains everything in MatchBet without the mappings
     */
    function getMatchBet(bytes32 matchKey) external view returns (MatchBetView memory) {
        MatchBet storage mb = matchBets[matchKey];
        return MatchBetView({
            bets: mb.bets,
            winnerFaction: mb.winnerFaction,
            resolved: mb.resolved,
            claimed: mb.claimed,
            statusRequestId: mb.statusRequestId,
            totalBetAmount: mb.totalBetAmount,
            lastRosterUpdate: mb.lastRosterUpdate,
            status: mb.status,
            lastStatusUpdate: mb.lastStatusUpdate
        });
    }

    /**
     * This lets you access a player's faction based on a match bet's mapping
     * @param matchKey The match the player is in
     * @param playerId The player to get the faction of
     * @return Returns the Faction a player belongs to
     */
    function getPlayerFaction(bytes32 matchKey, string calldata playerId) external view returns (Faction) {
        return matchBets[matchKey].playerToFaction[playerId];
    }

    /**
     * Gets the amount of winnings a player has earned but hasn't withdrawn in wei
     * @param playerId The player who earned the winnings and is associated with the msg.sender
     * @return The winnings in wei
     */
    function getWinnings(string calldata playerId) external view returns (uint256) {
        return playerToWinnings[playerId][msg.sender];
    }

    /**
     * Gets the amount of owner fees accumulated that hasn't been withdrawn yet
     * @return The amount in wei
     */
    function getOwnerFees() external view onlyOwner returns (uint256) {
        return ownerFeesCollected;
    }
}
