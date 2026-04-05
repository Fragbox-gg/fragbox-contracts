// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FragBoxBetting is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20Metadata;

    /* -------------------------------------------------------------------------- */
    /*                                   ERRORS                                   */
    /* -------------------------------------------------------------------------- */
    error FragBoxBetting__InvalidWallet();
    error FragBoxBetting__TierMismatch();
    error FragBoxBetting__TierNotActive();
    error FragBoxBetting__TierAlreadySet();
    error FragBoxBetting__TierIdMustBeGreaterThanZero();
    error FragBoxBetting__MatchStatusDoesNotAllowBets();
    error FragBoxBetting__MatchStatusIsInvalid();
    error FragBoxBetting__MatchAlreadyFinished();
    error FragBoxBetting__MatchNotFinished();
    error FragBoxBetting__TimeoutNotReached();
    error FragBoxBetting__InFlightTimeoutNotReached();
    error FragBoxBetting__BetTooSmall();
    error FragBoxBetting__BetTooLarge();
    error FragBoxBetting__RosterAlreadyRequested();
    error FragBoxBetting__NoBetForPlayer();
    error FragBoxBetting__InsufficientFundsForWithdrawal();
    error FragBoxBetting__WinnerUnknown();
    error FragBoxBetting__MinBetMustBeGreaterThanMaxBet();
    error FragBoxBetting__PlayerFactionInvalid();
    error FragBoxBetting__LosingFactionCannotClaim(Faction faction);
    error FragBoxBetting__InvalidMatchStatus(
        bytes32 matchKey, string matchId, MatchStatus currentStatus, MatchStatus newStatus
    );
    error FragBoxBetting__FinishedStatusMustHaveAWinner(
        bytes32 matchKey, string matchId, MatchStatus currentStatus, MatchStatus newStatus, Faction winnerFaction
    );

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
        Finished,
        Invalid
    }

    enum RequestType {
        Roster,
        Status
    }

    /* -------------------------------------------------------------------------- */
    /*                               CUSTOM STRUCTS                               */
    /* -------------------------------------------------------------------------- */
    struct MatchBet {
        Faction winnerFaction;
        MatchStatus matchStatus;
        uint256[4] factionTotals; // 0 = Unknown, 1 = Faction1 total, 2 = Faction2, 3 = Draw
        uint256 lastStatusUpdate;
        uint8 tierId;
        bytes32 statusRequestId;

        mapping(address wallet => mapping(bytes32 playerKey => InFlightBet inFlightBet))
            betAmountsInRosterValidationFlight;
        mapping(address wallet => mapping(bytes32 playerKey => uint256 betAmount)) walletToPlayerIdToBet;
        mapping(bytes32 playerKey => Faction playerFaction) playerToFaction; // playerKey => Faction (Unknown = invalid/not present)
    }

    /* ---------- VIEW STRUCT (no mapping -> can be returned in memory) ---------- */
    struct MatchBetView {
        Faction winnerFaction;
        MatchStatus matchStatus;
        uint256[4] factionTotals;
        uint256 lastStatusUpdate;
        uint8 tierId;
        bytes32 statusRequestId;
    }

    struct RequestInfo {
        RequestType requestType;
        bytes32 matchKey;
        bytes32 playerKey;
        uint256 betAmount;
        address wallet;
    }

    struct Tier {
        uint256 minBetAmount;
        uint256 maxBetAmount;
        bool active;
    }

    struct InFlightBet {
        uint256 betAmount;
        uint256 lastDepositTime;
    }

    /* -------------------------------------------------------------------------- */
    /*                                   EVENTS                                   */
    /* -------------------------------------------------------------------------- */
    event BetPlaced(
        bytes32 indexed matchKey, string matchId, address indexed bettor, uint256 amount, string playerId, uint8 tierId
    );
    event MatchClaimed(
        bytes32 indexed matchKey,
        string matchId,
        address indexed claimer,
        string playerId,
        uint256 amountClaimed,
        bool isRefund
    );
    event EmergencyRefund(
        bytes32 indexed matchKey, string matchId, address indexed claimer, string playerId, uint256 amountRefunded
    );
    event WinningsWithdrawn(bytes32 indexed playerKey, string playerId, address indexed wallet, uint256 amount);
    event InFlightFundsWithdrawn(
        bytes32 indexed matchKey,
        string matchId,
        bytes32 indexed playerKey,
        string playerId,
        address indexed wallet,
        uint256 amountWithdrawn
    );
    /* ---------------------------- ONLY OWNER EVENTS --------------------------- */
    event PlayerRegistered(bytes32 indexed playerId, address indexed wallet, string playerIdStr);
    event StatusUpdated(bytes32 indexed matchKey, string matchId, MatchStatus status, Faction winnerFaction);
    event RosterUpdated(
        bytes32 indexed matchKey,
        string matchId,
        bytes32 indexed playerKey,
        string playerId,
        address indexed bettor,
        Faction playerFaction
    );
    event OwnerFeesWithdrawn(address indexed wallet, uint256 amountWithdrawn);
    /* ------------------------- ADMIN / CONFIG CHANGES ------------------------- */
    event EmergencyRefundTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event InFlightWithdrawalTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event HouseFeePercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event MinStatusUpdateFeeUpdated(uint256 oldFee, uint256 newFee);
    event StatusUpdateCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event RosterUpdateCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event TierUpdated(uint8 indexed tierId, uint256 minBetAmount, uint256 maxBetAmount);
    event MatchTierSet(bytes32 indexed matchKey, string matchId, uint8 tierId);

    /* -------------------------------------------------------------------------- */
    /*                                  CONSTANTS                                 */
    /* -------------------------------------------------------------------------- */
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;

    /* -------------------------------------------------------------------------- */
    /*                             IMMUTABLE VARIABLES                            */
    /* -------------------------------------------------------------------------- */
    IERC20Metadata private immutable I_USDC;
    uint8 private immutable I_USDC_DECIMALS;

    /* -------------------------------------------------------------------------- */
    /*                              STORAGE VARIABLES                             */
    /* -------------------------------------------------------------------------- */
    mapping(uint8 tierId => Tier) private tiers;
    mapping(bytes32 matchKey => MatchBet matchBet) private matchBets;
    mapping(bytes32 playerId => address registeredWallet) private playerIdToRegisteredWallet;
    mapping(bytes32 requestId => RequestInfo requestInfo) private requestIdToInfo;
    mapping(address wallet => mapping(bytes32 playerKey => uint256 winnings)) private playerToWinnings;

    uint256 private ownerFeesCollected;

    /* --------------------------- OWNER / CONFIG VARS -------------------------- */
    uint256 private emergencyRefundTimeout = 4 hours;
    uint256 private inFlightWithdrawalTimeout = 1 hours;
    uint256 private houseFeePercentage = 1; // 1 = 1%

    /* -------------------------------------------------------------------------- */
    /*                             INTERNAL FUNCTIONS                             */
    /* -------------------------------------------------------------------------- */
    /**
     * Converts a string into a bytes object for gas savings
     * @param matchIdStr The string to convert
     */
    function _getKey(string calldata matchIdStr) internal pure returns (bytes32) {
        return keccak256(bytes(matchIdStr));
    }

    /**
     * Creates or modifies an existing tier
     * @param tierId The id of the tier
     * @param minBetAmount The min bet amount of the tier in USD
     * @param maxBetAmount The max bet amount of the tier in USD
     */
    function _setTier(uint8 tierId, uint256 minBetAmount, uint256 maxBetAmount) internal {
        if (tierId == 0) {
            revert FragBoxBetting__TierIdMustBeGreaterThanZero();
        }

        if (minBetAmount >= maxBetAmount) {
            revert FragBoxBetting__MinBetMustBeGreaterThanMaxBet();
        }

        tiers[tierId] = Tier({minBetAmount: toUsdc(minBetAmount), maxBetAmount: toUsdc(maxBetAmount), active: true});
    }

    /**
     * Called REPEATEDLY by backend to update match status
     * @notice Need to setup a CRON job or Chainlink automation to routinely call this based on active matchIds that users bet on
     * @param matchIdStr The match Id to check
     * @param newMatchStatus The status of the match
     * @param winnerFaction The winning faction of the match
     */
    function _updateMatchStatus(string calldata matchIdStr, MatchStatus newMatchStatus, Faction winnerFaction)
        internal
    {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        MatchStatus currentMatchStatus = mb.matchStatus;

        if (newMatchStatus == MatchStatus.Unknown) {
            revert FragBoxBetting__InvalidMatchStatus(matchKey, matchIdStr, currentMatchStatus, newMatchStatus);
        }

        if (currentMatchStatus == MatchStatus.Ongoing) {
            if (newMatchStatus != MatchStatus.Finished) {
                revert FragBoxBetting__InvalidMatchStatus(matchKey, matchIdStr, currentMatchStatus, newMatchStatus);
            }
        } else if (currentMatchStatus == MatchStatus.Invalid) {
            revert FragBoxBetting__InvalidMatchStatus(matchKey, matchIdStr, currentMatchStatus, newMatchStatus);
        }

        if (mb.matchStatus == MatchStatus.Finished) {
            revert FragBoxBetting__MatchAlreadyFinished();
        }

        mb.lastStatusUpdate = block.timestamp;

        // EDGE-CASE PROTECTION:
        // First status update must land on Unknown / Voting / Ready.
        // Anything else means the match skipped the betting window → invalid + full refunds.
        if (currentMatchStatus == MatchStatus.Unknown) {
            if (
                newMatchStatus != MatchStatus.Unknown && newMatchStatus != MatchStatus.Voting
                    && newMatchStatus != MatchStatus.Ready
            ) {
                mb.matchStatus = MatchStatus.Invalid;
                emit StatusUpdated(matchKey, matchIdStr, MatchStatus.Invalid, Faction.Unknown);
                return;
            }
        }

        mb.matchStatus = newMatchStatus;

        if (newMatchStatus == MatchStatus.Finished) {
            if (winnerFaction == Faction.Unknown) {
                revert FragBoxBetting__FinishedStatusMustHaveAWinner(
                    matchKey, matchIdStr, currentMatchStatus, newMatchStatus, winnerFaction
                );
            }

            mb.winnerFaction = winnerFaction;
        }

        emit StatusUpdated(matchKey, matchIdStr, newMatchStatus, winnerFaction);
    }

    constructor(address usdcAddress) Ownable(msg.sender) {
        I_USDC = IERC20Metadata(usdcAddress);
        I_USDC_DECIMALS = I_USDC.decimals();

        // Default tiers (low / mid / high stakes) – owner can change after deployment
        _setTier(1, 5, 10); // $5 – $10
        _setTier(2, 10, 20); // $10 – $20
        _setTier(3, 50, 100); // $50 – $100
    }

    /* -------------------------------------------------------------------------- */
    /*                             EXTERNAL FUNCTIONS                             */
    /* -------------------------------------------------------------------------- */
    /**
     * @notice Backend-only: Register a playerId → wallet after successful Faceit/Steam OAuth + RainbowKit connect.
     * This is the single source of truth that prevents match fixing.
     * @param playerIdStr The playerId to register
     * @param wallet The wallet to register
     */
    function registerPlayerWallet(string calldata playerIdStr, address wallet) external onlyOwner {
        bytes32 playerKey = _getKey(playerIdStr);
        playerIdToRegisteredWallet[playerKey] = wallet;
        emit PlayerRegistered(playerKey, wallet, playerIdStr);
    }

    /**
     * Called on first player deposit for a match
     * @notice This sends a request to chainlink functions to verify that the playerid and faction are valid (in the match and on the right team)
     * @param matchIdStr The matchId to check
     * @param playerId The playerId to check
     * @param bettor The address of the player who bet on the match
     */
    function updateMatchRoster(
        string calldata matchIdStr,
        string calldata playerId,
        address bettor,
        Faction playerFaction
    ) external whenNotPaused onlyOwner {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        bytes32 playerKey = _getKey(playerId);

        if (mb.playerToFaction[playerKey] != Faction.Unknown) {
            revert FragBoxBetting__RosterAlreadyRequested();
        }

        if (playerFaction != Faction.Faction1 && playerFaction != Faction.Faction2) {
            revert FragBoxBetting__PlayerFactionInvalid();
        }

        // Assign player faction
        mb.playerToFaction[playerKey] = playerFaction;

        uint256 betAmount = mb.betAmountsInRosterValidationFlight[bettor][playerKey].betAmount;
        mb.walletToPlayerIdToBet[bettor][playerKey] += betAmount;
        // Update totals
        mb.factionTotals[uint8(playerFaction)] += betAmount;

        delete mb.betAmountsInRosterValidationFlight[bettor][playerKey];

        emit RosterUpdated(matchKey, matchIdStr, playerKey, playerId, bettor, playerFaction);
    }

    /**
     * Called REPEATEDLY by backend to update match status
     * @notice Need to setup a CRON job or Chainlink automation to routinely call this based on active matchIds that users bet on
     * @dev This overload assumes winner faction is unknown, don't pass MatchStatus.Finished to this otherwise it will revert
     * @param matchIdStr The match Id to check
     * @param newMatchStatus The status of the match
     */
    function updateMatchStatus(string calldata matchIdStr, MatchStatus newMatchStatus)
        external
        nonReentrant
        whenNotPaused
        onlyOwner
    {
        _updateMatchStatus(matchIdStr, newMatchStatus, FragBoxBetting.Faction.Unknown);
    }

    /**
     * Called REPEATEDLY by backend to update match status
     * @notice Need to setup a CRON job or Chainlink automation to routinely call this based on active matchIds that users bet on
     * @param matchIdStr The match Id to check
     * @param newMatchStatus The status of the match
     * @param winnerFaction The winning faction of the match
     */
    function updateMatchStatus(string calldata matchIdStr, MatchStatus newMatchStatus, Faction winnerFaction)
        external
        nonReentrant
        whenNotPaused
        onlyOwner
    {
        _updateMatchStatus(matchIdStr, newMatchStatus, winnerFaction);
    }

    /**
     * @notice Owner can pre-set the tier for a match (recommended for production).
     * Once a tier is set, it cannot be changed.
     * @param matchIdStr The matchId to set the tier for
     * @param tierId The tierId to set for the match
     */
    function setMatchTier(string calldata matchIdStr, uint8 tierId) external onlyOwner {
        if (tierId == 0) revert FragBoxBetting__TierIdMustBeGreaterThanZero();

        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.tierId != 0) {
            revert FragBoxBetting__TierAlreadySet();
        }

        // Validate that the tier actually exists and is active
        if (!tiers[tierId].active) {
            revert FragBoxBetting__TierNotActive();
        }

        mb.tierId = tierId;
        emit MatchTierSet(matchKey, matchIdStr, tierId);
    }

    /**
     * Place Bet on an ongoing faceit match that you are a part of. This is where players pay their deposit fee so that we don't have to calculate fees during payout/resolution
     * @param matchIdStr The id of the match the player is betting on
     * @param playerIdStr The id of the player who is placing the bet
     * @param rawBetAmount The amount of USDC for the bet before fees
     * @param tierId The tier id for the bet
     */
    function deposit(string calldata matchIdStr, string calldata playerIdStr, uint256 rawBetAmount, uint8 tierId)
        external
        nonReentrant
        whenNotPaused
    {
        // TierId parameter (on-chain enforcement)
        Tier memory tier = tiers[tierId];
        if (!tier.active) revert FragBoxBetting__TierNotActive();
        if (rawBetAmount < tier.minBetAmount) revert FragBoxBetting__BetTooSmall();
        if (rawBetAmount > tier.maxBetAmount) revert FragBoxBetting__BetTooLarge();

        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        // Associate match with tier (locked on first deposit)
        if (mb.tierId == 0) {
            mb.tierId = tierId;
        } else if (mb.tierId != tierId) {
            revert FragBoxBetting__TierMismatch();
        }

        if (mb.matchStatus == MatchStatus.Ongoing || mb.matchStatus == MatchStatus.Finished) {
            revert FragBoxBetting__MatchStatusDoesNotAllowBets();
        }

        if (mb.matchStatus == MatchStatus.Invalid) {
            revert FragBoxBetting__MatchStatusIsInvalid();
        }

        // This prevents match fixing by forcing players to register their wallet addresses beforehand
        bytes32 playerKey = _getKey(playerIdStr);
        if (playerIdToRegisteredWallet[playerKey] != msg.sender) {
            revert FragBoxBetting__InvalidWallet();
        }

        // Calculate house fee and actual bet amount
        uint256 fee = calculateDepositFee(rawBetAmount);
        uint256 betAmount = rawBetAmount - fee;

        if (betAmount == 0) {
            revert FragBoxBetting__BetTooSmall();
        }

        I_USDC.safeTransferFrom(msg.sender, address(this), rawBetAmount);

        // Send fee to owner
        ownerFeesCollected += fee;

        Faction faction = mb.playerToFaction[playerKey];

        if (faction == Faction.Unknown) {
            uint256 existingBetAmount = mb.betAmountsInRosterValidationFlight[msg.sender][playerKey].betAmount
                + mb.walletToPlayerIdToBet[msg.sender][playerKey];
            if (existingBetAmount + rawBetAmount < tier.minBetAmount) revert FragBoxBetting__BetTooSmall();
            if (existingBetAmount + rawBetAmount > tier.maxBetAmount) revert FragBoxBetting__BetTooLarge();

            mb.betAmountsInRosterValidationFlight[msg.sender][playerKey] =
                InFlightBet({betAmount: existingBetAmount + betAmount, lastDepositTime: block.timestamp});
        } else {
            mb.walletToPlayerIdToBet[msg.sender][playerKey] += betAmount;
            mb.factionTotals[uint8(faction)] += betAmount;
        }

        emit BetPlaced(matchKey, matchIdStr, msg.sender, rawBetAmount, playerIdStr, tierId);
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

        MatchStatus matchStatus = mb.matchStatus;
        if (matchStatus != MatchStatus.Finished && matchStatus != MatchStatus.Invalid) {
            revert FragBoxBetting__MatchNotFinished();
        }

        bytes32 playerKey = _getKey(playerIdStr);
        uint256 betAmount = mb.walletToPlayerIdToBet[msg.sender][playerKey];
        if (betAmount == 0) revert FragBoxBetting__NoBetForPlayer();

        Faction winnerFaction = mb.winnerFaction;
        if (winnerFaction == Faction.Unknown && matchStatus != MatchStatus.Invalid) {
            revert FragBoxBetting__WinnerUnknown();
        }
        uint8 winnerFId = uint8(winnerFaction);

        uint256[4] storage winnerTotals = mb.factionTotals;

        // Draw or no winning bets -> full refund
        if (winnerFaction == Faction.Draw || winnerTotals[winnerFId] == 0 || matchStatus == MatchStatus.Invalid) {
            playerToWinnings[msg.sender][playerKey] += betAmount;
            mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;
            emit MatchClaimed(matchKey, matchIdStr, msg.sender, playerIdStr, betAmount, true);
            return;
        }

        uint256 totalWinningBet = winnerTotals[winnerFId];
        uint256 totalLosingBet = (winnerFaction == Faction.Faction1)
            ? winnerTotals[uint8(Faction.Faction2)]
            : winnerTotals[uint8(Faction.Faction1)];

        // STRICT SYMMETRY: winning side always gets exactly 2 * min(W, L)
        uint256 minBet = totalWinningBet < totalLosingBet ? totalWinningBet : totalLosingBet;

        Faction playerFaction = mb.playerToFaction[playerKey];
        uint256 payoutOrRefund = 0;

        if (playerFaction == winnerFaction) {
            // WINNER PATH: always get symmetric share (2 * minBet) + excess refund if winners overbet
            payoutOrRefund = Math.mulDiv(betAmount, 2 * minBet, totalWinningBet, Math.Rounding.Ceil);

            // Refund excess when winning side overbet (symmetric to loser path)
            if (totalWinningBet > totalLosingBet) {
                uint256 excess = totalWinningBet - minBet;
                payoutOrRefund += Math.mulDiv(betAmount, excess, totalWinningBet, Math.Rounding.Ceil);
            }
        } else {
            // LOSER PATH: only get excess refund if losing faction overbet
            if (totalLosingBet <= totalWinningBet) {
                revert FragBoxBetting__LosingFactionCannotClaim(playerFaction);
            }

            // excess on losing side is refunded pro-rata
            uint256 excess = totalLosingBet - minBet;
            payoutOrRefund = Math.mulDiv(betAmount, excess, totalLosingBet, Math.Rounding.Ceil);
        }

        playerToWinnings[msg.sender][playerKey] += payoutOrRefund;
        mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;

        emit MatchClaimed(matchKey, matchIdStr, msg.sender, playerIdStr, payoutOrRefund, false);
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

        MatchStatus matchStatus = mb.matchStatus;
        if (matchStatus != MatchStatus.Invalid) {
            if (matchStatus == MatchStatus.Finished) {
                revert FragBoxBetting__MatchAlreadyFinished();
            }

            if (block.timestamp <= mb.lastStatusUpdate + emergencyRefundTimeout) {
                revert FragBoxBetting__TimeoutNotReached();
            }
        }

        bytes32 playerKey = _getKey(playerIdStr);

        // Refund all bets
        uint256 betAmount = mb.walletToPlayerIdToBet[msg.sender][playerKey];
        playerToWinnings[msg.sender][playerKey] += betAmount;
        mb.walletToPlayerIdToBet[msg.sender][playerKey] = 0;

        emit EmergencyRefund(matchKey, matchIdStr, msg.sender, playerIdStr, betAmount);
    }

    /**
     * Allows a player to withdraw their winnings from the contract
     * @param playerId The player id the sender wallet is associated with
     */
    function withdraw(string calldata playerId) external nonReentrant whenNotPaused {
        bytes32 playerKey = _getKey(playerId);

        uint256 winningsAmount = playerToWinnings[msg.sender][playerKey];
        if (winningsAmount <= 0) {
            revert FragBoxBetting__InsufficientFundsForWithdrawal();
        }

        I_USDC.safeTransfer(msg.sender, winningsAmount);
        playerToWinnings[msg.sender][playerKey] = 0;
        emit WinningsWithdrawn(playerKey, playerId, msg.sender, winningsAmount);
    }

    /**
     * Allows the owner to withdraw collected deposit fees
     */
    function withdrawOwnerFees() external onlyOwner nonReentrant whenNotPaused {
        uint256 amount = ownerFeesCollected;
        I_USDC.safeTransfer(owner(), amount);
        ownerFeesCollected = 0;
        emit OwnerFeesWithdrawn(owner(), amount);
    }

    /**
     * Allows the user to withdraw funds from the contract when they are in flight (chainlink functions) for roster validation
     * This phase occurs right after a user deposits (bets) for the first time on any match
     * These funds could get locked up if the chainlink functions system fails to call fulfillRequest or fulfillRequest returns or reverts
     */
    function withdrawBetAmountsInRosterValidationFlight(string calldata matchId, string calldata playerId)
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 matchKey = _getKey(matchId);
        MatchBet storage mb = matchBets[matchKey];

        bytes32 playerKey = _getKey(playerId);
        InFlightBet storage inFlightBet = mb.betAmountsInRosterValidationFlight[msg.sender][playerKey];

        if (inFlightBet.lastDepositTime + inFlightWithdrawalTimeout > block.timestamp) {
            revert FragBoxBetting__InFlightTimeoutNotReached();
        }

        uint256 withdrawalAmount = inFlightBet.betAmount;
        if (withdrawalAmount <= 0) {
            revert FragBoxBetting__InsufficientFundsForWithdrawal();
        }

        I_USDC.safeTransfer(msg.sender, withdrawalAmount);
        inFlightBet.betAmount = 0;
        emit InFlightFundsWithdrawn(matchKey, matchId, playerKey, playerId, msg.sender, withdrawalAmount);
    }

    /**
     * Allows the owner to withdraw funds from the contract when they are in flight (chainlink functions) for roster validation back to the original user
     * This phase occurs right after a user deposits (bets) for the first time on any match
     * These funds could get locked up if the chainlink functions system fails to call fulfillRequest or fulfillRequest returns or reverts
     * @param withdrawalAddress The user who originally deposited
     */
    function withdrawBetAmountsInRosterValidationFlight(
        string calldata matchId,
        string calldata playerId,
        address withdrawalAddress
    ) external nonReentrant whenNotPaused onlyOwner {
        bytes32 matchKey = _getKey(matchId);
        MatchBet storage mb = matchBets[matchKey];

        bytes32 playerKey = _getKey(playerId);
        InFlightBet storage inFlightBet = mb.betAmountsInRosterValidationFlight[msg.sender][playerKey];

        uint256 withdrawalAmount = inFlightBet.betAmount;
        if (withdrawalAmount <= 0) {
            revert FragBoxBetting__InsufficientFundsForWithdrawal();
        }

        I_USDC.safeTransfer(withdrawalAddress, withdrawalAmount);
        inFlightBet.betAmount = 0;
        emit InFlightFundsWithdrawn(matchKey, matchId, playerKey, playerId, withdrawalAddress, withdrawalAmount);
    }

    /* -------------------------------- PAUSABLE -------------------------------- */
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /* -------------------------------------------------------------------------- */
    /*                                   SETTERS                                  */
    /* -------------------------------------------------------------------------- */
    /**
     * Sets the timeout for emergency refunds
     * @param newEmergencyRefundTimeout The new timeout in seconds
     */
    function setEmergencyRefundTimeout(uint256 newEmergencyRefundTimeout) external onlyOwner {
        emit EmergencyRefundTimeoutUpdated(emergencyRefundTimeout, newEmergencyRefundTimeout);
        emergencyRefundTimeout = newEmergencyRefundTimeout;
    }

    /**
     * Sets the timeout for in-flight withdrawal requests
     * @param newInFlightWithdrawalTimeout The new timeout in seconds
     */
    function setInFlightWithdrawalTimeout(uint256 newInFlightWithdrawalTimeout) external onlyOwner {
        emit InFlightWithdrawalTimeoutUpdated(inFlightWithdrawalTimeout, newInFlightWithdrawalTimeout);
        inFlightWithdrawalTimeout = newInFlightWithdrawalTimeout;
    }

    /**
     * Sets the house fee percentage for deposits (e.g. if 1, then 1% fee on deposits that goes to the owner)
     * @param newHouseFeePercentage The new house fee percentage
     */
    function setHouseFeePercentage(uint256 newHouseFeePercentage) external onlyOwner {
        emit HouseFeePercentageUpdated(houseFeePercentage, newHouseFeePercentage);
        houseFeePercentage = newHouseFeePercentage;
    }

    /**
     * Creates or modifies an existing tier
     * @param tierId The id of the tier
     * @param minBetAmount The min bet amount of the tier in USD
     * @param maxBetAmount The max bet amount of the tier in USD
     */
    function setTier(uint8 tierId, uint256 minBetAmount, uint256 maxBetAmount) external onlyOwner {
        _setTier(tierId, minBetAmount, maxBetAmount);
        emit TierUpdated(tierId, minBetAmount, maxBetAmount);
    }

    /**
     * Activate or deactivate a tier
     * @param tierId The id of the tier
     * @param active The state to set
     */
    function toggleTier(uint8 tierId, bool active) external onlyOwner {
        tiers[tierId].active = active;
        emit TierUpdated(tierId, tiers[tierId].minBetAmount, tiers[tierId].maxBetAmount);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   GETTERS                                  */
    /* -------------------------------------------------------------------------- */
    /**
     * @return The address of the USDC contract
     */
    function getUsdc() external view returns (IERC20Metadata) {
        return I_USDC;
    }

    /**
     * @return The count of decimals associated with the USDC contract
     */
    function getUsdcDecimals() external view returns (uint8) {
        return I_USDC_DECIMALS;
    }

    /**
     * Scales a value by the number of decimals that USDC uses
     * @notice Converts a human-readable USDC amount into the raw token amount (scaled by 6 decimals)
     * @param value The amount in "normal" USDC units (e.g. 5 means 5.000000 USDC)
     * @return The scaled value
     */
    function toUsdc(uint256 value) public view returns (uint256) {
        return value * (10 ** I_USDC_DECIMALS);
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
            tierId: mb.tierId,
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
     * Gets the amount of USDC winnings a player has earned but hasn't withdrawn
     * @param playerKey The player who earned the winnings and is associated with the msg.sender
     * @return The winnings in USDC
     */
    function getWinnings(bytes32 playerKey) external view returns (uint256) {
        return playerToWinnings[msg.sender][playerKey];
    }

    /**
     * Gets the amount of owner fees accumulated that hasn't been withdrawn yet
     * @return The amount in USDC
     */
    function getOwnerFeesCollected() external view onlyOwner returns (uint256) {
        return ownerFeesCollected;
    }

    /**
     * @return The amount of USDC that is in roster validation flight for the msg.sender
     */
    function getBetAmountsInRosterValidationFlight(string calldata matchId, string calldata playerId)
        external
        view
        returns (InFlightBet memory)
    {
        MatchBet storage mb = matchBets[_getKey(matchId)];
        return mb.betAmountsInRosterValidationFlight[msg.sender][_getKey(playerId)];
    }

    /**
     * @param playerIdStr The playerId to get the registered wallet of
     * @return The wallet registered to the playerId
     */
    function getRegisteredWallet(string calldata playerIdStr) external view returns (address) {
        return playerIdToRegisteredWallet[_getKey(playerIdStr)];
    }

    /**
     * Calcuates the fee for new deposits
     * @param depositAmount The total amount of USDC that someone is depositing
     * @return The fee in USDC
     */
    function calculateDepositFee(uint256 depositAmount) public view returns (uint256) {
        return (depositAmount * houseFeePercentage) / 100;
    }

    /**
     * Gets the percentage the contract takes during deposits
     * @return The percentage
     */
    function getHouseFeePercentage() external view returns (uint256) {
        return houseFeePercentage;
    }

    /**
     * @param tierId The id associated with the tier you want to get
     * @return The tier associated with the id
     */
    function getTier(uint8 tierId) external view returns (Tier memory) {
        return tiers[tierId];
    }
}
