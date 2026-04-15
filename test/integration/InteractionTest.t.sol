// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../../src/Raffle.sol";
import {CodeConstants} from "script/HelperConfig.s.sol";
import {LinkToken} from "test/mocks/LinkToken.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2PlusMock} from "chainlink/src/v0.8/vrf/mocks/VRFCoordinatorV2PlusMock.sol";

/**
 * @title InteractionTest
 * @notice Integration tests for Raffle contract interactions
 * Tests multi-step flows and component integration rather than unit functionality
 */
contract InteractionTest is Test, CodeConstants {
    Raffle public raffle;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint256 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER_ONE = makeAddr("playerOne");
    address public PLAYER_TWO = makeAddr("playerTwo");
    address public PLAYER_THREE = makeAddr("playerThree");
    uint256 public constant STARTING_PLAYER_BALANCE = 10 ether;

    VRFCoordinatorV2PlusMock vrfCoordinatorMock;

    event EnteredRaffle(address indexed player);
    event PickedWinner(address indexed winner);
    event RequestedRaffleWinner(uint256 indexed requestId);

    function setUp() external {
        entranceFee = 0.01 ether;
        interval = 30;
        gasLane = bytes32(0);
        callbackGasLimit = 500000;

        vrfCoordinatorMock = new VRFCoordinatorV2PlusMock(MOCK_BASE_FEE, MOCK_GAS_PRICE_LINK);
        link = address(new LinkToken());
        vrfCoordinator = address(vrfCoordinatorMock);

        subscriptionId = vrfCoordinatorMock.createSubscription();
        vrfCoordinatorMock.fundSubscription(subscriptionId, uint96(3 ether));
        raffle = new Raffle(entranceFee, interval, vrfCoordinator, gasLane, subscriptionId, callbackGasLimit);
        vrfCoordinatorMock.addConsumer(subscriptionId, address(raffle));

        vm.deal(PLAYER_ONE, STARTING_PLAYER_BALANCE);
        vm.deal(PLAYER_TWO, STARTING_PLAYER_BALANCE);
        vm.deal(PLAYER_THREE, STARTING_PLAYER_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-PLAYER INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test the complete raffle flow with multiple players
     * This tests integration: entry → upkeep check → winner selection → payout
     */
    function testCompleteRaffleFlowWithMultiplePlayers() public {
        // Step 1: Multiple players enter raffle
        vm.prank(PLAYER_ONE);
        raffle.enterRaffle{value: entranceFee}();

        vm.prank(PLAYER_TWO);
        raffle.enterRaffle{value: entranceFee}();

        vm.prank(PLAYER_THREE);
        raffle.enterRaffle{value: entranceFee}();

        // Verify all players are recorded
        assert(raffle.getNumberOfPlayers() == 3);

        // Step 2: Wait for upkeep to be needed
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        // Step 3: Check that upkeep is needed
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(upkeepNeeded);

        // Step 4: Perform upkeep (request random words)
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        // Verify raffle state changed to CALCULATING
        assert(uint256(raffle.getRaffleState()) == 1); // CALCULATING

        // Step 5: Simulate VRF response (fulfillRandomWords)
        VRFCoordinatorV2PlusMock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        // Step 6: Verify final state
        // - Winner should be one of the three players
        address winner = raffle.getRecentWinner();
        assert(winner == PLAYER_ONE || winner == PLAYER_TWO || winner == PLAYER_THREE);

        // - Raffle should be back to OPEN
        assert(uint256(raffle.getRaffleState()) == 0);

        // - All entry fees should be transferred to winner
        uint256 expectedPrize = entranceFee * 3;
        assert(winner.balance == STARTING_PLAYER_BALANCE + expectedPrize - entranceFee);

        // - Players array should be reset
        assert(raffle.getNumberOfPlayers() == 0);
    }

    /**
     * @notice Test that raffle resets properly between rounds
     * Tests state reset and ability to start a new raffle immediately
     */
    function testRaffleProperlyResetsForNextRound() public {
        // First round
        vm.prank(PLAYER_ONE);
        raffle.enterRaffle{value: entranceFee}();

        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        VRFCoordinatorV2PlusMock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        address firstWinner = raffle.getRecentWinner();
        uint256 firstWinnerTimestamp = raffle.getLastTimeStamp();

        // Second round - new players can immediately enter
        vm.prank(PLAYER_TWO);
        raffle.enterRaffle{value: entranceFee}();

        vm.prank(PLAYER_THREE);
        raffle.enterRaffle{value: entranceFee}();

        assert(raffle.getNumberOfPlayers() == 2);
        assert(uint256(raffle.getRaffleState()) == 0); // OPEN

        // Complete second round
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries2 = vm.getRecordedLogs();
        bytes32 requestId2 = entries2[1].topics[1];

        VRFCoordinatorV2PlusMock(vrfCoordinator).fulfillRandomWords(uint256(requestId2), address(raffle));

        address secondWinner = raffle.getRecentWinner();

        // Verify state was properly reset
        assert(raffle.getNumberOfPlayers() == 0);
        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getLastTimeStamp() > firstWinnerTimestamp);
        // Winners could be the same or different (randomness)
        assert(secondWinner != address(0));
    }

    /*//////////////////////////////////////////////////////////////
               TIMING & STATE TRANSITION INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that checkUpkeep properly evaluates all conditions together
     * This tests how multiple conditions interact (time, players, balance, state)
     */
    function testCheckUpkeepIntegrationWithAllConditions() public {
        // Initially: no players, no balance, not enough time = upkeep NOT needed
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);

        // Add player but time not passed = upkeep NOT needed
        vm.prank(PLAYER_ONE);
        raffle.enterRaffle{value: entranceFee}();
        (upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);

        // Enough time passed, player exists, balance exists = upkeep NEEDED
        vm.warp(block.timestamp + interval + 1);
        (upkeepNeeded,) = raffle.checkUpkeep("");
        assert(upkeepNeeded);

        // Perform upkeep (state changes to CALCULATING)
        raffle.performUpkeep("");
        (upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded); // State is CALCULATING, so upkeep NOT needed
    }

    /**
     * @notice Test VRF request lifecycle - from request to fulfillment
     * Verifies that random word properly selects a winner from players list
     */
    function testVRFRequestLifecycle() public {
        // Setup: Add multiple players
        vm.prank(PLAYER_ONE);
        raffle.enterRaffle{value: entranceFee}();
        vm.prank(PLAYER_TWO);
        raffle.enterRaffle{value: entranceFee}();
        vm.prank(PLAYER_THREE);
        raffle.enterRaffle{value: entranceFee}();

        vm.warp(block.timestamp + interval + 1);

        // Request random words
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Extract request ID from event logs
        bytes32 requestIdBytes = entries[1].topics[1];
        uint256 requestId = uint256(requestIdBytes);

        // Verify request ID is valid (non-zero)
        assert(requestId > 0);

        // Fulfill the request with random words
        VRFCoordinatorV2PlusMock(vrfCoordinator).fulfillRandomWords(requestId, address(raffle));

        // Verify winner is valid
        address winner = raffle.getRecentWinner();
        assert(winner != address(0));
        assert(
            winner == PLAYER_ONE || winner == PLAYER_TWO || winner == PLAYER_THREE
        );
    }

    /*//////////////////////////////////////////////////////////////
                     FUND & BALANCE INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that all funds are properly collected and distributed
     */
    function testFundsCollectionAndDistribution() public {
        uint256 raffleStartingBalance = address(raffle).balance;
        assert(raffleStartingBalance == 0);

        // Collect funds from players
        vm.prank(PLAYER_ONE);
        raffle.enterRaffle{value: entranceFee}();
        vm.prank(PLAYER_TWO);
        raffle.enterRaffle{value: entranceFee}();

        uint256 totalCollected = entranceFee * 2;
        assert(address(raffle).balance == totalCollected);

        // Complete raffle
        vm.warp(block.timestamp + interval + 1);
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        VRFCoordinatorV2PlusMock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        // Verify all funds transferred to winner
        assert(address(raffle).balance == 0);
        address actualWinner = raffle.getRecentWinner();
        
        // Winner should have received all entry fees minus their own entry fee
        uint256 expectedWinnerBalance = STARTING_PLAYER_BALANCE + (totalCollected - entranceFee);
        assert(actualWinner.balance == expectedWinnerBalance);
    }

    /*//////////////////////////////////////////////////////////////
              STATE CONSISTENCY INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that contract state remains consistent throughout operations
     */
    function testStateConsistencyThroughRaffleRound() public {
        // Initial state
        assert(uint256(raffle.getRaffleState()) == 0); // OPEN
        assert(raffle.getNumberOfPlayers() == 0);

        // After entry
        vm.prank(PLAYER_ONE);
        raffle.enterRaffle{value: entranceFee}();
        uint256 timestampAfterEntry = raffle.getLastTimeStamp();
        assert(uint256(raffle.getRaffleState()) == 0); // Still OPEN

        // After upkeep request
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        vm.recordLogs();
        raffle.performUpkeep("");
        assert(uint256(raffle.getRaffleState()) == 1); // Now CALCULATING
        assert(raffle.getNumberOfPlayers() == 1); // Players not reset yet
        
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        // After fulfillment
        VRFCoordinatorV2PlusMock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        // Final state after winner selection
        assert(uint256(raffle.getRaffleState()) == 0); // Back to OPEN
        assert(raffle.getNumberOfPlayers() == 0); // Players reset
        assert(raffle.getLastTimeStamp() > timestampAfterEntry); // Timestamp updated
    }
}
