// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeployRaffle} from "script/DeployRaffle.s.sol";
import {Raffle} from "src/Raffle.sol";
import {HelperConfig, CodeConstants} from "script/HelperConfig.s.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {LinkToken} from "test/mocks/LinkToken.sol";
import {CreateSubscription, FundSubscription, AddConsumer} from "script/Interactions.s.sol";

contract RaffleIntegrationTest is Test, CodeConstants {
    Raffle public raffle;
    HelperConfig public helperConfig;
    VRFCoordinatorV2_5Mock public vrfCoordinatorMock;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_BALANCE = 10 ether;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint256 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    event RaffleEntered(address indexed player);
    event RequestedRaffleWinner(uint256 indexed requestId);
    event WinnerPicked(address indexed winner);

    modifier raffleEntered() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != LOCAL_CHAIN_ID) {
            return;
        }
        _;
    }

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.deployContract();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        entranceFee = config.entranceFee;
        interval = config.interval;
        vrfCoordinator = config.vrfCoordinator;
        gasLane = config.gasLane;
        subscriptionId = config.subscriptionId;
        callbackGasLimit = config.callbackGasLimit;
        link = config.link;
        if (block.chainid == LOCAL_CHAIN_ID) {
            vrfCoordinatorMock = VRFCoordinatorV2_5Mock(vrfCoordinator);
        }
        vm.deal(PLAYER, STARTING_BALANCE);
    }

    // Integration Test 4: High player volume stress test on local chain
    // Integration Test 4: High player volume stress test on local chain
    function testHighPlayerVolume() public skipFork {
        // Arrange
        uint256 numberOfPlayers = 1000;
        address[] memory players = new address[](numberOfPlayers);
        for (uint256 i = 0; i < numberOfPlayers; i++) {
            players[i] = address(uint160(i + 1));
            vm.deal(players[i], STARTING_BALANCE);
            vm.prank(players[i]);
            raffle.enterRaffle{value: entranceFee}();
        }
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        // Calculate expected prize
        uint256 expectedPrize = entranceFee * numberOfPlayers;

        // Record starting balance of all players to find the winner's initial balance later
        uint256[] memory startingBalances = new uint256[](numberOfPlayers);
        for (uint256 i = 0; i < numberOfPlayers; i++) {
            startingBalances[i] = players[i].balance;
        }

        // Act: Complete raffle
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        vrfCoordinatorMock.fulfillRandomWords(uint256(requestId), address(raffle));

        // Assert: Winner picked and funds distributed correctly
        address winner = raffle.getRecentWinner();
        bool isWinnerInPlayers = false;
        uint256 winnerIndex = 0;

        // Find the winner in the players array and their starting balance
        for (uint256 i = 0; i < numberOfPlayers; i++) {
            if (players[i] == winner) {
                isWinnerInPlayers = true;
                winnerIndex = i;
                break;
            }
        }

        assert(isWinnerInPlayers); // Ensure winner is one of the players
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN); // State reset
        assert(raffle.getNumberOfPlayers() == 0); // Players array cleared

        // Verify winner received the correct amount
        uint256 winnerStartingBalance = startingBalances[winnerIndex];
        uint256 winnerEndingBalance = winner.balance;
        assert(winnerEndingBalance == winnerStartingBalance + expectedPrize);
    }
}
