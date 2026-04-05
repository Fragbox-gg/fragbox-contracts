// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FragBoxBetting is ReentrancyGuard, Ownable, FunctionsClient, Pausable {
    using SafeERC20 for IERC20Metadata;
    using FunctionsRequest for FunctionsRequest.Request;

    /* -------------------------------------------------------------------------- */
    /*                                   ERRORS                                   */
    /* -------------------------------------------------------------------------- */
    error FragBoxBetting__InvalidWallet();
    error FragBoxBetting__TierMismatch();
    error FragBoxBetting__TierNotActive();
    error FragBoxBetting__MatchStatusDoesNotAllowBets();
    error FragBoxBetting__PlayerAlreadyBetOnMatch();
    error FragBoxBetting__MatchStatusIsInvalid();
    error FragBoxBetting__MatchAlreadyFinished();
    error FragBoxBetting__MatchNotFinished();
    error FragBoxBetting__TimeoutNotReached();
    error FragBoxBetting__InFlightTimeoutNotReached();
    error FragBoxBetting__BetTooSmall();
    error FragBoxBetting__BetTooLarge();
    error FragBoxBetting__RosterAlreadyRequested();
    error FragBoxBetting__SecretsNotSet();
    error FragBoxBetting__StatusUpdateTooSoon();
    error FragBoxBetting__RosterUpdateTooSoon();
    error FragBoxBetting__NonOwnerFeeRequired();
    error FragBoxBetting__NoBetForPlayer();
    error FragBoxBetting__InsufficientFundsForWithdrawal();
    error FragBoxBetting__WinnerUnknown();
    error FragBoxBetting__TierIdMustBeGreaterThanZero();
    error FragBoxBetting__MinBetMustBeGreaterThanMaxBet();
    error FragBoxBetting__LosingFactionCannotClaim(Faction faction);

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

    /* -------------------------------------------------------------------------- */
    /*                                   EVENTS                                   */
    /* -------------------------------------------------------------------------- */
    event BetPlaced(
        bytes32 indexed matchKey, string matchId, address indexed better, uint256 amount, string playerId, uint8 tierId
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
    event PlayerRegistered(bytes32 indexed playerId, address indexed wallet, string playerIdStr);
    /* --------------------------- CHAINLINK FUNCTIONS -------------------------- */
    event StatusRequestSent(bytes32 indexed requestId, bytes32 indexed matchKey, string matchId);
    event RosterRequestSent(
        bytes32 indexed requestId, bytes32 indexed matchKey, string matchId, bytes32 indexed playerKey, string playerId
    );
    event StatusRequestFulfilled(
        bytes32 indexed requestId, bytes32 indexed matchKey, MatchStatus status, Faction winnerFaction
    );
    event RosterRequestFulfilled(bytes32 indexed matchKey, bytes32 indexed playerKey, Faction playerFaction);
    event StatusRequestError(bytes32 indexed requestId, bytes32 indexed matchKey, string error);
    event RosterRequestError(
        bytes32 indexed requestId, bytes32 indexed matchKey, bytes32 indexed playerKey, string error
    );
    /* ------------------------- ADMIN / CONFIG CHANGES ------------------------- */
    event EmergencyRefundTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event InFlightWithdrawalTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event HouseFeePercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event MinStatusUpdateFeeUpdated(uint256 oldFee, uint256 newFee);
    event StatusUpdateCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event RosterUpdateCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event DonSecretsUpdated();
    event OwnerFeesWithdrawn(address indexed wallet, uint256 amountWithdrawn);
    event InFlightFundsWithdrawn(address indexed wallet, uint256 amountWithdrawn);
    event TierUpdated(uint8 indexed tierId, uint256 minBetAmount, uint256 maxBetAmount);

    /* -------------------------------------------------------------------------- */
    /*                                  CONSTANTS                                 */
    /* -------------------------------------------------------------------------- */
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;

    /* -------------------------------------------------------------------------- */
    /*                             IMMUTABLE VARIABLES                            */
    /* -------------------------------------------------------------------------- */
    IERC20Metadata private immutable I_USDC;
    address private immutable I_CHAINLINKFUNCTIONSROUTER;
    bytes32 private immutable I_DONID;
    uint64 private immutable I_SUBSCRIPTIONID;
    uint8 private immutable I_USDC_DECIMALS;
    string private I_GETROSTER;
    string private I_GETSTATUS;

    /* -------------------------------------------------------------------------- */
    /*                              STORAGE VARIABLES                             */
    /* -------------------------------------------------------------------------- */
    mapping(uint8 tierId => Tier) private tiers;
    mapping(bytes32 matchKey => MatchBet matchBet) private matchBets;
    mapping(bytes32 playerId => address registeredWallet) private playerIdToRegisteredWallet;
    mapping(bytes32 requestId => RequestInfo requestInfo) private requestIdToInfo;
    mapping(address wallet => uint256 amount) private betAmountsInRosterValidationFlight;
    mapping(address wallet => uint256 lastDepositTime) private walletToLastDepositTime;
    mapping(address wallet => mapping(bytes32 playerKey => uint256 winnings)) private playerToWinnings;

    uint8 private donHostedSecretsSlotId;
    uint64 private donHostedSecretsVersion;
    uint256 private ownerFeesCollected;

    /* --------------------------- OWNER / CONFIG VARS -------------------------- */
    uint256 private emergencyRefundTimeout = 4 hours;
    uint256 private inFlightWithdrawalTimeout = 1 hours;
    uint256 private houseFeePercentage = 1; // 1 = 1%
    uint256 private minStatusUpdateFee = 20e6; // $20
    uint256 private statusUpdateCooldown = 5 minutes;
    uint256 private rosterUpdateCooldown = 10 minutes;

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
     * @dev Non-owners must pay the fee in USDC (transferred to the contract). Owner calls are free
     * @param feeAmount The minimum fee necessary for the function in USDC
     */
    function _costsFeeOrOwner(uint256 feeAmount) internal {
        if (msg.sender != owner()) {
            // Require some USDC is sent (basic protection)
            if (I_USDC.balanceOf(msg.sender) < feeAmount) revert FragBoxBetting__NonOwnerFeeRequired();

            I_USDC.safeTransferFrom(msg.sender, address(this), feeAmount);

            // Accumulate the fee (you could also send to owner instantly, but accumulating is fine)
            ownerFeesCollected += feeAmount;
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

        if (block.timestamp - rosterUpdateCooldown < mb.playerToLastRosterUpdate[playerKey] + rosterUpdateCooldown) {
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
            playerKey: playerKey,
            betAmount: betAmount,
            wallet: msg.sender
        });
        emit RosterRequestSent(requestId, matchKey, matchIdStr, playerKey, playerId);
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

    constructor(
        address usdcAddress,
        address chainLinkFunctionsRouter,
        bytes32 donId,
        uint64 subscriptionId,
        string memory getRoster,
        string memory getStatus
    ) Ownable(msg.sender) FunctionsClient(chainLinkFunctionsRouter) {
        I_USDC = IERC20Metadata(usdcAddress);
        I_CHAINLINKFUNCTIONSROUTER = chainLinkFunctionsRouter;
        I_DONID = donId;
        I_SUBSCRIPTIONID = subscriptionId;
        I_USDC_DECIMALS = I_USDC.decimals();
        I_GETROSTER = getRoster;
        I_GETSTATUS = getStatus;

        // Default tiers (low / mid / high stakes) – owner can change after deployment
        _setTier(1, 5, 10); // $5 – $10
        _setTier(2, 10, 20); // $10 – $20
        _setTier(3, 50, 100); // $50 – $100
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
        emit DonSecretsUpdated();
    }

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
     * Called REPEATEDLY by backend to update match status
     * @notice Need to setup a CRON job or Chainlink automation to routinely call this based on active matchIds that users bet on
     * @param matchIdStr The match Id to check
     */
    function updateMatchStatus(string calldata matchIdStr)
        external
        nonReentrant
        whenNotPaused
        costsFeeOrOwner(minStatusUpdateFee)
    {
        bytes32 matchKey = _getKey(matchIdStr);
        MatchBet storage mb = matchBets[matchKey];

        if (mb.matchStatus == MatchStatus.Finished) revert FragBoxBetting__MatchAlreadyFinished();
        if (donHostedSecretsVersion == 0) revert FragBoxBetting__SecretsNotSet();

        if (block.timestamp - statusUpdateCooldown < mb.lastStatusUpdate) {
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
        emit StatusRequestSent(requestId, matchKey, matchIdStr);
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
        RequestType requestType = requestInfo.requestType;

        if (err.length > 0) {
            if (requestType == RequestType.Status) {
                emit StatusRequestError(requestId, matchKey, string(err));
            } else if (requestType == RequestType.Roster) {
                emit RosterRequestError(requestId, matchKey, requestInfo.playerKey, string(err));
            }
            return;
        }

        // Request ownership validation (prevents stale data corruption)
        if (requestType == RequestType.Status) {
            MatchBet storage mb = matchBets[matchKey];

            if (mb.statusRequestId != requestId) {
                emit StatusRequestError(requestId, matchKey, "Stale Status Request Id");
                return;
            }

            if (response.length != 2) {
                emit StatusRequestError(requestId, matchKey, "Invalid Status Response");
                return;
            }

            MatchStatus currentMatchStatus = mb.matchStatus;
            MatchStatus newMatchStatus = MatchStatus(uint8(response[0]));

            // EDGE-CASE PROTECTION:
            // First status update must land on Unknown / Voting / Ready.
            // Anything else means the match skipped the betting window → invalid + full refunds.
            if (currentMatchStatus == MatchStatus.Unknown) {
                if (
                    newMatchStatus != MatchStatus.Unknown && newMatchStatus != MatchStatus.Voting
                        && newMatchStatus != MatchStatus.Ready
                ) {
                    mb.matchStatus = MatchStatus.Invalid;
                    emit StatusRequestFulfilled(requestId, matchKey, MatchStatus.Invalid, Faction.Unknown);
                    return;
                }
            }

            mb.matchStatus = newMatchStatus;

            Faction winnerFaction = Faction(uint8(response[1]));
            if (newMatchStatus == MatchStatus.Finished) {
                mb.winnerFaction = winnerFaction;
            }

            emit StatusRequestFulfilled(requestId, matchKey, newMatchStatus, winnerFaction);
        } else if (requestType == RequestType.Roster) {
            address requestor = requestInfo.wallet;
            uint256 betAmount = requestInfo.betAmount;
            bytes32 playerKey = requestInfo.playerKey;

            if (betAmountsInRosterValidationFlight[requestor] < betAmount) {
                emit RosterRequestError(requestId, matchKey, playerKey, "Bet was withdrawn during roster validation");
                return;
            }

            if (response.length != 1) {
                emit RosterRequestError(requestId, matchKey, playerKey, "Invalid Roster Response");
                return;
            }

            uint8 fId = uint8(response[0]);
            Faction playerFaction = Faction(fId);

            if (playerFaction != Faction.Faction1 && playerFaction != Faction.Faction2) {
                emit RosterRequestError(requestId, matchKey, playerKey, "Invalid player");
                return;
            }

            MatchBet storage mb = matchBets[matchKey];

            if (mb.playerToFaction[playerKey] != Faction.Unknown) {
                emit RosterRequestError(requestId, matchKey, playerKey, "Faction already assigned");
            }

            mb.playerToFaction[playerKey] = playerFaction;

            betAmountsInRosterValidationFlight[requestor] -= betAmount;
            mb.walletToPlayerIdToBet[requestor][playerKey] += betAmount;

            // Update totals
            mb.factionTotals[fId] += betAmount;

            emit RosterRequestFulfilled(matchKey, playerKey, playerFaction);
        }
    }

    /**
     * Place Bet on an ongoing faceit match that you are a part of. This is where players pay their deposit fee so that we don't have to calculate fees during payout/resolution
     * @param matchIdStr The id of the match the player is betting on
     * @param playerIdStr The id of the player who is placing the bet
     * @param amount The amount of the bet (in wei)
     * @param tierId The tier id for the bet
     */
    function deposit(string calldata matchIdStr, string calldata playerIdStr, uint256 amount, uint8 tierId)
        external
        nonReentrant
        whenNotPaused
    {
        // TierId parameter (on-chain enforcement)
        Tier memory tier = tiers[tierId];
        if (!tier.active) revert FragBoxBetting__TierNotActive();
        if (amount < tier.minBetAmount) revert FragBoxBetting__BetTooSmall();
        if (amount > tier.maxBetAmount) revert FragBoxBetting__BetTooLarge();

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
        uint256 fee = calculateDepositFee(amount);
        uint256 betAmount = amount - fee;

        if (betAmount == 0) {
            revert FragBoxBetting__BetTooSmall();
        }

        I_USDC.safeTransferFrom(msg.sender, address(this), amount);

        // Send fee to owner
        ownerFeesCollected += fee;

        Faction faction = mb.playerToFaction[playerKey];

        if (faction == Faction.Unknown) {
            betAmountsInRosterValidationFlight[msg.sender] += betAmount;
            walletToLastDepositTime[msg.sender] = block.timestamp;
            updateMatchRoster(matchIdStr, playerIdStr, betAmount);
        } else {
            revert FragBoxBetting__PlayerAlreadyBetOnMatch();
        }

        emit BetPlaced(matchKey, matchIdStr, msg.sender, amount, playerIdStr, tierId);
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
    function withdrawBetAmountsInRosterValidationFlight() external nonReentrant whenNotPaused {
        if (walletToLastDepositTime[msg.sender] + inFlightWithdrawalTimeout > block.timestamp) {
            revert FragBoxBetting__InFlightTimeoutNotReached();
        }

        uint256 withdrawalAmount = betAmountsInRosterValidationFlight[msg.sender];
        if (withdrawalAmount <= 0) {
            revert FragBoxBetting__InsufficientFundsForWithdrawal();
        }

        I_USDC.safeTransfer(msg.sender, withdrawalAmount);
        betAmountsInRosterValidationFlight[msg.sender] = 0;
        emit InFlightFundsWithdrawn(msg.sender, withdrawalAmount);
    }

    /**
     * Allows the owner to withdraw funds from the contract when they are in flight (chainlink functions) for roster validation back to the original user
     * This phase occurs right after a user deposits (bets) for the first time on any match
     * These funds could get locked up if the chainlink functions system fails to call fulfillRequest or fulfillRequest returns or reverts
     * @param withdrawalAddress The user who originally deposited
     */
    function withdrawBetAmountsInRosterValidationFlight(address withdrawalAddress)
        external
        nonReentrant
        whenNotPaused
        onlyOwner
    {
        uint256 withdrawalAmount = betAmountsInRosterValidationFlight[withdrawalAddress];
        if (withdrawalAmount <= 0) {
            revert FragBoxBetting__InsufficientFundsForWithdrawal();
        }

        I_USDC.safeTransfer(withdrawalAddress, withdrawalAmount);
        betAmountsInRosterValidationFlight[withdrawalAddress] -= withdrawalAmount;
        emit InFlightFundsWithdrawn(withdrawalAddress, withdrawalAmount);
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
     * Sets the min fee for status updates in USD (when not the owner)
     * @param newMinStatusUpdateFee The new min fee in USD wei
     */
    function setMinStatusUpdateFee(uint256 newMinStatusUpdateFee) external onlyOwner {
        emit MinStatusUpdateFeeUpdated(minStatusUpdateFee, newMinStatusUpdateFee);
        minStatusUpdateFee = newMinStatusUpdateFee;
    }

    /**
     * Sets the cooldown period for status updates
     * @param newStatusUpdateCooldown The cooldown period in seconds
     */
    function setStatusUpdateCooldown(uint256 newStatusUpdateCooldown) external onlyOwner {
        emit StatusUpdateCooldownUpdated(statusUpdateCooldown, newStatusUpdateCooldown);
        statusUpdateCooldown = newStatusUpdateCooldown;
    }

    /**
     * Sets the cooldown period for roster updates
     * @param newRosterUpdateCooldown The cooldown period in seconds
     */
    function setRosterUpdateCooldown(uint256 newRosterUpdateCooldown) external onlyOwner {
        emit RosterUpdateCooldownUpdated(rosterUpdateCooldown, newRosterUpdateCooldown);
        rosterUpdateCooldown = newRosterUpdateCooldown;
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
     * @return The address of the chainlink functions router contract
     */
    function getChainlinkFunctionsRouter() external view returns (address) {
        return I_CHAINLINKFUNCTIONSROUTER;
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
    function getOwnerFeesCollected() external view onlyOwner returns (uint256) {
        return ownerFeesCollected;
    }

    /**
     * @return The amount of eth in wei that is in roster validation flight for the msg.sender
     */
    function getBetAmountsInRosterValidationFlight() external view returns (uint256) {
        return betAmountsInRosterValidationFlight[msg.sender];
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
     * @param depositAmount The total amount of eth in wei that someone is depositing
     * @return The fee in wei
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
