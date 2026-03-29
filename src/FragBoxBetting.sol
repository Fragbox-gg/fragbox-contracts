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
import {console} from "forge-std/console.sol";

contract FragBoxBetting is ReentrancyGuard, Ownable, FunctionsClient, Pausable {
    error FragBoxBetting__MatchAlreadyResolved();
    error FragBoxBetting__MatchNotResolved();
    error FragBoxBetting__TimeoutNotReached();
    error FragBoxBetting__MatchNotRequested();
    error FragBoxBetting__BetTooSmall();
    error FragBoxBetting__BetTooLarge();
    error FragBoxBetting__RosterAlreadyRequested();
    error FragBoxBetting__MatchIsFinishedOrOngoing();
    error FragBoxBetting__MatchNotFinished();
    error FragBoxBetting__SecretsNotSet();
    error FragBoxBetting__NoWinnings();
    error FragBoxBetting__StatusUpdateTooSoon();
    error FragBoxBetting__RosterUpdateTooSoon();
    error FragBoxBetting__NonOwnerFeeRequired();
    error FragBoxBetting__NoBets();
    error FragBoxBetting__AmountToWithdrawIsGreaterThanFundsInFlight();
    error FragBoxBetting__WinnerUnknown();
    error FragBoxBetting__InvalidFaction(Faction faction);

    using FunctionsRequest for FunctionsRequest.Request;
    using OracleLib for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant TIMEOUT_DURATION = 24 hours;
    uint256 private constant HOUSE_FEE_PERCENTAGE = 1; // 1 = 1%
    uint256 private constant PERCENTAGE_BASE = 100;
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 private constant STATUS_UPDATE_COOLDOWN = 5 minutes;
    uint256 private constant ROSTER_UPDATE_COOLDOWN = 10 minutes;
    uint256 public constant MIN_STATUS_UPDATE_FEE_USD = 20 ether;
    uint256 private constant MIN_BET_AMOUNT_IN_USD = 3 ether;
    uint256 private constant MAX_BET_AMOUNT_IN_USD = 3000 ether;

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

    struct MatchBet {
        mapping(address wallet => mapping(bytes32 playerKey => uint256 betAmount)) walletToPlayerIdToBet;

        uint256[4] factionTotals; // 1 = Faction1 total, 2 = Faction2, 3 = Draw

        Faction winnerFaction; // "" = pending, "faction1"/"faction2"/"draw"
        bool resolved; // this is true when a victor has been set/the match has finished
        bytes32 statusRequestId;

        mapping(bytes32 playerKey => Faction playerFaction) playerToFaction; // playerKey => Faction (Unknown = invalid/not present)
        mapping(bytes32 playerKey => uint256 lastRosterUpdate) playerToLastRosterUpdate;

        uint256 totalBetAmount;
        uint256 lastRosterUpdate;
        uint256 lastStatusUpdate;

        MatchStatus matchStatus;
    }

    /* ---------- VIEW STRUCT (no mapping -> can be returned in memory) ---------- */
    struct MatchBetView {
        uint256[4] factionTotals;
        Faction winnerFaction;
        bool resolved;
        bytes32 statusRequestId;
        uint256 totalBetAmount;
        uint256 lastRosterUpdate;
        uint256 lastStatusUpdate;
        MatchStatus matchStatus;
    }

    mapping(bytes32 matchKey => MatchBet matchBet) private matchBets;

    struct RequestInfo {
        RequestType requestType;
        bytes32 matchKey;
        bytes32 playerKey;
        uint256 betAmount;
        address wallet;
    }

    mapping(bytes32 requestId => RequestInfo requestInfo) private requestIdToInfo;
    mapping(address wallet => mapping(bytes32 playerKey => uint256 winnings)) private playerToWinnings;

    AggregatorV3Interface private immutable I_ETHUSDPRICEFEED;
    address private immutable I_CHAINLINKFUNCTIONSROUTER;
    bytes32 private immutable I_DONID;
    uint64 private immutable I_SUBSCRIPTIONID;
    string private I_GETROSTER;
    string private I_GETSTATUS;

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

    uint8 private donHostedSecretsSlotId;
    uint64 private donHostedSecretsVersion;

    uint256 private betAmountsInRosterValidationFlight;
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

    modifier costsFeeOrOwner() {
        _costsFeeOrOwner();
        _;
    }

    function _costsFeeOrOwner() internal {
        if (msg.sender != owner()) {
            // Require some ETH is sent (basic protection)
            if (msg.value == 0) revert FragBoxBetting__NonOwnerFeeRequired();

            uint256 usdValueWei = getUsdValueOfEth(msg.value);
            if (usdValueWei < MIN_STATUS_UPDATE_FEE_USD) {
                revert FragBoxBetting__NonOwnerFeeRequired();
            }

            // Accumulate the fee (you could also send to owner instantly, but accumulating is fine)
            ownerFeesCollected += msg.value;
        }
        // No refund logic here — we accept exact or overpayment (common pattern)
    }

    /**
     * Called REPEATEDLY by backend to update match status
     * @notice Need to setup a CRON job or Chainlink automation to routinely call this based on active matchIds that users bet on
     * @param matchIdStr The match Id to check
     */
    function updateMatchStatus(string calldata matchIdStr) external payable whenNotPaused costsFeeOrOwner {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved) revert FragBoxBetting__MatchAlreadyResolved();
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
        RequestInfo storage requestInfo = requestIdToInfo[requestId];
        bytes32 matchKey = requestInfo.matchKey;
        MatchBet storage mb = matchBets[matchKey];

        if (err.length > 0) {
            emit RequestError(requestId, matchKey, string(err));
            return;
        }

        // Request ownership validation (prevents stale data corruption)
        if (requestInfo.requestType == RequestType.Status) {
            if (mb.statusRequestId != requestId) {
                emit RequestError(requestId, matchKey, "Stale Status Request Id");
                return;
            }
        }

        if (requestInfo.requestType == RequestType.Roster) {
            bytes32 playerKey = requestInfo.playerKey;
            mb.playerToLastRosterUpdate[playerKey] = block.timestamp;
            mb.lastRosterUpdate = block.timestamp;

            uint8 fId = uint8(response[0]);
            Faction playerFaction = Faction(fId);

            if (playerFaction != Faction.Faction1 && playerFaction != Faction.Faction2) {
                emit RequestError(requestId, matchKey, "Invalid player");
                return;
            }

            mb.playerToFaction[playerKey] = playerFaction;

            uint256 betAmount = requestInfo.betAmount;
            betAmountsInRosterValidationFlight -= betAmount;
            mb.walletToPlayerIdToBet[requestInfo.wallet][playerKey] += betAmount;

            // Update totals
            mb.factionTotals[fId] += betAmount;
            mb.totalBetAmount += betAmount;

            emit RosterUpdated(matchKey, playerKey, playerFaction);
        } else if (requestInfo.requestType == RequestType.Status) {
            MatchStatus matchStatus = MatchStatus(uint8(response[0]));
            Faction winnerFaction = Faction(uint8(response[1]));

            mb.matchStatus = matchStatus;
            mb.lastStatusUpdate = block.timestamp;

            if (matchStatus == MatchStatus.Finished) {
                mb.winnerFaction = winnerFaction;
                mb.resolved = true;
            }

            emit RequestFulfilled(requestId, matchKey, matchStatus, winnerFaction);
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
        // TODO Make this check the existing bet amount so that players can't spam multiple bets to get past this
        uint256 usdValueOfEth = getUsdValueOfEth(msg.value);
        if (usdValueOfEth < MIN_BET_AMOUNT_IN_USD) revert FragBoxBetting__BetTooSmall();
        if (usdValueOfEth > MAX_BET_AMOUNT_IN_USD) revert FragBoxBetting__BetTooLarge();

        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved) {
            revert FragBoxBetting__MatchAlreadyResolved();
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
            betAmountsInRosterValidationFlight += betAmount;
            updateMatchRoster(matchIdStr, playerIdStr, betAmount);
        } else {
            mb.walletToPlayerIdToBet[msg.sender][playerKey] += betAmount;

            // Update totals
            mb.factionTotals[uint8(faction)] += betAmount;
            mb.totalBetAmount += betAmount;
        }

        emit BetPlaced(matchKey, msg.sender, betAmount, playerIdStr);
    }

    /**
     * Checks if a match has completed and pays out based on the victor.
     * Payouts are calculated based on how much each player deposited (wagered).
     * So a player who wagered $20 when their team total is $100 will get 20% of the prize pot
     * @param matchIdStr Match id to check
     */
    function claim(string calldata matchIdStr, string calldata playerIdStr) external nonReentrant whenNotPaused {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (!mb.resolved) revert FragBoxBetting__MatchNotResolved();
        if (mb.lastRosterUpdate == 0 || mb.lastStatusUpdate == 0) revert FragBoxBetting__MatchNotRequested();
        if (mb.matchStatus != MatchStatus.Finished) revert FragBoxBetting__MatchNotFinished();

        uint256 totalPot = mb.totalBetAmount;
        if (totalPot == 0) revert FragBoxBetting__NoBets();

        uint256 totalWinningBet = (mb.winnerFaction != Faction.Faction1 && mb.winnerFaction != Faction.Faction2)
            ? 0
            : mb.factionTotals[uint8(mb.winnerFaction)];

        bytes32 playerKey = _getKey(playerIdStr);

        uint256 betAmount = mb.walletToPlayerIdToBet[msg.sender][playerKey];

        if (totalWinningBet <= 0) {
            if (betAmount > 0) {
                // No one bet on winner -> refund everyone
                playerToWinnings[msg.sender][playerKey] += betAmount;
                mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;
            }
        } else { // Winning bet is greater than 0 so payout logic is valid
            Faction faction = mb.playerToFaction[playerKey];
            if (mb.winnerFaction == Faction.Unknown) {
                revert FragBoxBetting__WinnerUnknown();
            } else if (mb.winnerFaction != Faction.Draw) {
                // If we know who the winner is and it's not a draw, only let winning players claim their prize
                if (faction != mb.winnerFaction) {
                    revert FragBoxBetting__InvalidFaction(faction);
                }
            }

            if (betAmount > 0) {
                // Payout logic
                uint256 payout = (betAmount * totalPot) / totalWinningBet;

                playerToWinnings[msg.sender][playerKey] += payout;
                mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;
            }
        }

        // TODO Sweep dust from integer division to owner

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
        // TODO We should not be able to refund if the match has already been claimed
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.resolved) {
            revert FragBoxBetting__MatchAlreadyResolved();
        }
        if (mb.lastRosterUpdate == 0 || mb.lastStatusUpdate == 0) {
            revert FragBoxBetting__MatchNotRequested();
        }
        if (
            block.timestamp <= mb.lastStatusUpdate + TIMEOUT_DURATION
                && block.timestamp <= mb.lastRosterUpdate + TIMEOUT_DURATION
        ) {
            revert FragBoxBetting__TimeoutNotReached();
        }

        bytes32 playerKey = _getKey(playerIdStr);

        // Refund all bets
        uint256 betAmount = mb.walletToPlayerIdToBet[msg.sender][playerKey];
        playerToWinnings[msg.sender][playerKey] += betAmount;
        mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;

        emit EmergencyRefund(matchKey);
    }

    // TODO Add emergencyRefund onlyOwner method that doesn't care about any constraints

    /**
     * Allows a player to withdraw their winnings from the contract
     * @param playerId The player id the sender wallet is associated with
     */
    function withdraw(string memory playerId) external nonReentrant whenNotPaused {
        bytes32 playerKey = getKey(playerId);

        uint256 winningsAmount = playerToWinnings[msg.sender][playerKey];
        if (winningsAmount <= 0) {
            revert FragBoxBetting__NoWinnings();
        }

        Address.sendValue(payable(msg.sender), winningsAmount);
        playerToWinnings[msg.sender][playerKey] -= winningsAmount;
        emit WinningsWithdrawn(playerId, msg.sender, winningsAmount);
    }

    /**
     * Allows the owner to withdraw collected deposit fees
     */
    function withdrawOwnerFees() external onlyOwner {
        uint256 amount = ownerFeesCollected;
        Address.sendValue(payable(owner()), amount);
        ownerFeesCollected = 0;
    }

    /**
     * Allows the owner to withdraw funds from the contract when they are in flight (chainlink functions) for roster validation
     * This phase occurs right after a user deposits (bets) for the first time on any match
     * These funds could get locked up if the chainlink functions system fails to call fulfillRequest or fulfillRequest returns or reverts
     * @param amountToWithdraw The amount of eth in wei to attempt to withdraw
     */
    function withdrawBetAmountsInRosterValidationFlight(uint256 amountToWithdraw) external onlyOwner {
        if (amountToWithdraw > betAmountsInRosterValidationFlight) {
            revert FragBoxBetting__AmountToWithdrawIsGreaterThanFundsInFlight();
        }
        Address.sendValue(payable(owner()), amountToWithdraw);
        betAmountsInRosterValidationFlight -= amountToWithdraw;
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
            resolved: mb.resolved,
            statusRequestId: mb.statusRequestId,
            totalBetAmount: mb.totalBetAmount,
            lastRosterUpdate: mb.lastRosterUpdate,
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
     * @return The amount of eth in wei that is in roster validation flight
     */
    function getBetAmountsInRosterValidationFlight() external view onlyOwner returns (uint256) {
        return betAmountsInRosterValidationFlight;
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
