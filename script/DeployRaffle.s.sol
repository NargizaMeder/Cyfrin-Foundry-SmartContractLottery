// SPDX- License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {Raffle} from "../src/Raffle.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {console} from "forge-std/console.sol";
import {CreateSubscription, FundSubscription, AddConsumer} from "script/Interactions.s.sol";
import {VRFCoordinatorV2PlusMock} from "../test/mocks/VRFCoordinatorV2PlusMock.sol";

contract DeployRaffle is Script {
    function run() public {
        (Raffle raffle, HelperConfig helperConfig) = deployContract();
        console.log("Raffle deployed at:", address(raffle));
        // Optionally log other details, e.g., subscriptionId
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        console.log("Subscription ID:", config.subscriptionId);
    }

    function deployContract() public returns (Raffle, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        if (config.subscriptionId == 0) {
            vm.startBroadcast();
            // Create subscription directly in broadcast context so deployer is the owner
            config.subscriptionId = VRFCoordinatorV2PlusMock(config.vrfCoordinator).createSubscription();
            console.log("Created subscription ID:", config.subscriptionId);

            // Fund the subscription
            VRFCoordinatorV2PlusMock(config.vrfCoordinator)
                .fundSubscription(config.subscriptionId, uint96(3 ether * 100));
            console.log("Funded subscription");
            vm.stopBroadcast();
        }

        vm.startBroadcast();
        Raffle raffle = new Raffle(
            config.entranceFee,
            config.interval,
            config.vrfCoordinator,
            config.gasLane,
            config.subscriptionId,
            config.callbackGasLimit
        );

        // Add consumer to subscription while still in broadcast context
        VRFCoordinatorV2PlusMock(config.vrfCoordinator).addConsumer(config.subscriptionId, address(raffle));
        vm.stopBroadcast();

        return (raffle, helperConfig);
    }
}
