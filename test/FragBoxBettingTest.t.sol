// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployFragBoxBetting} from "../script/DeployFragBoxBetting.s.sol";
import {FragBoxBetting} from "../src/FragBoxBetting.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SimulateOracles} from "./SimulateOracles.t.sol";

contract FragBoxBettingTest is SimulateOracles {
    FragBoxBetting fragBoxBetting;
    address chainLinkFunctionsRouter;

    address public USER;
    address public USER2;
    address public USER3;

    uint256 constant SEND_VALUE = 5e6; // USDC has 6 decimals so this is $5
    uint8 constant DEFAULT_TIER_ID = 1;
    uint256 constant STARTING_USDC_BALANCE = 50e6; // $50
    uint256 constant WARP_TIME = 5 minutes;

    event StatusUpdated(bytes32 indexed matchKey, string matchId, FragBoxBetting.MatchStatus status, FragBoxBetting.Faction winnerFaction);
    event RosterUpdated(bytes32 indexed matchKey, string matchId, bytes32 indexed playerKey, string playerId, address indexed bettor, FragBoxBetting.Faction playerFaction);
    event HouseFeePercentageUpdated(uint256 oldPercentage, uint256 newPercentage);

    function setUp() external {
        DeployFragBoxBetting deployFragBoxBetting = new DeployFragBoxBetting();
        fragBoxBetting = deployFragBoxBetting.run();

        USER = makeAddr("USER");
        deal(address(fragBoxBetting.getUsdc()), USER, STARTING_USDC_BALANCE);

        USER2 = makeAddr("USER2");
        deal(address(fragBoxBetting.getUsdc()), USER2, STARTING_USDC_BALANCE);

        USER3 = makeAddr("USER3");
        deal(address(fragBoxBetting.getUsdc()), USER3, STARTING_USDC_BALANCE);

        vm.startPrank(USER);
        fragBoxBetting.getUsdc().approve(address(fragBoxBetting), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER2);
        fragBoxBetting.getUsdc().approve(address(fragBoxBetting), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER3);
        fragBoxBetting.getUsdc().approve(address(fragBoxBetting), type(uint256).max);
        vm.stopPrank();

        super.setUpSimulation(fragBoxBetting);

        vm.startPrank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER);
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID, USER);
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                                DEPOSIT TESTS                               */
    /* -------------------------------------------------------------------------- */
    function testPlaceBetWithNoBalance() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(FragBoxBetting.FragBoxBetting__BetTooSmall.selector, 0));
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, 0, DEFAULT_TIER_ID);
        vm.stopPrank();
    }

    function testPlaceBet() public {
        vm.startPrank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);
        vm.stopPrank();
    }

    function testPausableDeposit() public {
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.pause();

        vm.prank(USER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.unpause();

        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);
    }

    function testDepositEnforcesMinBetUSD() public {
        uint256 tooSmallDeposit = 3_000_000; // $3
        vm.prank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__BetTooSmall.selector);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, tooSmallDeposit, DEFAULT_TIER_ID);
    }

    function testDepositEnforcesMaxBetUSD() public {
        uint256 tooLargeDeposit = 100_000_000_000_000; // $100,000
        deal(address(fragBoxBetting.getUsdc()), USER, tooLargeDeposit);
        vm.prank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__BetTooLarge.selector);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, tooLargeDeposit, DEFAULT_TIER_ID);
    }

    function testDepositWithInvalidWallet() public {
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER2);

        vm.startPrank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__InvalidWallet.selector);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                    CHAINLINK FUNCTIONS INTEGRATION TESTS                   */
    /* -------------------------------------------------------------------------- */
    function test_FulfillRosterUpdate_Success() public {
        bytes32 matchKey = fragBoxBetting.getKey(MATCHID);

        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assertTrue(
            fragBoxBetting.getPlayerFaction(matchKey, fragBoxBetting.getKey(WINNING_PLAYERID))
                == FragBoxBetting.Faction.Faction1
        );
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Unknown);
        assertEq(mb.lastStatusUpdate, 0);
    }

    function test_FulfillStatusUpdate_Ongoing() public {
        bytes32 matchKey = fragBoxBetting.getKey(MATCHID);

        // 1. Roster first
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Unknown);

        // 2. Status update to voting
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Voting, FragBoxBetting.Faction.Unknown);

        mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Voting);

        vm.warp(block.timestamp + WARP_TIME);

        // 3. Status update to ongoing
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Ongoing, FragBoxBetting.Faction.Unknown);

        mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Ongoing);
    }

    function test_FulfillStatusUpdate_Finished_SetsWinnerAndResolved() public {
        bytes32 matchKey = fragBoxBetting.getKey(MATCHID);

        // Roster first
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        // Voting status
        vm.expectEmit(true, true, true, true);
        emit StatusUpdated(
            matchKey, MATCHID, FragBoxBetting.MatchStatus.Voting, FragBoxBetting.Faction.Unknown
        );

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Voting, FragBoxBetting.Faction.Unknown);

        vm.warp(block.timestamp + WARP_TIME);

        // Finished status
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Finished, WINNING_FACTION);

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(matchKey);
        assert(mb.matchStatus == FragBoxBetting.MatchStatus.Finished);
        assertEq(uint8(mb.winnerFaction), uint8(WINNING_FACTION));
    }

    function test_DepositAfterRosterValidated_Succeeds() public {
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        FragBoxBetting.MatchBetView memory mb = fragBoxBetting.getMatchBet(fragBoxBetting.getKey(MATCHID));

        uint256 sum = 0;
        uint256 len = mb.factionTotals.length;
        for (uint256 i = 0; i < len; i++) {
            sum += mb.factionTotals[i];
        }

        assertGt(sum, 0);
    }

    function testEmergencyRefundAfterTimeout() public {
        uint256 balBefore = fragBoxBetting.getUsdc().balanceOf(USER);

        // Deposit, advance time >24h, call emergencyRefund
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);
        
        // Validate roster
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Ready, FragBoxBetting.Faction.Unknown);

        vm.warp(block.timestamp + WARP_TIME);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Ongoing, FragBoxBetting.Faction.Unknown);

        vm.startPrank(USER);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__TimeoutNotReached.selector);
        fragBoxBetting.emergencyRefund(MATCHID, WINNING_PLAYERID);
        vm.warp(block.timestamp + 6 hours);
        fragBoxBetting.emergencyRefund(MATCHID, WINNING_PLAYERID);

        // then player calls withdraw() and gets full amount back
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER), balBefore - fee);
    }

    function testNoOneBetOnWinner_AllRefunded() public {
        uint256 balBefore = fragBoxBetting.getUsdc().balanceOf(USER);

        // deposit only on losing faction
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, LOSING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);
        
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, LOSING_PLAYERID, USER, LOSING_FACTION);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Ready, FragBoxBetting.Faction.Unknown);

        vm.warp(block.timestamp + WARP_TIME);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Finished, WINNING_FACTION);

        // claim() should refund everyone via playerToWinnings
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);

        // withdraw succeeds
        fragBoxBetting.withdraw(LOSING_PLAYERID);
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        vm.stopPrank();
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER), balBefore - fee);
    }

    function testClaimWithDrawWinnerRefundsAll() public {
        uint256 startingBalance = fragBoxBetting.getUsdc().balanceOf(USER);

        // deposit some on Draw
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        // fulfill status with "draw"
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Finished, FragBoxBetting.Faction.Draw);

        // claim
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        // assert full refund to winnings (or fix this behavior if not intended)
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER), startingBalance - fee);
    }

    function test_RosterFailure_RefundViaFlightWithdraw() public {
        uint256 balBefore = fragBoxBetting.getUsdc().balanceOf(USER);

        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        vm.expectRevert(FragBoxBetting.FragBoxBetting__PlayerFactionInvalid.selector);
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, FragBoxBetting.Faction.Unknown);

        // Funds are now in flight (net of fee)
        vm.prank(USER);
        assertEq(
            fragBoxBetting.getBetAmountsInRosterValidationFlight(MATCHID, WINNING_PLAYERID).betAmount,
            SEND_VALUE - fragBoxBetting.calculateDepositFee(SEND_VALUE)
        );

        vm.warp(block.timestamp + 1 hours + 1 minutes);

        vm.prank(USER);
        fragBoxBetting.withdrawBetAmountsInRosterValidationFlight(MATCHID, WINNING_PLAYERID);

        // User gets full net amount back (fee was already taken — intended)
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER), balBefore - fragBoxBetting.calculateDepositFee(SEND_VALUE));
    }

    function test_Claim_LoserNoExcess_Reverts() public {
        uint256 balBefore = fragBoxBetting.getUsdc().balanceOf(USER);

        // Winner and loser deposit the same amount
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, LOSING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, LOSING_PLAYERID, USER, LOSING_FACTION);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER2);

        vm.prank(USER2);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER2, WINNING_FACTION);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Voting, FragBoxBetting.Faction.Unknown);

        vm.warp(block.timestamp + WARP_TIME);

        // Finish match with opposite faction as winner
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Finished, WINNING_FACTION);

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                FragBoxBetting.FragBoxBetting__LosingFactionCannotClaim.selector, FragBoxBetting.Faction.Faction2
            )
        );
        fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__InsufficientFundsForWithdrawal.selector);
        fragBoxBetting.withdraw(LOSING_PLAYERID);
        vm.stopPrank();

        // No funds should have moved to playerToWinnings
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER), balBefore - SEND_VALUE);
    }

    function test_Claim_AllPaths_CorrectPayoutAndDustToOwner() public {
        vm.startPrank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(LOSING_PLAYERID, USER2);

        uint256 startingOwnerFees = fragBoxBetting.getOwnerFeesCollected();
        uint256 userBal = fragBoxBetting.getUsdc().balanceOf(USER);
        uint256 user2Bal = fragBoxBetting.getUsdc().balanceOf(USER2);
        vm.stopPrank();

        // User bets heavy on winner, User2 bets light on loser
        uint256 bet1 = 10_000_000;
        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, bet1, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        uint256 bet2 = 5_000_000;
        vm.prank(USER2);
        fragBoxBetting.deposit(MATCHID, LOSING_PLAYERID, bet2, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, LOSING_PLAYERID, USER2, LOSING_FACTION);

        // Finish match — Faction1 wins
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Ready);

        vm.warp(block.timestamp + WARP_TIME);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Finished, WINNING_FACTION);

        // Claim
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        vm.startPrank(USER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                FragBoxBetting.FragBoxBetting__LosingFactionCannotClaim.selector, FragBoxBetting.Faction.Faction2
            )
        );
        fragBoxBetting.claim(MATCHID, LOSING_PLAYERID);
        vm.expectRevert(FragBoxBetting.FragBoxBetting__InsufficientFundsForWithdrawal.selector);
        fragBoxBetting.withdraw(LOSING_PLAYERID);
        vm.stopPrank();

        uint256 fee1 = fragBoxBetting.calculateDepositFee(bet1);
        uint256 fee2 = fragBoxBetting.calculateDepositFee(bet2);
        uint256 totalLosingBet = bet2 - fee2;
        uint256 totalWinningBet = bet1 - fee1;
        uint256 expectedWinnerPayout = totalLosingBet + totalWinningBet; // excess on winner side is refunded

        assertEq(fragBoxBetting.getUsdc().balanceOf(USER), userBal - bet1 + expectedWinnerPayout);
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER2), user2Bal - bet2); // loser gets nothing extra

        // Dust always goes to owner
        vm.startPrank(fragBoxBetting.owner());
        assertGt(fragBoxBetting.getOwnerFeesCollected(), startingOwnerFees);
        assertEq(fragBoxBetting.getUsdc().balanceOf(address(fragBoxBetting)), fragBoxBetting.getOwnerFeesCollected());
        vm.stopPrank();
    }

    function test_MultiplePlayersSameFaction_ProRataWorks() public {
        // Three winners with different bet sizes
        uint256 bal1 = fragBoxBetting.getUsdc().balanceOf(USER);
        uint256 bal2 = fragBoxBetting.getUsdc().balanceOf(USER2);
        uint256 bal3 = fragBoxBetting.getUsdc().balanceOf(USER3);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID, USER);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID2, USER2);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.registerPlayerWallet(WINNING_PLAYERID3, USER3);

        uint256 bet1 = 5_000_000; // $5
        uint256 bet2 = 7_000_000; // $7
        uint256 bet3 = 10_000_000; // $10

        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, bet1, DEFAULT_TIER_ID);
        
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        vm.prank(USER2);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID2, bet2, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID2, USER2, WINNING_FACTION);

        vm.prank(USER3);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID3, bet3, DEFAULT_TIER_ID);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID3, USER3, WINNING_FACTION);

        // Finish with Faction1 win (no loser bets)
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Ready);

        vm.warp(block.timestamp + WARP_TIME);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Finished, WINNING_FACTION);

        // Claim + withdraw each
        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        vm.startPrank(USER2);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID2);
        fragBoxBetting.withdraw(WINNING_PLAYERID2);
        vm.stopPrank();

        vm.startPrank(USER3);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID3);
        fragBoxBetting.withdraw(WINNING_PLAYERID3);
        vm.stopPrank();

        assertEq(fragBoxBetting.getUsdc().balanceOf(USER), bal1 - fragBoxBetting.calculateDepositFee(bet1));
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER2), bal2 - fragBoxBetting.calculateDepositFee(bet2));
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER3), bal3 - fragBoxBetting.calculateDepositFee(bet3));
    }

    function test_Draw_FullRefundToAll() public {
        // same setup as test_ClaimWithDrawWinnerRefundsAll but uses the already-existing test logic
        // (already in your file — this is just a duplicate for clarity with full assertions)
        uint256 balBefore = fragBoxBetting.getUsdc().balanceOf(USER);

        vm.prank(USER);
        fragBoxBetting.deposit(MATCHID, WINNING_PLAYERID, SEND_VALUE, DEFAULT_TIER_ID);

        vm.expectEmit(true, true, true, false);
        emit RosterUpdated(fragBoxBetting.getKey(MATCHID), MATCHID, fragBoxBetting.getKey(WINNING_PLAYERID), WINNING_PLAYERID, USER, WINNING_FACTION);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchRoster(MATCHID, WINNING_PLAYERID, USER, WINNING_FACTION);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Ready);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.updateMatchStatus(MATCHID, FragBoxBetting.MatchStatus.Finished, FragBoxBetting.Faction.Draw);

        vm.startPrank(USER);
        fragBoxBetting.claim(MATCHID, WINNING_PLAYERID);
        fragBoxBetting.withdraw(WINNING_PLAYERID);
        vm.stopPrank();

        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        assertEq(fragBoxBetting.getUsdc().balanceOf(USER), balBefore - fee);
    }

    /* -------------------------------------------------------------------------- */
    /*                                TEST GETTERS                                */
    /* -------------------------------------------------------------------------- */
    function testGetUsdc() public view {
        fragBoxBetting.getUsdc();
    }

    function testGetUsdcDecimals() public view {
        assertEq(fragBoxBetting.getUsdcDecimals(), 6);
    }

    function testGetKey() public view {
        fragBoxBetting.getKey(MATCHID);
    }

    function testGetMatchBet() public view {
        fragBoxBetting.getMatchBet(fragBoxBetting.getKey(MATCHID));
    }

    function testGetPlayerFaction() public view {
        fragBoxBetting.getPlayerFaction(fragBoxBetting.getKey(MATCHID), fragBoxBetting.getKey(WINNING_PLAYERID));
    }

    function testGetOwnerFees() public {
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.getOwnerFeesCollected();

        vm.expectRevert();
        vm.prank(USER);
        fragBoxBetting.getOwnerFeesCollected();
    }

    function testCalculateDepositFee() public {
        uint256 fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        assertEq(SEND_VALUE - fee, SEND_VALUE - (SEND_VALUE * fragBoxBetting.getHouseFeePercentage()) / 100);

        vm.expectEmit(false, false, false, true);
        emit HouseFeePercentageUpdated(fragBoxBetting.getHouseFeePercentage(), 5);
        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.setHouseFeePercentage(5);

        fee = fragBoxBetting.calculateDepositFee(SEND_VALUE);
        assertEq(SEND_VALUE - fee, SEND_VALUE - (SEND_VALUE * 5) / 100);
    }

    function testGetAndSetTier() public {
        FragBoxBetting.Tier memory tier1 = fragBoxBetting.getTier(1);
        assertEq(tier1.active, true);
        assertEq(tier1.minBetAmount, fragBoxBetting.toUsdc(5));
        assertEq(tier1.maxBetAmount, fragBoxBetting.toUsdc(10));

        FragBoxBetting.Tier memory tier2 = fragBoxBetting.getTier(2);
        assertEq(tier2.active, true);
        assertEq(tier2.minBetAmount, fragBoxBetting.toUsdc(10));
        assertEq(tier2.maxBetAmount, fragBoxBetting.toUsdc(20));

        FragBoxBetting.Tier memory tier3 = fragBoxBetting.getTier(3);
        assertEq(tier3.active, true);
        assertEq(tier3.minBetAmount, fragBoxBetting.toUsdc(50));
        assertEq(tier3.maxBetAmount, fragBoxBetting.toUsdc(100));

        vm.prank(fragBoxBetting.owner());
        vm.expectRevert(FragBoxBetting.FragBoxBetting__MinBetMustBeGreaterThanMaxBet.selector);
        fragBoxBetting.setTier(1, 10, 5);

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.setTier(1, 10, 50);

        tier1 = fragBoxBetting.getTier(1);
        assertEq(tier1.active, true);
        assertEq(tier1.minBetAmount, fragBoxBetting.toUsdc(10));
        assertEq(tier1.maxBetAmount, fragBoxBetting.toUsdc(50));

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.setTier(4, 100, 5000);

        FragBoxBetting.Tier memory tier4 = fragBoxBetting.getTier(4);
        assertEq(tier4.active, true);
        assertEq(tier4.minBetAmount, fragBoxBetting.toUsdc(100));
        assertEq(tier4.maxBetAmount, fragBoxBetting.toUsdc(5000));
    }

    function testGetPaused() public {
        assertFalse(fragBoxBetting.paused());

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.pause();

        assertTrue(fragBoxBetting.paused());

        vm.prank(fragBoxBetting.owner());
        fragBoxBetting.unpause();

        assertFalse(fragBoxBetting.paused());
    }
}
