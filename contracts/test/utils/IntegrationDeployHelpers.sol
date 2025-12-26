// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {DeployFeeModule} from "../../script/for-tests/DeployFeeModule.s.sol";
import {DeploySettlement} from "../../script/for-tests/DeploySettlement.s.sol";
import {DeployRegistry} from "../../script/for-tests/DeployRegistry.s.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {FeeModule} from "../../src/FeeModule.sol";
import {Settlement} from "../../src/Settlement.sol";
import {WhitelistRegistry} from "../../src/WhitelistRegistry.sol";

abstract contract IntegrationDeployHelpers is Test {
    DeployRegistry internal _registryDeployer;
    WhitelistRegistry internal registry;

    DeployFeeModule internal _feeDeployer;
    FeeModule internal feeModule;

    DeploySettlement internal _settlementDeployer;
    Settlement internal settlement;

    ERC20Mock mockToken;

    address internal user;
    uint256 internal userPrivKey;

    address internal user2;
    uint256 internal user2PrivKey;

    function _initUser() internal {
        (user, userPrivKey) = makeAddrAndKey("user");
    }

    function _initUser2() internal {
        (user2, user2PrivKey) = makeAddrAndKey("user2");
    }

    function _initFeeModule() internal {
        _feeDeployer = new DeployFeeModule();
        feeModule = _feeDeployer.run();
    }

    function _initRegistry() internal {
        _registryDeployer = new DeployRegistry();
        registry = _registryDeployer.run();
    }

    function _initSettlement() internal {
        _settlementDeployer = new DeploySettlement();
        settlement = _settlementDeployer.run();
    }

    function _initToken() internal {
        mockToken = new ERC20Mock();
    }
}
