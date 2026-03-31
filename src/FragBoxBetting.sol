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
    /* -------------------------------------------------------------------------- */
    /*                                   ERRORS                                   */
    /* -------------------------------------------------------------------------- */
    error FragBoxBetting__MatchAlreadyFinished();
    error FragBoxBetting__MatchNotFinished();
    error FragBoxBetting__TimeoutNotReached();
    error FragBoxBetting__BetTooSmall();
    error FragBoxBetting__BetTooLarge();
    error FragBoxBetting__RosterAlreadyRequested();
    error FragBoxBetting__MatchIsFinishedOrOngoing();
    error FragBoxBetting__SecretsNotSet();
    error FragBoxBetting__StatusUpdateTooSoon();
    error FragBoxBetting__RosterUpdateTooSoon();
    error FragBoxBetting__NonOwnerFeeRequired();
    error FragBoxBetting__NoBetForPlayer();
    error FragBoxBetting__InsufficientFundsForWithdrawal();
    error FragBoxBetting__WinnerUnknown();
    error FragBoxBetting__LosingFactionCannotClaim(Faction faction);

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    /* -------------------------------------------------------------------------- */
    /*                                    ENUMS                                   */
    /* -------------------------------------------------------------------------- */
    enum Faction {
        Unknown,
        Faction1,
        Faction2,
        Draw
    }

    enum MatchStatus {
        Unknown,
        Voting,
        Ready,
        Ongoing,
        Finished
    }

    enum RequestType {
        Roster,
        Status
    }

    /* -------------------------------------------------------------------------- */
    /*                               CUSTOM STRUCTS                               */
    /* -------------------------------------------------------------------------- */
    struct BetAuthorization {
        bytes32 matchKey;
        string playerId;
        uint256 betAmount;
        uint256 nonce;
        uint256 deadline;
    }

    struct MatchBet {
        Faction winnerFaction;
        MatchStatus matchStatus;
        uint256[4] factionTotals; // 0 = Unknown, 1 = Faction1 total, 2 = Faction2, 3 = Draw
        uint256 lastStatusUpdate;
        bytes32 statusRequestId;

        mapping(address wallet => mapping(bytes32 playerKey => uint256 betAmount)) walletToPlayerIdToBet;
        mapping(bytes32 playerKey => Faction playerFaction) playerToFaction; // playerKey => Faction (Unknown = invalid/not present)
        mapping(bytes32 playerKey => uint256 lastRosterUpdate) playerToLastRosterUpdate;
    }

    /* ---------- VIEW STRUCT (no mapping -> can be returned in memory) ---------- */
    struct MatchBetView {
        Faction winnerFaction;
        MatchStatus matchStatus;
        uint256[4] factionTotals;
        uint256 lastStatusUpdate;
        bytes32 statusRequestId;
    }

    struct RequestInfo {
        RequestType requestType;
        bytes32 matchKey;
        bytes32 playerKey;
        uint256 betAmount;
        address wallet;
    }

    /* -------------------------------------------------------------------------- */
    /*                                   EVENTS                                   */
    /* -------------------------------------------------------------------------- */
    event BetPlaced(bytes32 indexed matchKey, address indexed better, uint256 amount, string playerId);
    event RequestSent(bytes32 indexed requestId, bytes32 indexed matchKey);
    event RequestFulfilled(
        bytes32 indexed requestId, bytes32 indexed matchKey, MatchStatus status, Faction winnerFaction
    );
    event RequestError(bytes32 indexed requestId, bytes32 indexed matchKey, string error);
    event EmergencyRefund(bytes32 indexed matchKey);
    event MatchClaimed(bytes32 indexed matchKey);
    event RosterUpdated(bytes32 indexed matchKey, bytes32 playerId, Faction playerFaction);
    event WinningsWithdrawn(string indexed playerId, address wallet, uint256 amount);
    event PermitSignerUpdated(address indexed oldSigner, address indexed newSigner);

    /* -------------------------------------------------------------------------- */
    /*                                  CONSTANTS                                 */
    /* -------------------------------------------------------------------------- */
    bytes32 public constant DEPOSIT_PERMIT_TYPEHASH = keccak256(
        "DepositPermit(bytes32 matchKey,string playerId,uint256 depositAmount,uint256 nonce,uint256 deadline)"
    );
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant TIMEOUT_DURATION = 24 hours;
    uint256 private constant HOUSE_FEE_PERCENTAGE = 1; // 1 = 1%
    uint256 private constant PERCENTAGE_BASE = 100;
    uint256 private constant STATUS_UPDATE_COOLDOWN = 5 minutes;
    uint256 private constant ROSTER_UPDATE_COOLDOWN = 10 minutes;
    uint256 private constant MIN_STATUS_UPDATE_FEE_USD = 20 ether;
    uint256 private constant MIN_BET_AMOUNT_IN_USD = 3 ether;
    uint256 private constant MAX_BET_AMOUNT_IN_USD = 3000 ether;

    /* -------------------------------------------------------------------------- */
    /*                             IMMUTABLE VARIABLES                            */
    /* -------------------------------------------------------------------------- */
    AggregatorV3Interface private immutable I_ETHUSDPRICEFEED;
    address private immutable I_CHAINLINKFUNCTIONSROUTER;
    bytes32 private immutable I_DONID;
    uint64 private immutable I_SUBSCRIPTIONID;
    string private I_GETROSTER;
    string private I_GETSTATUS;

    /* -------------------------------------------------------------------------- */
    /*                              STORAGE VARIABLES                             */
    /* -------------------------------------------------------------------------- */
    mapping(bytes32 matchKey => MatchBet matchBet) private matchBets;
    mapping(bytes32 requestId => RequestInfo requestInfo) private requestIdToInfo;
    mapping(address wallet => uint256 amount) private betAmountsInRosterValidationFlight;
    mapping(address wallet => mapping(bytes32 playerKey => uint256 winnings)) private playerToWinnings;

    uint8 private donHostedSecretsSlotId;
    uint64 private donHostedSecretsVersion;
    uint256 private ownerFeesCollected;

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

    /* -------------------------------------------------------------------------- */
    /*                                  MODIFIERS                                 */
    /* -------------------------------------------------------------------------- */
    modifier costsFeeOrOwner(uint256 feeAmount) {
        _costsFeeOrOwner(feeAmount);
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                             INTERNAL FUNCTIONS                             */
    /* -------------------------------------------------------------------------- */
    /**
     * Checks if the caller has paid the required fee or is the owner
     * @param feeAmount The minimum fee necessary for the function (in USD with 18 decimals, e.g. 20 * 1e18 for $20)
     */
    function _costsFeeOrOwner(uint256 feeAmount) internal {
        if (msg.sender != owner()) {
            // Require some ETH is sent (basic protection)
            if (msg.value == 0) revert FragBoxBetting__NonOwnerFeeRequired();

            uint256 usdValueWei = getUsdValueOfEth(msg.value);
            if (usdValueWei < feeAmount) {
                revert FragBoxBetting__NonOwnerFeeRequired();
            }

            // Accumulate the fee (you could also send to owner instantly, but accumulating is fine)
            ownerFeesCollected += msg.value;
        }
        // No refund logic here — we accept exact or overpayment (common pattern)
    }

    /**
     * Converts a string into a bytes object for gas savings
     * @param matchIdStr The string to convert
     */
    function _getKey(string calldata matchIdStr) internal pure returns (bytes32) {
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
     * Converts a string to the match status enum
     * @param matchStatusStr The string that represents a match status
     */
    function _toMatchStatus(string memory matchStatusStr) internal pure returns (MatchStatus) {
        bytes32 hash = keccak256(bytes(matchStatusStr));
        if (hash == keccak256(bytes(""))) return MatchStatus.Unknown;
        if (hash == keccak256(bytes("Unknown"))) return MatchStatus.Unknown;
        if (hash == keccak256(bytes("Voting"))) return MatchStatus.Voting;
        if (hash == keccak256(bytes("Ready"))) return MatchStatus.Ready;
        if (hash == keccak256(bytes("Ongoing"))) return MatchStatus.Ongoing;
        if (hash == keccak256(bytes("Finished"))) return MatchStatus.Finished;
        return MatchStatus.Unknown;
    }

    /**
     * Called on first player deposit for a match
     * @notice This sends a request to chainlink functions to verify that the playerid and faction are valid (in the match and on the right team)
     * @param matchIdStr The matchId to check
     * @param playerId The playerId to check
     */
    function updateMatchRoster(string calldata matchIdStr, string calldata playerId, uint256 betAmount)
        internal
        whenNotPaused
    {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        bytes32 playerKey = _getKey(playerId);

        if (mb.playerToFaction[playerKey] != Faction.Unknown) {
            revert FragBoxBetting__RosterAlreadyRequested();
        }
        if (donHostedSecretsVersion == 0) revert FragBoxBetting__SecretsNotSet();

        if (block.timestamp - ROSTER_UPDATE_COOLDOWN < mb.playerToLastRosterUpdate[playerKey] + ROSTER_UPDATE_COOLDOWN)
        {
            revert FragBoxBetting__RosterUpdateTooSoon();
        }

        mb.playerToLastRosterUpdate[playerKey] = block.timestamp;

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(I_GETROSTER);

        string[] memory args = new string[](2);
        args[0] = matchIdStr;
        args[1] = playerId;
        req.setArgs(args);

        req.addDONHostedSecrets(donHostedSecretsSlotId, donHostedSecretsVersion);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), I_SUBSCRIPTIONID, CALLBACK_GAS_LIMIT, I_DONID);

        requestIdToInfo[requestId] = RequestInfo({
            requestType: RequestType.Roster,
            matchKey: matchKey,
            playerKey: _getKey(playerId),
            betAmount: betAmount,
            wallet: msg.sender
        });
        emit RequestSent(requestId, matchKey);
    }

    /* -------------------------------------------------------------------------- */
    /*                             EXTERNAL FUNCTIONS                             */
    /* -------------------------------------------------------------------------- */
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
     * Called REPEATEDLY by backend to update match status
     * @notice Need to setup a CRON job or Chainlink automation to routinely call this based on active matchIds that users bet on
     * @param matchIdStr The match Id to check
     */
    function updateMatchStatus(string calldata matchIdStr)
        external
        payable
        whenNotPaused
        costsFeeOrOwner(MIN_STATUS_UPDATE_FEE_USD)
    {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.matchStatus == MatchStatus.Finished) revert FragBoxBetting__MatchAlreadyFinished();
        if (donHostedSecretsVersion == 0) revert FragBoxBetting__SecretsNotSet();

        if (block.timestamp - STATUS_UPDATE_COOLDOWN < mb.lastStatusUpdate + STATUS_UPDATE_COOLDOWN) {
            revert FragBoxBetting__StatusUpdateTooSoon();
        }

        mb.lastStatusUpdate = block.timestamp;

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(I_GETSTATUS);

        string[] memory args = new string[](1);
        args[0] = matchIdStr;
        req.setArgs(args);

        req.addDONHostedSecrets(donHostedSecretsSlotId, donHostedSecretsVersion);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), I_SUBSCRIPTIONID, CALLBACK_GAS_LIMIT, I_DONID);

        mb.statusRequestId = requestId;
        requestIdToInfo[requestId] = RequestInfo({
            requestType: RequestType.Status, matchKey: matchKey, playerKey: bytes32(0), betAmount: 0, wallet: msg.sender
        });
        emit RequestSent(requestId, matchKey);
    }

    /**
     * The chainlink functions oracle calls this function when it finishes calling the faceit API
     * @param requestId The Id of the chainlink functions oracle request. Set in updateMatchRoster and updateMatchStatus
     * @param response The response body of the API request
     * @param err The error message of the API request
     */
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        RequestInfo memory requestInfo = requestIdToInfo[requestId];
        delete requestIdToInfo[requestId];
        bytes32 matchKey = requestInfo.matchKey;

        if (err.length > 0) {
            emit RequestError(requestId, matchKey, string(err));
            return;
        }

        // Request ownership validation (prevents stale data corruption)
        if (requestInfo.requestType == RequestType.Status) {
            MatchBet storage mb = matchBets[matchKey];

            if (mb.statusRequestId != requestId) {
                emit RequestError(requestId, matchKey, "Stale Status Request Id");
                return;
            }

            if (response.length != 2) {
                emit RequestError(requestId, matchKey, "Invalid Status Response");
                return;
            }

            MatchStatus matchStatus = MatchStatus(uint8(response[0]));
            mb.matchStatus = matchStatus;

            Faction winnerFaction = Faction(uint8(response[1]));
            if (matchStatus == MatchStatus.Finished) {
                mb.winnerFaction = winnerFaction;
            }

            emit RequestFulfilled(requestId, matchKey, matchStatus, winnerFaction);
        } else if (requestInfo.requestType == RequestType.Roster) {
            address requestor = requestInfo.wallet;
            uint256 betAmount = requestInfo.betAmount;

            if (betAmountsInRosterValidationFlight[requestor] < betAmount) {
                emit RequestError(requestId, matchKey, "Bet was withdrawn during roster validation");
                return;
            }

            if (response.length != 1) {
                emit RequestError(requestId, matchKey, "Invalid Roster Response");
                return;
            }

            uint8 fId = uint8(response[0]);
            Faction playerFaction = Faction(fId);

            if (playerFaction != Faction.Faction1 && playerFaction != Faction.Faction2) {
                emit RequestError(requestId, matchKey, "Invalid player");
                return;
            }

            MatchBet storage mb = matchBets[matchKey];
            bytes32 playerKey = requestInfo.playerKey;

            mb.playerToFaction[playerKey] = playerFaction;

            betAmountsInRosterValidationFlight[requestor] -= betAmount;
            mb.walletToPlayerIdToBet[requestor][playerKey] += betAmount;

            // Update totals
            mb.factionTotals[fId] += betAmount;

            emit RosterUpdated(matchKey, playerKey, playerFaction);
        }
    }

    /**
     * Place Bet on an ongoing faceit match that you are a part of. This is where players pay their deposit fee so that we don't have to calculate fees during payout/resolution
     * @param matchIdStr The id of the match the player is betting on
     * @param playerIdStr The id of the player who is placing the bet
     */
    function deposit(string calldata matchIdStr, string calldata playerIdStr)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        // The point of this is just to prevent anyone from sending an insanely large amount of money or an insanely small amount of money
        // We don't care if someone bets a large amount of money on a match, but we want to prevent mistakes (like someone sending 1000x the intended bet amount) and also prevent dust bets that would cause issues with the pro-rata calculations and leftover dust in the contract after payouts
        uint256 usdValueOfEth = getUsdValueOfEth(msg.value);
        if (usdValueOfEth < MIN_BET_AMOUNT_IN_USD) revert FragBoxBetting__BetTooSmall();
        if (usdValueOfEth > MAX_BET_AMOUNT_IN_USD) revert FragBoxBetting__BetTooLarge();

        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.matchStatus == MatchStatus.Finished) {
            revert FragBoxBetting__MatchAlreadyFinished();
        }

        if (mb.matchStatus == MatchStatus.Ongoing || mb.matchStatus == MatchStatus.Finished) {
            revert FragBoxBetting__MatchIsFinishedOrOngoing();
        }

        // Calculate house fee and actual bet amount
        uint256 fee = calculateDepositFee(msg.value);
        uint256 betAmount = msg.value - fee;

        if (betAmount <= 0) {
            revert FragBoxBetting__BetTooSmall();
        }

        // Send fee to owner
        ownerFeesCollected += fee;

        bytes32 playerKey = _getKey(playerIdStr);
        Faction faction = mb.playerToFaction[playerKey];

        if (faction == Faction.Unknown) {
            betAmountsInRosterValidationFlight[msg.sender] += betAmount;
            updateMatchRoster(matchIdStr, playerIdStr, betAmount);
        } else {
            mb.walletToPlayerIdToBet[msg.sender][playerKey] += betAmount;

            // Update totals
            mb.factionTotals[uint8(faction)] += betAmount;
        }

        emit BetPlaced(matchKey, msg.sender, betAmount, playerIdStr);
    }

    /**
     * @notice Claims winnings/refunds for a finished match.
     * Strict equalization: winning faction always receives exactly
     * 2 × min(W, L) total, regardless of which side overbet.
     * Excess on the heavier side is automatically refunded pro-rata.
     *
     * Winners overbet (W=150, L=100) -> winners get 200 (2 × 100)
     * Losers overbet (W=100, L=150) -> winners get 200 (2 × 100)
     *
     * Both factions risk the exact same amount. Excess on both sides is refunded.
     *
     * @param matchIdStr Match id to check
     */
    function claim(string calldata matchIdStr, string calldata playerIdStr) external nonReentrant whenNotPaused {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.matchStatus != MatchStatus.Finished) revert FragBoxBetting__MatchNotFinished();

        bytes32 playerKey = _getKey(playerIdStr);
        uint256 betAmount = mb.walletToPlayerIdToBet[msg.sender][playerKey];
        if (betAmount == 0) revert FragBoxBetting__NoBetForPlayer();

        Faction winnerFaction = mb.winnerFaction;
        if (winnerFaction == Faction.Unknown) revert FragBoxBetting__WinnerUnknown();
        uint8 winnerFId = uint8(winnerFaction);

        uint256[4] storage winnerTotals = mb.factionTotals;

        // Draw or no winning bets -> full refund
        if (winnerFaction == Faction.Draw || winnerTotals[winnerFId] == 0) {
            playerToWinnings[msg.sender][playerKey] += betAmount;
            mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;
            emit MatchClaimed(matchKey);
            return;
        }

        uint256 totalWinningBet = winnerTotals[winnerFId];
        uint256 totalLosingBet = (winnerFaction == Faction.Faction1)
            ? winnerTotals[uint8(Faction.Faction2)]
            : winnerTotals[uint8(Faction.Faction1)];

        // STRICT SYMMETRY: winning side always gets exactly 2 * min(W, L)
        uint256 minBet = totalWinningBet < totalLosingBet ? totalWinningBet : totalLosingBet;

        Faction playerFaction = mb.playerToFaction[playerKey];
        uint256 payoutOrRefund;

        if (playerFaction == winnerFaction) {
            // WINNER PATH: always get symmetric share (2 * minBet)
            uint256 numerator = betAmount * 2 * minBet;
            payoutOrRefund = numerator / totalWinningBet;

            // Dust sweep for this division
            uint256 dust = numerator % totalWinningBet;
            ownerFeesCollected += dust;
        } else {
            // LOSER PATH: only get excess refund if losing faction overbet
            if (totalLosingBet <= totalWinningBet) {
                revert FragBoxBetting__LosingFactionCannotClaim(playerFaction);
            }
            // excess on losing side is refunded pro-rata
            uint256 excess = totalLosingBet - minBet;
            uint256 numerator = betAmount * excess;
            payoutOrRefund = numerator / totalLosingBet;

            // Dust sweep for this division
            uint256 dust = numerator % totalLosingBet;
            ownerFeesCollected += dust;
        }

        if (payoutOrRefund > 0) {
            playerToWinnings[msg.sender][playerKey] += payoutOrRefund;
            mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;
        }

        emit MatchClaimed(matchKey);
    }

    /**
     * Refund any bets that haven't completed in 24 hours
     * @param matchIdStr The matchId to check the status of
     */
    function emergencyRefund(string calldata matchIdStr, string calldata playerIdStr)
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.matchStatus == MatchStatus.Finished) {
            revert FragBoxBetting__MatchAlreadyFinished();
        }

        if (block.timestamp <= mb.lastStatusUpdate + TIMEOUT_DURATION) {
            revert FragBoxBetting__TimeoutNotReached();
        }

        bytes32 playerKey = _getKey(playerIdStr);

        // Refund all bets
        uint256 betAmount = mb.walletToPlayerIdToBet[msg.sender][playerKey];
        playerToWinnings[msg.sender][playerKey] += betAmount;
        mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;

        emit EmergencyRefund(matchKey);
    }

    /**
     * Allows a player to withdraw their winnings from the contract
     * @param playerId The player id the sender wallet is associated with
     */
    function withdraw(string memory playerId) external nonReentrant whenNotPaused {
        bytes32 playerKey = getKey(playerId);

        uint256 winningsAmount = playerToWinnings[msg.sender][playerKey];
        if (winningsAmount <= 0) {
            revert FragBoxBetting__InsufficientFundsForWithdrawal();
        }

        Address.sendValue(payable(msg.sender), winningsAmount);
        playerToWinnings[msg.sender][playerKey] -= winningsAmount;
        emit WinningsWithdrawn(playerId, msg.sender, winningsAmount);
    }

    /**
     * Allows the owner to withdraw collected deposit fees
     */
    function withdrawOwnerFees() external onlyOwner nonReentrant whenNotPaused {
        uint256 amount = ownerFeesCollected;
        Address.sendValue(payable(owner()), amount);
        ownerFeesCollected = 0;
    }

    /**
     * Allows the user to withdraw funds from the contract when they are in flight (chainlink functions) for roster validation
     * This phase occurs right after a user deposits (bets) for the first time on any match
     * These funds could get locked up if the chainlink functions system fails to call fulfillRequest or fulfillRequest returns or reverts
     */
    function withdrawBetAmountsInRosterValidationFlight() external nonReentrant whenNotPaused {
        uint256 withdrawalAmount = betAmountsInRosterValidationFlight[msg.sender];
        if (withdrawalAmount <= 0) {
            revert FragBoxBetting__InsufficientFundsForWithdrawal();
        }

        Address.sendValue(payable(msg.sender), withdrawalAmount);
        betAmountsInRosterValidationFlight[msg.sender] -= withdrawalAmount;
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
    function getKey(string memory matchIdStr) public pure returns (bytes32) {
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
            factionTotals: mb.factionTotals,
            winnerFaction: mb.winnerFaction,
            statusRequestId: mb.statusRequestId,
            lastStatusUpdate: mb.lastStatusUpdate,
            matchStatus: mb.matchStatus
        });
    }

    /**
     * This lets you access a player's faction based on a match bet's mapping
     * @param matchKey The match the player is in
     * @param playerKey The player to get the faction of
     * @return Returns the Faction a player belongs to
     */
    function getPlayerFaction(bytes32 matchKey, bytes32 playerKey) external view returns (Faction) {
        return matchBets[matchKey].playerToFaction[playerKey];
    }

    /**
     * Gets the amount of winnings a player has earned but hasn't withdrawn in wei
     * @param playerKey The player who earned the winnings and is associated with the msg.sender
     * @return The winnings in wei
     */
    function getWinnings(bytes32 playerKey) external view returns (uint256) {
        return playerToWinnings[msg.sender][playerKey];
    }

    /**
     * Gets the amount of owner fees accumulated that hasn't been withdrawn yet
     * @return The amount in wei
     */
    function getOwnerFees() external view onlyOwner returns (uint256) {
        return ownerFeesCollected;
    }

    /**
     * @return The amount of eth in wei that is in roster validation flight for the msg.sender
     */
    function getBetAmountsInRosterValidationFlight() external view returns (uint256) {
        return betAmountsInRosterValidationFlight[msg.sender];
    }

    /**
     * Calcuates the fee for new deposits
     * @param depositAmount The total amount of eth in wei that someone is depositing
     * @return The fee in wei
     */
    function calculateDepositFee(uint256 depositAmount) public pure returns (uint256) {
        return (depositAmount * HOUSE_FEE_PERCENTAGE) / PERCENTAGE_BASE;
    }

    /**
     * Gets the percentage the contract takes during deposits
     * @return The percentage
     */
    function getHouseFeePercentage() external pure returns (uint256) {
        return HOUSE_FEE_PERCENTAGE;
    }

    /**
     * @return The value to divide house fee percentage by
     */
    function getPercentageBase() external pure returns (uint256) {
        return PERCENTAGE_BASE;
    }

    /**
     * Gets the minimum total deposit amount per match
     * @return The amount in USD wei
     */
    function getMinBetAmountInUsd() external pure returns (uint256) {
        return MIN_BET_AMOUNT_IN_USD;
    }

    /**
     * Gets the maximum total deposit amount per match
     * @return The amount in USD wei
     */
    function getMaxBetAmountInUsd() external pure returns (uint256) {
        return MAX_BET_AMOUNT_IN_USD;
    }
}
