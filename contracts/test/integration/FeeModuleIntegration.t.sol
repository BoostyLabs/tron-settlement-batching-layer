// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {IntegrationDeployHelpers} from "../utils/IntegrationDeployHelpers.sol";
import {TestConstants as TC} from "../utils/TestConstants.sol";

import {Types} from "../../src/libraries/Types.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract FeeModuleIntegrationTest is Test, IntegrationDeployHelpers {
    // DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    function setUp() public {
        _initUser();
        _initUser2();
        _initFeeModule();
        _initSettlement();

        vm.prank(DEFAULT_SENDER);
        feeModule.setSettlement(address(settlement));
    }

    /* -------------------------------------------------------------------------- */
    /*                           INITIAL STATE                                    */
    /* -------------------------------------------------------------------------- */

    function test_Constructor_InitialValues() public view {
        assertNotEq(feeModule.getSettlement(), address(0));
        assertEq(feeModule.getSettlement(), address(settlement));
        assertEq(address(feeModule.owner()), DEFAULT_SENDER);
    }

    /* -------------------------------------------------------------------------- */
    /*                           CALCULATIONS                                     */
    /* -------------------------------------------------------------------------- */

    function test_CalculateFee_FreeQuota_NoChanges() public view {
        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
        assertEq(feeInfo.fee, 0);
        assertEq(uint256(feeInfo.txType), uint256(Types.TxType.FREE_TIER));
        assertEq(feeInfo.freeQuota, TC.FREE_TX_AMOUNT);

        for (uint256 i = 0; i < TC.FREE_TX_AMOUNT; i++) {
            feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
            assertEq(feeInfo.fee, 0);
            assertEq(uint256(feeInfo.txType), uint256(Types.TxType.FREE_TIER));
            assertEq(feeInfo.freeQuota, TC.FREE_TX_AMOUNT);
        }
    }

    function test__CalculateFee_Batched_MultipleRecipients() public view {
        uint256 recipients = 5;
        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.BATCHED, TC.VOLUME, recipients);
        assertEq(feeInfo.fee, TC.BATCH_FEE * recipients);
        assertEq(uint256(feeInfo.txType), uint256(Types.TxType.BATCHED));
    }

    function test__CalculateFee_Instant() public view {
        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.INSTANT, TC.VOLUME, 1);
        assertEq(feeInfo.fee, TC.INSTANT_FEE);
        assertEq(uint256(feeInfo.txType), uint256(Types.TxType.INSTANT));
    }

    function test_CalculateFee_FreeTier_ResetsNextDay() public {
        for (uint256 i = 0; i < TC.FREE_TX_AMOUNT; i++) {
            feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
            vm.prank(address(settlement));
            feeModule.applyFee(user, 0, keccak256(abi.encodePacked(i)), 1, Types.TxType.FREE_TIER);
        }

        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
        assertEq(feeInfo.fee, TC.BASE_FEE);

        vm.warp(block.timestamp + 1 days);

        feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
        assertEq(feeInfo.fee, 0);
        assertEq(feeInfo.freeQuota, TC.FREE_TX_AMOUNT);
    }

    function test_CalculateFee_LargeVolume() public view {
        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.LARGE_VOLUME, 1);
        assertEq(feeInfo.fee, 0);
        assertEq(uint256(feeInfo.txType), uint256(Types.TxType.DELAYED));
        assertEq(feeInfo.freeQuota, TC.FREE_TX_AMOUNT);

        feeInfo = feeModule.calculateFee(user, Types.TxType.INSTANT, TC.LARGE_VOLUME, 1);
        assertEq(feeInfo.fee, 0);

        feeInfo = feeModule.calculateFee(user, Types.TxType.BATCHED, TC.LARGE_VOLUME, 2);
        assertEq(feeInfo.fee, 0);
    }

    function test_CalculateFee_BatchedWithOneRecipient() public {
        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        feeModule.calculateFee(user, Types.TxType.BATCHED, TC.VOLUME, 1);
    }

    function test__CalculateFee_NonBatched_MultipleRecipients_Reverts() public {
        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 5);

        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        feeModule.calculateFee(user, Types.TxType.INSTANT, TC.VOLUME, 3);

        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        feeModule.calculateFee(user, Types.TxType.FREE_TIER, TC.VOLUME, 2);
    }

    function test__CalculateFee_Batched_SingleRecipient_Reverts() public {
        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        feeModule.calculateFee(user, Types.TxType.BATCHED, TC.VOLUME, 1);
    }

    function test__CalculateFee_Batched_Success() public view {
        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.BATCHED, TC.VOLUME, 5);
        assertEq(feeInfo.fee, TC.BATCH_FEE * 5);
        assertEq(uint256(feeInfo.txType), uint256(Types.TxType.BATCHED));
    }

    function test_CalculateFee_Batched_LargeVolume() public view {
        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.BATCHED, TC.LARGE_VOLUME, 3);
        assertEq(feeInfo.fee, 0);
        assertEq(uint256(feeInfo.txType), uint256(Types.TxType.BATCHED));
    }

    /* -------------------------------------------------------------------------- */
    /*                               applyFee                                     */
    /* -------------------------------------------------------------------------- */

    function test_ApplyFee_UpdatesTotalFees() public {
        bytes32 transferHash = keccak256(abi.encodePacked("transfer1"));
        uint64 batchId = 1;
        uint256 fee = TC.BASE_FEE;

        vm.prank(address(settlement));
        feeModule.applyFee(user, fee, transferHash, batchId, Types.TxType.DELAYED);

        assertEq(feeModule.getFeeOfTransaction(transferHash), fee);
        assertEq(feeModule.getTotalFeesCollected(), fee);
        assertEq(feeModule.getBatchTotalFees(batchId), fee);
    }

    function test_ApplyFee_Multiple_AccumulatesCorrectly() public {
        bytes32 hash1 = keccak256(abi.encodePacked("tx1"));
        bytes32 hash2 = keccak256(abi.encodePacked("tx2"));
        uint64 batchId = 1;

        vm.startPrank(address(settlement));
        feeModule.applyFee(user, TC.BASE_FEE, hash1, batchId, Types.TxType.INSTANT);
        feeModule.applyFee(user, TC.INSTANT_FEE, hash2, batchId, Types.TxType.INSTANT);
        vm.stopPrank();

        assertEq(feeModule.getTotalFeesCollected(), TC.BASE_FEE + TC.INSTANT_FEE);
        assertEq(feeModule.getBatchTotalFees(batchId), TC.BASE_FEE + TC.INSTANT_FEE);
    }

    /* -------------------------------------------------------------------------- */
    /*                         FULL FLOW SCENARIOS                                */
    /* -------------------------------------------------------------------------- */

    function test_FullFlow_CalculateAndApplyFee() public {
        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.INSTANT, TC.VOLUME, 1);
        assertEq(feeInfo.fee, TC.INSTANT_FEE);

        bytes32 transferHash = keccak256(abi.encodePacked("transfer1"));
        uint64 batchId = 1;

        vm.prank(address(settlement));
        feeModule.applyFee(user, feeInfo.fee, transferHash, batchId, Types.TxType.INSTANT);

        assertEq(feeModule.getFeeOfTransaction(transferHash), TC.INSTANT_FEE);
        assertEq(feeModule.getTotalFeesCollected(), TC.INSTANT_FEE);
        assertEq(feeModule.getBatchTotalFees(batchId), TC.INSTANT_FEE);
    }

    function test_MultipleUsers_IndependentFreeTier() public {
        address user2 = makeAddr("user2");

        vm.startPrank(address(settlement));

        for (uint256 i = 0; i < 5; i++) {
            Types.FeeInfo memory feeInfo1 = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
            assertEq(feeInfo1.fee, 0);
            assertEq(uint256(feeInfo1.txType), uint256(Types.TxType.FREE_TIER));

            bytes32 txHash = keccak256(abi.encodePacked(user, i));
            feeModule.applyFee(user, 0, txHash, 1, Types.TxType.FREE_TIER);
        }

        Types.FeeInfo memory feeInfo2 = feeModule.calculateFee(user2, Types.TxType.DELAYED, TC.VOLUME, 1);
        assertEq(feeInfo2.fee, 0);
        assertEq(uint256(feeInfo2.txType), uint256(Types.TxType.FREE_TIER));
        assertEq(feeInfo2.freeQuota, TC.FREE_TX_AMOUNT);

        bytes32 txHash2 = keccak256(abi.encodePacked(user2, uint256(0)));
        feeModule.applyFee(user2, 0, txHash2, 2, Types.TxType.FREE_TIER);

        assertEq(feeModule.getRemainingFreeTierTransactions(user), TC.FREE_TX_AMOUNT - 5);
        assertEq(feeModule.getRemainingFreeTierTransactions(user2), TC.FREE_TX_AMOUNT - 1);

        vm.stopPrank();
    }

    function test_FreeQuota_AfterApply() public {
        Types.FeeInfo memory feeInfo;

        for (uint256 i = 0; i < TC.FREE_TX_AMOUNT; i++) {
            feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
            vm.prank(address(settlement));
            feeModule.applyFee(user, feeInfo.fee, keccak256(abi.encodePacked(i)), 1, feeInfo.txType);

            assertEq(feeModule.getRemainingFreeTierTransactions(user), TC.FREE_TX_AMOUNT - (i + 1));
        }

        feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
        assertEq(feeInfo.fee, TC.BASE_FEE);
    }

    function test_MultipleBatches_SeparateFeeAccumulation() public {
        bytes32 hash1 = keccak256(abi.encodePacked("tx1"));
        bytes32 hash2 = keccak256(abi.encodePacked("tx2"));
        bytes32 hash3 = keccak256(abi.encodePacked("tx3"));

        vm.startPrank(address(settlement));
        feeModule.applyFee(user, TC.BASE_FEE, hash1, 1, Types.TxType.DELAYED);
        feeModule.applyFee(user, TC.INSTANT_FEE, hash2, 1, Types.TxType.INSTANT);
        feeModule.applyFee(user, TC.BATCH_FEE * 3, hash3, 2, Types.TxType.BATCHED);
        vm.stopPrank();

        assertEq(feeModule.getBatchTotalFees(1), TC.BASE_FEE + TC.INSTANT_FEE);
        assertEq(feeModule.getBatchTotalFees(2), TC.BATCH_FEE * 3);
        assertEq(feeModule.getTotalFeesCollected(), TC.BASE_FEE + TC.INSTANT_FEE + TC.BATCH_FEE * 3);
    }

    function test_LargeVolumeUser_ThenSmallVolume() public view {
        Types.FeeInfo memory feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.LARGE_VOLUME, 1);
        assertEq(feeInfo.fee, 0);
        assertEq(feeInfo.freeQuota, TC.FREE_TX_AMOUNT);

        feeInfo = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
        assertEq(feeInfo.fee, 0);
        assertEq(uint256(feeInfo.txType), uint256(Types.TxType.FREE_TIER));
        assertEq(feeInfo.freeQuota, TC.FREE_TX_AMOUNT);
    }

    function test_FreeTier_AcrossDayBoundary() public {
        for (uint256 i = 0; i < 3; i++) {
            feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
        }
        assertEq(feeModule.getRemainingFreeTierTransactions(user), 10);

        vm.prank(address(settlement));
        feeModule.applyFee(user, 0, keccak256(abi.encodePacked("tx1")), 1, Types.TxType.FREE_TIER);
        assertEq(feeModule.getRemainingFreeTierTransactions(user), 9);

        vm.warp(block.timestamp + 12 hours);
        assertEq(feeModule.getRemainingFreeTierTransactions(user), 9);

        vm.warp(block.timestamp + 13 hours); // total 25 hours
        assertEq(feeModule.getRemainingFreeTierTransactions(user), TC.FREE_TX_AMOUNT);
    }

    function test_CalculateFee_FreeTierLimitExceeded() public {
        vm.startPrank(address(settlement));
        for (uint256 i = 0; i < TC.FREE_TX_AMOUNT; i++) {
            Types.FeeInfo memory feeInfo1 = feeModule.calculateFee(user, Types.TxType.DELAYED, TC.VOLUME, 1);
            assertEq(feeInfo1.fee, 0);
            assertEq(uint256(feeInfo1.txType), uint256(Types.TxType.FREE_TIER));

            bytes32 txHash = keccak256(abi.encodePacked(i));
            feeModule.applyFee(user, 0, txHash, 1, Types.TxType.FREE_TIER);
        }

        vm.expectRevert(Errors.FeeModule__FreeTierLimitExceeded.selector);
        feeModule.calculateFee(user, Types.TxType.FREE_TIER, TC.VOLUME, 1);
        vm.stopPrank();
    }

    function test_ApplyFee_FreeTierLimitExceeded() public {
        for (uint256 i = 0; i < TC.FREE_TX_AMOUNT; i++) {
            vm.prank(address(settlement));
            feeModule.applyFee(user, 0, keccak256(abi.encodePacked(i)), 1, Types.TxType.FREE_TIER);
        }

        vm.prank(address(settlement));
        vm.expectRevert(Errors.FeeModule__FreeTierLimitExceeded.selector);
        feeModule.applyFee(user, 0, keccak256("overflow"), 1, Types.TxType.FREE_TIER);
    }

    /* -------------------------------------------------------------------------- */
    /*                                GETTERS                                     */
    /* -------------------------------------------------------------------------- */

    function test_Getters_All() public {
        bytes32 txHash1 = keccak256("tx1");
        bytes32 txHash2 = keccak256("tx2");
        uint64 batchId1 = 1;
        uint64 batchId2 = 2;

        vm.startPrank(address(settlement));
        feeModule.applyFee(user, TC.BASE_FEE, txHash1, 1, Types.TxType.DELAYED);
        feeModule.applyFee(user, TC.INSTANT_FEE, txHash2, 2, Types.TxType.INSTANT);
        vm.stopPrank();

        feeModule.calculateFee(user2, Types.TxType.DELAYED, TC.VOLUME, 1);
        vm.prank(address(settlement));
        feeModule.applyFee(user2, 0, keccak256("freeTx"), 3, Types.TxType.FREE_TIER);

        assertEq(feeModule.getSettlement(), address(settlement));
        assertEq(feeModule.getOwner(), DEFAULT_SENDER);

        Types.FreeTxInfo memory usage = feeModule.getFreeTxUsage(user2);
        assertEq(usage.count, 1);
        assertEq(usage.day, block.timestamp / 1 days);

        assertEq(feeModule.getFeeOfTransaction(txHash1), TC.BASE_FEE);
        assertEq(feeModule.getFeeOfTransaction(txHash2), TC.INSTANT_FEE);

        assertEq(feeModule.getTotalFeesCollected(), TC.BASE_FEE + TC.INSTANT_FEE);

        assertEq(feeModule.getBatchTotalFees(1), TC.BASE_FEE);
        assertEq(feeModule.getBatchTotalFees(2), TC.INSTANT_FEE);
        assertEq(feeModule.getBatchTotalFees(3), 0);

        uint256 remaining = feeModule.getRemainingFreeTierTransactions(user2);
        assertEq(remaining, TC.FREE_TX_AMOUNT - 1);
    }
}
