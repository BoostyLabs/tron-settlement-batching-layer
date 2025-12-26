// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {WhitelistRegistry} from "../../src/WhitelistRegistry.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployRegistry is Script {
    function run() public returns (WhitelistRegistry) {
        HelperConfig helperConfig = new HelperConfig();

        vm.startBroadcast();
        address updater = helperConfig.getActiveNetworkConfig();
        WhitelistRegistry registry = new WhitelistRegistry(updater);
        vm.stopBroadcast();

        return registry;
    }
}
