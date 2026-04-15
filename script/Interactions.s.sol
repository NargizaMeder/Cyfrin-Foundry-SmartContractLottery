// SPDX- License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig, CodeConstants} from "script/HelperConfig.s.sol";
import {LinkToken} from "test/mocks/LinkToken.sol";
import {Raffle} from "../src/Raffle.sol";
import {DevOpsTools} from "lib/foundry-devops/src/DevOpsTools.sol";
import {VRFCoordinatorV2PlusMock} from "../test/mocks/VRFCoordinatorV2PlusMock.sol";

contract CreateSubscription is Script, CodeConstants {
    function createSubscriptionUsingConfig() public returns (uint256, address) {
        HelperConfig helperConfig = new HelperConfig();
        address vrfCoordinator = helperConfig.getConfig().vrfCoordinator;
        uint256 deployerKey = helperConfig.getConfig().deployerKey;
        return createSubscription(vrfCoordinator, deployerKey);
    }

    function createSubscription(address vrfCoordinator, uint256 deployerKey) public returns (uint256, address) {
        console.log("Creating subscription on chain Id: ", block.chainid);
        // No broadcast here - caller manages context
        uint256 subId = VRFCoordinatorV2PlusMock(vrfCoordinator).createSubscription();
        return (subId, vrfCoordinator);
    }

    function run() public returns (uint256, address) {
        HelperConfig helperConfig = new HelperConfig();
        uint256 deployerKey = helperConfig.getConfig().deployerKey;
        vm.startBroadcast(deployerKey); // broadcast only in run()
        (uint256 subId, address vrfCoordinator) = createSubscriptionUsingConfig();
        vm.stopBroadcast();
        return (subId, vrfCoordinator);
    }
}

contract FundSubscription is Script, CodeConstants {
    uint256 public constant FUND_AMOUNT = 3 ether;

    function fundSubscription(address vrfCoordinator, uint256 subscriptionId, address linkToken, uint256 deployerKey)
        public
    {
        console.log("Funding subscription: ", subscriptionId);
        if (block.chainid == LOCAL_CHAIN_ID) {
            // No broadcast here
            VRFCoordinatorV2PlusMock(vrfCoordinator).fundSubscription(subscriptionId, uint96(FUND_AMOUNT * 100));
        } else {
            //vm.startBroadcast(deployerKey);
            LinkToken(linkToken).transferAndCall(vrfCoordinator, FUND_AMOUNT, abi.encode(subscriptionId));
            //vm.stopBroadcast();
        }
    }

    function run() public {
        HelperConfig helperConfig = new HelperConfig();
        address vrfCoordinator = helperConfig.getConfig().vrfCoordinator;
        uint256 subscriptionId = helperConfig.getConfig().subscriptionId;
        address linkToken = helperConfig.getConfig().link;
        uint256 deployerKey = helperConfig.getConfig().deployerKey;
        fundSubscription(vrfCoordinator, subscriptionId, linkToken, deployerKey);
    }
}

contract AddConsumer is Script {
    function addConsumer(address contractToAddToVrf, address vrfCoordinator, uint256 subId) public {
        console.log("Adding consumer contract: ", contractToAddToVrf);
        VRFCoordinatorV2PlusMock(vrfCoordinator).addConsumer(subId, contractToAddToVrf);
    }

    function run() external {
        address mostRecentlyDeployed = DevOpsTools.get_most_recent_deployment("Raffle", block.chainid);
        HelperConfig helperConfig = new HelperConfig();
        address vrfCoordinator = helperConfig.getConfig().vrfCoordinator;
        uint256 subId = helperConfig.getConfig().subscriptionId;
        uint256 deployerKey = helperConfig.getConfig().deployerKey;
        vm.startBroadcast(deployerKey); // broadcast as the deployer private key
        addConsumer(mostRecentlyDeployed, vrfCoordinator, subId);
        vm.stopBroadcast();
    }
}
