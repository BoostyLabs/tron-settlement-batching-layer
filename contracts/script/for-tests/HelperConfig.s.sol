// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address updater;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 2494104990) {
            activeNetworkConfig = getShastaTestnetConfig();
        } else if (block.chainid == 728126428) {
            activeNetworkConfig = getTronMainnetConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getShastaTestnetConfig() public pure returns (NetworkConfig memory) {
        // change address
        address updater = address(1);
        return NetworkConfig({updater: updater});
    }

    function getTronMainnetConfig() public pure returns (NetworkConfig memory) {
        // change address
        address updater = address(1);
        return NetworkConfig({updater: updater});
    }

    function getOrCreateAnvilEthConfig() public pure returns (NetworkConfig memory) {
        // default anvil address
        address updater = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        return NetworkConfig({updater: updater});
    }

    function getActiveNetworkConfig() public view returns (address) {
        return (activeNetworkConfig.updater);
    }
}
