// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {TestConstants as TC} from "../utils/TestConstants.sol";

import {FeeModule} from "../../src/FeeModule.sol";
import {IFeeModule} from "../../src/interfaces/IFeeModule.sol";

import {Types} from "../../src/libraries/Types.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract FeeModuleUnitTest is Test {
    FeeModule feeModule;
    address settlementAddr;
    address user;
    address owner;

    function setUp() public {
        owner = makeAddr("owner");

        vm.prank(owner);
        feeModule = new FeeModule();
        settlementAddr = makeAddr("settlement");
        user = makeAddr("user");

        vm.prank(owner);
        feeModule.setSettlement(settlementAddr);
    }

    /* -------------------------------------------------------------------------- */
    /*                           INITIAL STATE                                    */
    /* -------------------------------------------------------------------------- */

    function test_Constructor_InitialValues() public view {
        assertEq(feeModule.owner(), owner);
        assertEq(feeModule.getSettlement(), settlementAddr);
    }

    /* -------------------------------------------------------------------------- */
    /*                              calculateFee                                  */
    /* -------------------------------------------------------------------------- */

    function test_CalculateFee_InvalidInput_Reverts() public {
        // sender
        vm.expectRevert(Errors.FeeModule__InvalidInput.selector);
        feeModule.calculateFee(address(0), Types.TxType.INSTANT, TC.VOLUME, 1);

        // volume
        vm.expectRevert(Errors.FeeModule__InvalidInput.selector);
        feeModule.calculateFee(user, Types.TxType.INSTANT, 0, 1);

        // recipient count
        vm.expectRevert(Errors.FeeModule__InvalidInput.selector);
        feeModule.calculateFee(user, Types.TxType.INSTANT, TC.VOLUME, 0);

        // recipient count
        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        feeModule.calculateFee(user, Types.TxType.INSTANT, TC.VOLUME, 3);

        // recipient count
        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        feeModule.calculateFee(user, Types.TxType.BATCHED, TC.VOLUME, 1);

        vm.expectRevert(Errors.FeeModule__InvalidInput.selector);
        feeModule.calculateFee(address(0), Types.TxType.FREE_TIER, 0, 0);
    }

    function test_CalculateFee_InstantFee() public view {
        Types.FeeInfo memory info = feeModule.calculateFee(user, Types.TxType.INSTANT, TC.VOLUME, 1);
        assertEq(info.fee, TC.INSTANT_FEE);
        assertEq(uint256(info.txType), uint256(Types.TxType.INSTANT));
    }

    function test_CalculateFee_BatchedFee() public view {
        uint256 recipientCount = 3;
        Types.FeeInfo memory info = feeModule.calculateFee(user, Types.TxType.BATCHED, TC.VOLUME, recipientCount);
        assertEq(info.fee, TC.BATCH_FEE * recipientCount);
        assertEq(uint256(info.txType), uint256(Types.TxType.BATCHED));
    }

    function test_CalculateFee_LargeVolumeNoFee() public view {
        Types.FeeInfo memory info = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.LARGE_VOLUME, 1);
        assertEq(info.fee, 0);
        assertEq(uint256(info.txType), uint256(Types.TxType.DELAYED));
    }

    function test_CalculateFee_ReturnsCorrectFee() public view {
        Types.FeeInfo memory info = feeModule.calculateFee(user, Types.TxType.INSTANT, TC.VOLUME, 1);

        assertEq(info.fee, TC.INSTANT_FEE);
        assertEq(uint256(info.txType), uint256(Types.TxType.INSTANT));
    }

    function test_CalculateFee_FreeTier_NoStateChanges() public view {
        Types.FeeInfo memory info = feeModule.calculateFee(user, Types.TxType.FREE_TIER, TC.VOLUME, 1);

        assertEq(info.fee, 0);
        assertEq(uint256(info.txType), uint256(Types.TxType.FREE_TIER));
    }

    /* -------------------------------------------------------------------------- */
    /*                              applyFee                                      */
    /* -------------------------------------------------------------------------- */

    function test_ApplyFee_InvalidInput() public {
        uint256 feeAmount = 100;
        // sender
        vm.expectRevert(Errors.FeeModule__InvalidInput.selector);
        feeModule.applyFee(address(0), feeAmount, keccak256(abi.encodePacked("1")), 1, Types.TxType.DELAYED);

        // transferHash
        vm.expectRevert(Errors.FeeModule__InvalidInput.selector);
        feeModule.applyFee(user, feeAmount, bytes32(0), 1, Types.TxType.DELAYED);

        // batch id
        vm.expectRevert(Errors.FeeModule__InvalidInput.selector);
        feeModule.applyFee(user, feeAmount, keccak256(abi.encodePacked("1")), 0, Types.TxType.DELAYED);
    }

    function test_ApplyFee_NotSettlement_Reverts() public {
        vm.expectRevert(Errors.FeeModule__NotAuthorized.selector);
        feeModule.applyFee(user, 1, keccak256(abi.encodePacked("1")), 1, Types.TxType.DELAYED);
    }

    function test_ApplyFee_ZeroFeeSucceeds() public {
        uint256 feeAmount = 0;
        vm.prank(settlementAddr);
        feeModule.applyFee(user, feeAmount, keccak256(abi.encodePacked("1")), 1, Types.TxType.DELAYED);
    }

    function test_ApplyFee_Succeeds() public {
        uint256 feeAmount = 200_000;
        bytes32 transferHash = keccak256(abi.encodePacked("tx1"));
        uint64 batchId = 1;

        // set transfer fee first
        vm.prank(settlementAddr);
        vm.expectEmit(true, false, false, true);
        emit IFeeModule.FeeApplied(user, feeAmount, transferHash, batchId);
        feeModule.applyFee(user, feeAmount, transferHash, batchId, Types.TxType.INSTANT);

        // verify totalFees and batchTotalFees updated
        uint256 totalFees = feeModule.getTotalFeesCollected();
        assertEq(totalFees, feeAmount);

        uint256 batchFees = feeModule.getBatchTotalFees(batchId);
        assertEq(batchFees, feeAmount);
    }

    function test_ApplyFee_FreeTier_ConsumesQuota() public {
        uint256 feeAmount = 0;
        bytes32 transferHash = keccak256(abi.encodePacked("txFreeTier"));
        uint64 batchId = 3;

        uint256 initialQuota = feeModule.getRemainingFreeTierTransactions(user);

        vm.prank(settlementAddr);
        vm.expectEmit(true, false, false, true);
        emit IFeeModule.FreeTierUsed(user, initialQuota - 1);
        feeModule.applyFee(user, feeAmount, transferHash, batchId, Types.TxType.FREE_TIER);

        uint256 finalQuota = feeModule.getRemainingFreeTierTransactions(user);
        assertEq(finalQuota, initialQuota - 1);
    }

    /* -------------------------------------------------------------------------- */
    /*                              setSettlement                                 */
    /* -------------------------------------------------------------------------- */

    function test_SetSettlement_InvalidInput() public {
        vm.prank(owner);
        vm.expectRevert(Errors.FeeModule__InvalidInput.selector);
        feeModule.setSettlement(address(0));
    }

    function test_SetSettlement_AlreadySettlement() public {
        vm.prank(owner);
        vm.expectRevert(Errors.FeeModule__AlreadySettlement.selector);
        feeModule.setSettlement(settlementAddr);
    }

    function test_SetSettlement_SetsAndEmits() public {
        address newSettlement = makeAddr("newSettlement");
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IFeeModule.SettlementUpdated(newSettlement);
        feeModule.setSettlement(newSettlement);

        assertEq(feeModule.getSettlement(), newSettlement);
    }

    /* -------------------------------------------------------------------------- */
    /*                                 GETTERS                                    */
    /* -------------------------------------------------------------------------- */

    function test_Getters() public {
        assertEq(feeModule.getSettlement(), settlementAddr);

        assertEq(feeModule.getOwner(), owner);

        assertEq(feeModule.getFreeTxUsage(user).count, 0);
        assertEq(feeModule.getFreeTxUsage(user).day, 0);

        assertEq(feeModule.getRemainingFreeTierTransactions(user), 10);

        uint256 feeAmount = 200_000;
        bytes32 transferHash = keccak256(abi.encodePacked("tx2"));
        uint64 batchId = 2;
        vm.prank(settlementAddr);
        feeModule.applyFee(user, feeAmount, transferHash, batchId, Types.TxType.INSTANT);

        uint256 fee = feeModule.getFeeOfTransaction(transferHash);
        assertEq(fee, feeAmount);

        assertEq(feeModule.getTotalFeesCollected(), feeAmount);
        assertEq(feeModule.getBatchTotalFees(batchId), feeAmount);
    }
}
