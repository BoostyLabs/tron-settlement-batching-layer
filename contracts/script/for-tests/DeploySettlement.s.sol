// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {Settlement} from "../../src/Settlement.sol";

contract DeploySettlement is Script {
    function run() public returns (Settlement) {
        vm.startBroadcast();
        Settlement settlement = new Settlement();
        vm.stopBroadcast();

        return settlement;
    }
}
