pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";

contract Deploy is Script {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external returns (MilestoneEscrow escrow) {
        vm.startBroadcast();
        escrow = new MilestoneEscrow(ARC_USDC);
        vm.stopBroadcast();
    }
}
