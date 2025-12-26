// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {FeeModule} from "../../src/FeeModule.sol";

contract DeployFeeModule is Script {
    function run() public returns (FeeModule) {
        vm.startBroadcast();
        FeeModule feeModule = new FeeModule();
        vm.stopBroadcast();
        return feeModule;
    }
}
