// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IntegrationDeployHelpers} from "../utils/IntegrationDeployHelpers.sol";
import {TestConstants as TC} from "../utils/TestConstants.sol";

import {ISettlement} from "../../src/interfaces/ISettlement.sol";

import {Types} from "../../src/libraries/Types.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract SettlementIntegrationTest is Test, IntegrationDeployHelpers {
    using MessageHashUtils for bytes32;

    struct ExecuteData {
        bytes32[] txProof;
        bytes32[] wlProof;
        Types.TransferData data;
    }

    // Updated Merkle root including batchSalt
    bytes32 constant BATCH_MERKLE_ROOT = 0x3a0c41421185f03cda4c7149849489222399b27838a28ef7931c459b142b0877;
    bytes32 constant WHITELIST_MERKLE_ROOT = 0x9026d8a85fee65817561c5d02b985f4e34a8f70d19b21f5382e13c646a71176a;

    function setUp() public {
        _initUser();
        _initUser2();
        _initFeeModule();
        _initRegistry();
        _initSettlement();
        _initToken();

        vm.startPrank(DEFAULT_SENDER);
        feeModule.setSettlement(address(settlement));
        settlement.setWhitelistRegistry(address(registry));
        vm.stopPrank();

        vm.startPrank(TC.UPDATER);
        registry.addAuthorizedUpdater(user);

        vm.startPrank(DEFAULT_SENDER);
        settlement.setFeeModule(address(feeModule));
        settlement.setMaxTxPerBatch(uint32(TC.MAX_TX_PER_BATCH));
        settlement.setTimelockDuration(uint48(TC.TIMELOCK_DURATION));
        settlement.setToken(address(mockToken));
        settlement.approveAggregator(user2);
        _updateMerkleRoot();
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                           INITIAL STATE                                    */
    /* -------------------------------------------------------------------------- */

    function test_Constructor_InitialValues() public view {
        assert(address(settlement.getFeeModule()) == address(feeModule));
        assert(address(settlement.getWhitelistRegistry()) == address(registry));
        assert(address(settlement.getToken()) == address(mockToken));
        assert(settlement.getMaxTxPerBatch() == TC.MAX_TX_PER_BATCH);
        assert(settlement.getTimelockDuration() == TC.TIMELOCK_DURATION);

        assert(settlement.isApprovedAggregator(user2));
    }

    /* -------------------------------------------------------------------------- */
    /*                               HELPERS                                      */
    /* -------------------------------------------------------------------------- */

    function _updateMerkleRoot() public returns (bytes memory signature) {
        uint64 currentNonce = registry.getCurrentNonce();
        bytes32 hash =
            keccak256(abi.encodePacked(WHITELIST_MERKLE_ROOT, currentNonce, block.chainid, address(registry)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivKey, signedHash);
        signature = abi.encodePacked(r, s, v);

        registry.updateMerkleRoot(WHITELIST_MERKLE_ROOT, currentNonce, signature);
    }

    function _mintTokensAndApprove(address to, uint256 amount) internal {
        mockToken.mint(to, amount);
        vm.prank(to);
        mockToken.approve(address(settlement), amount);
    }

    function _submitBatch() public {
        vm.prank(user2);
        settlement.submitBatch(BATCH_MERKLE_ROOT, uint32(TC.MAX_TX_PER_BATCH), 1);
        vm.warp(25 hours);
    }

    /* -------------------------------------------------------------------------- */
    /*                              submitBatch                                   */
    /* -------------------------------------------------------------------------- */

    function test_SubmitBatch_EmitsEvent() public {
        vm.prank(user2);

        vm.expectEmit(true, false, false, true);
        emit ISettlement.BatchSubmitted(1, BATCH_MERKLE_ROOT, uint32(TC.MAX_TX_PER_BATCH), uint48(block.timestamp));
        (bool success, uint256 batchId) = settlement.submitBatch(BATCH_MERKLE_ROOT, uint32(TC.MAX_TX_PER_BATCH), 1);

        Types.Batch memory batch = settlement.getBatchById(uint64(batchId));
        assertTrue(success);
        assertEq(settlement.getCurrentBatchId(), batchId);

        assertEq(batch.merkleRoot, BATCH_MERKLE_ROOT);
        assertEq(batch.timestamp, block.timestamp);
        assertEq(batch.txCount, TC.MAX_TX_PER_BATCH);
        assertEq(batch.unlockTime, block.timestamp + TC.TIMELOCK_DURATION);
    }

    function test_SubmitBatch_InvalidTxCount() public {
        vm.startPrank(user2);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(BATCH_MERKLE_ROOT, 0, 1);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(BATCH_MERKLE_ROOT, uint32(TC.MAX_TX_PER_BATCH) + 1, 1);

        vm.stopPrank();
    }

    function test_SubmitBatch_AlreadySubmitted() public {
        _submitBatch();

        vm.prank(user2);
        vm.expectRevert(Errors.Settlement__BatchAlreadySubmitted.selector);
        settlement.submitBatch(BATCH_MERKLE_ROOT, uint32(TC.MAX_TX_PER_BATCH), 1);
    }

    function test_SubmitBatch_DynamicConfigChanges() public {
        uint32 newMaxTx = 5;
        uint48 newTimelock = 2 days;

        vm.startPrank(DEFAULT_SENDER);
        settlement.setMaxTxPerBatch(uint32(newMaxTx));
        settlement.setTimelockDuration(newTimelock);
        vm.stopPrank();

        vm.startPrank(user2);
        uint32 oldLimitTxCount = uint32(TC.MAX_TX_PER_BATCH);

        assertGt(oldLimitTxCount, newMaxTx);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(BATCH_MERKLE_ROOT, oldLimitTxCount, 1);

        (bool success, uint256 batchId) = settlement.submitBatch(BATCH_MERKLE_ROOT, newMaxTx, 1);
        assertTrue(success);

        Types.Batch memory batch = settlement.getBatchById(uint64(batchId));
        assertEq(batch.unlockTime, block.timestamp + newTimelock);
        vm.stopPrank();
    }

    function test_SubmitBatch_BatchIdIncrement() public {
        vm.prank(user2);
        (bool success1, uint256 batchId1) = settlement.submitBatch(BATCH_MERKLE_ROOT, uint32(TC.MAX_TX_PER_BATCH), 1);
        assertTrue(success1);

        vm.warp(block.timestamp + 1 hours);

        bytes32 newRoot = keccak256(abi.encodePacked("newRoot"));
        vm.prank(user2);
        (bool success2, uint256 batchId2) = settlement.submitBatch(newRoot, uint32(TC.MAX_TX_PER_BATCH), 1);
        assertTrue(success2);

        assertEq(batchId2, batchId1 + 1);
    }

    function test_SubmitBatch_StateIntegrity() public {
        bytes32 root1 = keccak256(abi.encodePacked("root1"));
        bytes32 root2 = keccak256(abi.encodePacked("root2"));

        vm.startPrank(user2);

        (, uint256 batchId1) = settlement.submitBatch(root1, uint32(TC.MAX_TX_PER_BATCH), 1);

        vm.warp(block.timestamp + 1 hours);
        (, uint256 batchId2) = settlement.submitBatch(root2, uint32(TC.MAX_TX_PER_BATCH), 1);

        vm.stopPrank();

        assertEq(batchId2, batchId1 + 1);
        assertEq(settlement.getBatchIdByRoot(root1), batchId1);
        assertEq(settlement.getBatchIdByRoot(root2), batchId2);

        Types.Batch memory batch1Data = settlement.getBatchById(uint64(batchId1));
        assertEq(batch1Data.merkleRoot, root1);
        assert(batch1Data.timestamp < settlement.getBatchById(uint64(batchId2)).timestamp);
    }

    function test_SubmitBatch_AggregatorLifecycle() public {
        _submitBatch();

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user2));
        settlement.disapproveAggregator(user2);

        vm.prank(DEFAULT_SENDER);
        settlement.disapproveAggregator(user2);

        bytes32 newRoot = keccak256(abi.encodePacked("newRoot"));
        vm.prank(user2);
        vm.expectRevert(Errors.Settlement__AggregatorNotApproved.selector);
        settlement.submitBatch(newRoot, uint32(TC.MAX_TX_PER_BATCH), 1);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user2));
        settlement.approveAggregator(user2);

        vm.prank(DEFAULT_SENDER);
        settlement.approveAggregator(user2);

        vm.prank(user2);
        (bool success,) = settlement.submitBatch(newRoot, uint32(TC.MAX_TX_PER_BATCH), 1);
        assertTrue(success);
    }

    function testFuzz_SubmitBatch_Success(bytes32 merkleRoot, uint256 txCount) public {
        txCount = bound(txCount, 1, TC.MAX_TX_PER_BATCH);

        vm.assume(merkleRoot != bytes32(0));
        vm.assume(merkleRoot != BATCH_MERKLE_ROOT);

        vm.prank(user2);
        (bool success, uint256 batchId) = settlement.submitBatch(merkleRoot, uint32(txCount), 1);

        assertTrue(success);

        Types.Batch memory batch = settlement.getBatchById(uint64(batchId));
        assertEq(batch.merkleRoot, merkleRoot);
        assertEq(batch.txCount, txCount);
        assertEq(settlement.getBatchIdByRoot(merkleRoot), batchId);
    }

    function testFuzz_SubmitBatch_RevertIfMaxTxExceeded(bytes32 merkleRoot, uint256 txCount) public {
        txCount = bound(txCount, TC.MAX_TX_PER_BATCH + 1, type(uint32).max);

        vm.prank(user2);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(merkleRoot, uint32(txCount), 1);
    }

    /* -------------------------------------------------------------------------- */
    /*                            executeTransfer                                 */
    /* -------------------------------------------------------------------------- */

    function test_ExecuteTransfer_SuccessAndEmits() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex11();

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        vm.expectEmit(true, true, false, true);
        emit ISettlement.TransferExecuted(
            executeData.data.from, executeData.data.to, executeData.data.amount, executeData.data.nonce
        );

        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertTrue(success);
        assertEq(mockToken.balanceOf(executeData.data.from), 0);
        assertEq(mockToken.balanceOf(executeData.data.to), executeData.data.amount);
    }

    function test_ExecuteTransfer_RevertIfBeforeUnlock() public {
        vm.prank(user2);
        settlement.submitBatch(BATCH_MERKLE_ROOT, uint32(TC.MAX_TX_PER_BATCH), 1);
        vm.warp(block.timestamp + TC.TIMELOCK_DURATION - 1);

        ExecuteData memory executeData = _getExecuteDataForIndex11();

        vm.expectRevert(Errors.Settlement__BatchLocked.selector);
        settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);
    }

    function test_ExecuteTransfer_RevertIfAlreadyExecuted() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex11();

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount * 2);

        settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        vm.expectRevert(Errors.Settlement__TransferAlreadyExecuted.selector);
        settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);
    }

    function test_ExecuteTransfer_RevertIfInsufficientBalance() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex11();

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount - 1);

        vm.expectRevert(Errors.Settlement__InsufficientBalance.selector);
        settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);
    }

    function test_ExecuteTransfer_RevertIfInvalidTxProof() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex11();

        executeData.txProof[0] = bytes32(uint256(executeData.txProof[0]) + 1);

        vm.expectRevert(Errors.Settlement__InvalidMerkleProof.selector);
        settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);
    }

    function test_ExecuteTransfer_RevertIfInvalidBatch() public {
        ExecuteData memory executeData = _getExecuteDataForIndex11();
        executeData.data.batchId = 999;

        vm.expectRevert(Errors.Settlement__InvalidBatch.selector);
        settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);
    }

    function test_ExecuteTransfer_RevertIfBatchIdMismatch() public {
        vm.startPrank(user2);
        settlement.submitBatch(BATCH_MERKLE_ROOT, uint32(TC.MAX_TX_PER_BATCH), 1);
        bytes32 otherRoot = keccak256("other");
        (, uint64 batchB) = settlement.submitBatch(otherRoot, uint32(TC.MAX_TX_PER_BATCH), 1);
        vm.stopPrank();

        vm.warp(25 hours);
        ExecuteData memory executeData = _getExecuteDataForIndex11();
        executeData.data.batchId = batchB;
        vm.expectRevert(Errors.Settlement__InvalidMerkleProof.selector);
        settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);
    }

    function test_ExecuteTransfer_Batched_NoWhitelistProof_Reverts() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex13(); // BATCHED

        // Видаляємо whitelist proof повністю
        bytes32[] memory emptyProof = new bytes32[](0);
        executeData.wlProof = emptyProof;

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        vm.expectRevert(Errors.Settlement__NotWhitelisted.selector);
        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertFalse(success);
        assertEq(mockToken.balanceOf(executeData.data.from), executeData.data.amount);
        assertEq(mockToken.balanceOf(executeData.data.to), 0);
    }

    function test_ExecuteTransfer_Batched_InvalidWhitelistProof_Reverts() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex13(); // BATCHED

        executeData.wlProof[0] = keccak256(abi.encodePacked("invalid"));

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        vm.expectRevert(Errors.Settlement__NotWhitelisted.selector);
        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertFalse(success);
        assertEq(mockToken.balanceOf(executeData.data.from), executeData.data.amount);
        assertEq(mockToken.balanceOf(executeData.data.to), 0);
    }

    function test_ExecuteTransfer_NonBatched_SkipsWhitelistValidation() public {
        _submitBatch();
        {
            ExecuteData memory instantData = _getExecuteDataForIndex11();
            instantData.data.txType = Types.TxType.INSTANT;
            bytes32[] memory emptyProof = new bytes32[](0);
            instantData.wlProof = emptyProof;

            uint256 balanceBefore = mockToken.balanceOf(instantData.data.to);

            _mintTokensAndApprove(instantData.data.from, instantData.data.amount);
            bool successInstant = settlement.executeTransfer(instantData.txProof, instantData.wlProof, instantData.data);
            assertTrue(successInstant);

            uint256 balanceAfter = mockToken.balanceOf(instantData.data.to);
            assertEq(balanceAfter, balanceBefore + instantData.data.amount);
        }

        {
            ExecuteData memory delayedData = _getExecuteDataForIndex0();
            delayedData.data.txType = Types.TxType.DELAYED;
            bytes32[] memory emptyProof = new bytes32[](0);
            delayedData.wlProof = emptyProof;

            uint256 balanceBefore = mockToken.balanceOf(delayedData.data.to);

            _mintTokensAndApprove(delayedData.data.from, delayedData.data.amount);
            bool successDelayed = settlement.executeTransfer(delayedData.txProof, delayedData.wlProof, delayedData.data);
            assertTrue(successDelayed);

            uint256 balanceAfter = mockToken.balanceOf(delayedData.data.to);
            assertEq(balanceAfter, balanceBefore + delayedData.data.amount);
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                            Fee Types Tests                                 */
    /* -------------------------------------------------------------------------- */

    function test_ExecuteTransfer_FreeWithDelayedFee() public {
        _submitBatch();
        uint64 batchId = settlement.getCurrentBatchId();
        ExecuteData memory executeData = _getExecuteDataForIndex0();
        executeData.data.txType = Types.TxType.DELAYED;
        executeData.data.amount = 100000000;

        uint256 expectedFee = 0;

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertTrue(success);
        assertEq(mockToken.balanceOf(executeData.data.from), 0);
        assertEq(mockToken.balanceOf(executeData.data.to), executeData.data.amount);

        bytes32 txHash = keccak256(
            abi.encodePacked(
                executeData.data.from,
                executeData.data.to,
                executeData.data.amount,
                executeData.data.nonce,
                executeData.data.timestamp,
                executeData.data.recipientCount,
                executeData.data.txType,
                uint64(1) // batchSalt
            )
        );

        assertEq(feeModule.getFeeOfTransaction(txHash), expectedFee);
        assertEq(feeModule.getBatchTotalFees(executeData.data.batchId), expectedFee);
    }

    function test_ExecuteTransfer_Delayed_InvalidFrom() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex17();

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertFalse(success);
    }

    function test_ExecuteTransfer_Delayed_InvalidTo() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex18();

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertFalse(success);
    }

    function test_ExecuteTransfer_WithInstantFee() public {
        _submitBatch();
        uint64 batchId = settlement.getCurrentBatchId();
        ExecuteData memory executeData = _getExecuteDataForIndex11();

        executeData.data.txType = Types.TxType.INSTANT;
        executeData.data.amount = 200000000; // Less than LARGE_VOLUME

        // INSTANT_FEE = 200_000
        uint256 expectedFee = 200_000;

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertTrue(success);
        assertEq(mockToken.balanceOf(executeData.data.from), 0);
        assertEq(mockToken.balanceOf(executeData.data.to), executeData.data.amount);

        bytes32 txHash = keccak256(
            abi.encodePacked(
                executeData.data.from,
                executeData.data.to,
                executeData.data.amount,
                executeData.data.nonce,
                executeData.data.timestamp,
                executeData.data.recipientCount,
                executeData.data.txType,
                uint64(1) // batchSalt
            )
        );

        assertEq(feeModule.getFeeOfTransaction(txHash), expectedFee);
        assertEq(feeModule.getBatchTotalFees(executeData.data.batchId), expectedFee);
    }

    function test_ExecuteTransfer_Instant_InvalidRecipientCount() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex12();

        executeData.data.txType = Types.TxType.INSTANT;
        executeData.data.amount = 300000000;

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertFalse(success);
        assertEq(mockToken.balanceOf(executeData.data.from), executeData.data.amount);
        assertEq(mockToken.balanceOf(executeData.data.to), 0);
    }

    function test_ExecuteTransfer_WithBatchedFee() public {
        _submitBatch();
        uint64 batchId = settlement.getCurrentBatchId();
        ExecuteData memory executeData = _getExecuteDataForIndex13();

        uint256 expectedFee = TC.BATCH_FEE * executeData.data.recipientCount;

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertTrue(success);
        assertEq(mockToken.balanceOf(executeData.data.from), 0);
        assertEq(mockToken.balanceOf(executeData.data.to), executeData.data.amount);

        bytes32 txHash = keccak256(
            abi.encodePacked(
                executeData.data.from,
                executeData.data.to,
                executeData.data.amount,
                executeData.data.nonce,
                executeData.data.timestamp,
                executeData.data.recipientCount,
                executeData.data.txType,
                uint64(1) // batchSalt
            )
        );

        assertEq(feeModule.getFeeOfTransaction(txHash), expectedFee);
        assertEq(feeModule.getBatchTotalFees(executeData.data.batchId), expectedFee);
        assertEq(feeModule.getTotalFeesCollected(), expectedFee);
    }

    function test_ExecuteTransfer_Batched_NotWhitelisted() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex14();

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        vm.expectRevert(Errors.Settlement__NotWhitelisted.selector);
        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertFalse(success);
        assertEq(mockToken.balanceOf(executeData.data.from), executeData.data.amount);
        assertEq(mockToken.balanceOf(executeData.data.to), 0);
    }

    function test_ExecuteTransfer_Batched_InvalidRecipientCount() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex15();

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        vm.expectRevert(Errors.FeeModule__InvalidRecipientCount.selector);
        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertFalse(success);
        assertEq(mockToken.balanceOf(executeData.data.from), executeData.data.amount);
        assertEq(mockToken.balanceOf(executeData.data.to), 0);
    }

    function test_ExecuteTransfer_WithFreeTier() public {
        _submitBatch();
        uint64 batchId = settlement.getCurrentBatchId();
        ExecuteData memory executeData = _getExecuteDataForIndex10();

        executeData.data.txType = Types.TxType.FREE_TIER;
        executeData.data.amount = 50000000;

        // First free transaction - no fee
        uint256 expectedFee = 0;

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        // Check remaining free tier before
        uint256 remainingBefore = feeModule.getRemainingFreeTierTransactions(executeData.data.from);
        assertEq(remainingBefore, 10); // All 10 available

        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertTrue(success);
        assertEq(mockToken.balanceOf(executeData.data.from), 0);
        assertEq(mockToken.balanceOf(executeData.data.to), executeData.data.amount);

        bytes32 txHash = keccak256(
            abi.encodePacked(
                executeData.data.from,
                executeData.data.to,
                executeData.data.amount,
                executeData.data.nonce,
                executeData.data.timestamp,
                executeData.data.recipientCount,
                executeData.data.txType,
                uint64(1) // batchSalt
            )
        );

        assertEq(feeModule.getFeeOfTransaction(txHash), expectedFee);

        // Check remaining free tier after
        uint256 remainingAfter = feeModule.getRemainingFreeTierTransactions(executeData.data.from);
        assertEq(remainingAfter, 9); // 1 used
    }

    function test_ExecuteTransfer_DelayedFeeWithinFreeTier() public {
        _submitBatch();
        uint64 batchId = settlement.getCurrentBatchId();
        ExecuteData memory executeData = _getExecuteDataForIndex0();

        uint256 expectedFee = 0;

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertTrue(success);
        assertEq(mockToken.balanceOf(executeData.data.from), 0);
        assertEq(mockToken.balanceOf(executeData.data.to), executeData.data.amount);

        bytes32 txHash = keccak256(
            abi.encodePacked(
                executeData.data.from,
                executeData.data.to,
                executeData.data.amount,
                executeData.data.nonce,
                executeData.data.timestamp,
                executeData.data.recipientCount,
                executeData.data.txType,
                uint64(1) // batchSalt
            )
        );

        assertEq(feeModule.getFeeOfTransaction(txHash), expectedFee);
        uint256 remaining = feeModule.getRemainingFreeTierTransactions(executeData.data.from);
        assertEq(remaining, 9);
    }

    function test_ExecuteTransfer_LargeVolumeNoFee() public {
        _submitBatch();
        uint64 batchId = settlement.getCurrentBatchId();
        ExecuteData memory executeData = _getExecuteDataForIndex16();

        executeData.data.txType = Types.TxType.INSTANT;
        executeData.data.amount = 1000000000000000;

        // No fee for large volumes
        uint256 expectedFee = 0;

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertTrue(success);
        assertEq(mockToken.balanceOf(executeData.data.from), 0);
        assertEq(mockToken.balanceOf(executeData.data.to), executeData.data.amount);

        bytes32 txHash = keccak256(
            abi.encodePacked(
                executeData.data.from,
                executeData.data.to,
                executeData.data.amount,
                executeData.data.nonce,
                executeData.data.timestamp,
                executeData.data.recipientCount,
                executeData.data.txType,
                uint64(1) // batchSalt
            )
        );

        assertEq(feeModule.getFeeOfTransaction(txHash), expectedFee);
        assertEq(feeModule.getBatchTotalFees(executeData.data.batchId), expectedFee);
    }

    function test_ExecuteTransfer_DelayedTxFlow() public {
        _submitBatch();
        ExecuteData memory executeData0 = _getExecuteDataForIndex0();

        _mintTokensAndApprove(executeData0.data.from, executeData0.data.amount);

        bool success = settlement.executeTransfer(executeData0.txProof, executeData0.wlProof, executeData0.data);
        assertTrue(success);

        ExecuteData memory executeData1 = _getExecuteDataForIndex1();
        _mintTokensAndApprove(executeData1.data.from, executeData1.data.amount);

        bool success1 = settlement.executeTransfer(executeData1.txProof, executeData1.wlProof, executeData1.data);
        assertTrue(success1);

        ExecuteData memory executeData2 = _getExecuteDataForIndex2();
        _mintTokensAndApprove(executeData2.data.from, executeData2.data.amount);

        bool success2 = settlement.executeTransfer(executeData2.txProof, executeData2.wlProof, executeData2.data);
        assertTrue(success2);

        // 3
        ExecuteData memory executeData3 = _getExecuteDataForIndex3();
        _mintTokensAndApprove(executeData3.data.from, executeData3.data.amount);

        bool success3 = settlement.executeTransfer(executeData3.txProof, executeData3.wlProof, executeData3.data);
        assertTrue(success3);

        // 4
        ExecuteData memory executeData4 = _getExecuteDataForIndex4();
        _mintTokensAndApprove(executeData4.data.from, executeData4.data.amount);

        bool success4 = settlement.executeTransfer(executeData4.txProof, executeData4.wlProof, executeData4.data);
        assertTrue(success4);

        // 5
        ExecuteData memory executeData5 = _getExecuteDataForIndex5();
        _mintTokensAndApprove(executeData5.data.from, executeData5.data.amount);

        bool success5 = settlement.executeTransfer(executeData5.txProof, executeData5.wlProof, executeData5.data);
        assertTrue(success5);

        // 6
        ExecuteData memory executeData6 = _getExecuteDataForIndex6();
        _mintTokensAndApprove(executeData6.data.from, executeData6.data.amount);

        bool success6 = settlement.executeTransfer(executeData6.txProof, executeData6.wlProof, executeData6.data);
        assertTrue(success6);

        // 7
        ExecuteData memory executeData7 = _getExecuteDataForIndex7();
        _mintTokensAndApprove(executeData7.data.from, executeData7.data.amount);

        bool success7 = settlement.executeTransfer(executeData7.txProof, executeData7.wlProof, executeData7.data);
        assertTrue(success7);

        // 8
        ExecuteData memory executeData8 = _getExecuteDataForIndex8();
        _mintTokensAndApprove(executeData8.data.from, executeData8.data.amount);

        bool success8 = settlement.executeTransfer(executeData8.txProof, executeData8.wlProof, executeData8.data);
        assertTrue(success8);

        // 9
        ExecuteData memory executeData9 = _getExecuteDataForIndex9();
        _mintTokensAndApprove(executeData9.data.from, executeData9.data.amount);

        bool success9 = settlement.executeTransfer(executeData9.txProof, executeData9.wlProof, executeData9.data);
        assertTrue(success9);

        bytes32 txHash9 = keccak256(
            abi.encodePacked(
                executeData9.data.from,
                executeData9.data.to,
                executeData9.data.amount,
                executeData9.data.nonce,
                executeData9.data.timestamp,
                executeData9.data.recipientCount,
                executeData9.data.txType
            )
        );
        assertEq(feeModule.getFeeOfTransaction(txHash9), 0);

        // 10
        ExecuteData memory executeData10 = _getExecuteDataForIndex10();
        _mintTokensAndApprove(executeData10.data.from, executeData10.data.amount);

        vm.expectRevert(Errors.FeeModule__FreeTierLimitExceeded.selector);
        bool success10 = settlement.executeTransfer(executeData10.txProof, executeData10.wlProof, executeData10.data);
        assertFalse(success10);
    }

    function test_ExecuteTransfer_GasComparison() public {
        _submitBatch();

        // === DELAYED (free tier) ===
        ExecuteData memory delayedData = _getExecuteDataForIndex0();
        _mintTokensAndApprove(delayedData.data.from, delayedData.data.amount);

        uint256 gasStartDelayed = gasleft();
        settlement.executeTransfer(delayedData.txProof, delayedData.wlProof, delayedData.data);
        uint256 gasUsedDelayed = gasStartDelayed - gasleft();

        // === INSTANT ===
        ExecuteData memory instantData = _getExecuteDataForIndex11();
        _mintTokensAndApprove(instantData.data.from, instantData.data.amount);

        uint256 gasStartInstant = gasleft();
        settlement.executeTransfer(instantData.txProof, instantData.wlProof, instantData.data);
        uint256 gasUsedInstant = gasStartInstant - gasleft();

        // === BATCHED ===
        ExecuteData memory batchedData = _getExecuteDataForIndex13();
        _mintTokensAndApprove(batchedData.data.from, batchedData.data.amount);

        uint256 gasStartBatched = gasleft();
        settlement.executeTransfer(batchedData.txProof, batchedData.wlProof, batchedData.data);
        uint256 gasUsedBatched = gasStartBatched - gasleft();

        console.log("=== GAS COMPARISON ===");
        console.log("DELAYED (free):  ", gasUsedDelayed);
        console.log("INSTANT:         ", gasUsedInstant);
        console.log("BATCHED (15 rec):", gasUsedBatched);

        assertGt(gasUsedDelayed, 0);
        assertGt(gasUsedInstant, 0);
        assertGt(gasUsedBatched, 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                              pause/unpause                                 */
    /* -------------------------------------------------------------------------- */

    function test_ExecuteTransfer_PauseUnpause_Workflow() public {
        _submitBatch();
        ExecuteData memory executeData = _getExecuteDataForIndex11();

        _mintTokensAndApprove(executeData.data.from, executeData.data.amount);

        vm.prank(DEFAULT_SENDER);
        settlement.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        vm.prank(DEFAULT_SENDER);
        settlement.unpause();

        bool success = settlement.executeTransfer(executeData.txProof, executeData.wlProof, executeData.data);

        assertTrue(success);
        assertEq(mockToken.balanceOf(executeData.data.from), 0);
        assertEq(mockToken.balanceOf(executeData.data.to), executeData.data.amount);
    }

    /* -------------------------------------------------------------------------- */
    /*                         executeData HEPLERS                                */
    /* -------------------------------------------------------------------------- */

    function _getExecuteDataForIndex11() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);
        txProof[0] = 0x462abd36dedb15579a43289e45666716fa82e276865699156f10f01fce09bea4;
        txProof[1] = 0x591ff5b157a63b6c10acb4331c80fe4c013f946c177848663e17c995d065ab6c;
        txProof[2] = 0x8097f9b2b4adcb7ea03968a76be829838c7e54478a37edf3c2060e1626be7fb9;
        txProof[3] = 0x31994ea0b0c611d5c8673e93d7acac8ce3c40c1a7ff9612645345abc39d59975;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;
        executeData.txProof = txProof;

        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;

        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 200000000,
            nonce: 12,
            timestamp: 1766392480,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.INSTANT
        });
    }

    function _getExecuteDataForIndex13() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);
        txProof[0] = 0x7401529a3f64f3280807f8c1c25476cb42f45a8d53eb4a8ce0489ca439530b43;
        txProof[1] = 0x30265017c12a0d5f16aa7c34dea1bf8fc8554bbdc356287671971c4a4da6b460;
        txProof[2] = 0x210818ded81351b6dc7f13a560472c3185d0bae960d8f7212190674caacdcfa8;
        txProof[3] = 0x31994ea0b0c611d5c8673e93d7acac8ce3c40c1a7ff9612645345abc39d59975;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;
        executeData.txProof = txProof;

        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;

        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            amount: 500000000,
            nonce: 14,
            timestamp: 1766392482,
            recipientCount: 5,
            batchId: 1,
            txType: Types.TxType.BATCHED
        });
    }

    function _getExecuteDataForIndex14() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);
        txProof[0] = 0xac933fbe94da3ad81a1b622b7e9e83dce453dc6588b908ec4e39edc0afb91dc6;
        txProof[1] = 0x287d3ddd35e0c598f46919e410628799adaf9b4d25fcd921e17b0077e12bde90;
        txProof[2] = 0x210818ded81351b6dc7f13a560472c3185d0bae960d8f7212190674caacdcfa8;
        txProof[3] = 0x31994ea0b0c611d5c8673e93d7acac8ce3c40c1a7ff9612645345abc39d59975;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;
        executeData.txProof = txProof;

        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;

        executeData.data = Types.TransferData({
            from: 0x1234567890123456789012345678901234567890,
            to: 0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            amount: 150000000,
            nonce: 15,
            timestamp: 1766392483,
            recipientCount: 3,
            batchId: 1,
            txType: Types.TxType.BATCHED
        });
    }

    function _getExecuteDataForIndex15() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);
        txProof[0] = 0x864e732fa92158038c741b630577f00889c249ae8441ddaff05c2e185153afc6;
        txProof[1] = 0x287d3ddd35e0c598f46919e410628799adaf9b4d25fcd921e17b0077e12bde90;
        txProof[2] = 0x210818ded81351b6dc7f13a560472c3185d0bae960d8f7212190674caacdcfa8;
        txProof[3] = 0x31994ea0b0c611d5c8673e93d7acac8ce3c40c1a7ff9612645345abc39d59975;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;
        executeData.txProof = txProof;

        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;

        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 16,
            timestamp: 1766392484,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.BATCHED
        });
    }

    function _getExecuteDataForIndex12() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);
        txProof[0] = 0x560083d61bbad176074a8ff65fa7a2b20cbc6080b8176f55d47bdd63503e7b49;
        txProof[1] = 0x30265017c12a0d5f16aa7c34dea1bf8fc8554bbdc356287671971c4a4da6b460;
        txProof[2] = 0x210818ded81351b6dc7f13a560472c3185d0bae960d8f7212190674caacdcfa8;
        txProof[3] = 0x31994ea0b0c611d5c8673e93d7acac8ce3c40c1a7ff9612645345abc39d59975;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;
        executeData.txProof = txProof;

        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;

        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 300000000,
            nonce: 13,
            timestamp: 1766392481,
            recipientCount: 3,
            batchId: 1,
            txType: Types.TxType.INSTANT
        });
    }

    function _getExecuteDataForIndex17() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](3);
        txProof[0] = 0xa477e0f7047a672583f1234bbd1485e57bda886eeea3ea1c2f76e242083c7d85;
        txProof[1] = 0x587b51946820bae3febac952ae82d0a10a2c1991bc887caf0c9831de2adb24bb;
        txProof[2] = 0xb6576b13bfbf97dae871a1b20d938a53329e10800ce093213abb811e236b7f6c;
        executeData.txProof = txProof;

        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;

        executeData.data = Types.TransferData({
            from: 0x0000000000000000000000000000000000000000,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 18,
            timestamp: 1766392486,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex18() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](2);
        txProof[0] = 0xc86dbe3ece3fe96d98622181ce07212d536e3217636b501a87e8a0e98b001a84;
        txProof[1] = 0xb6576b13bfbf97dae871a1b20d938a53329e10800ce093213abb811e236b7f6c;
        executeData.txProof = txProof;

        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;

        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x0000000000000000000000000000000000000000,
            amount: 100000000,
            nonce: 19,
            timestamp: 1766392487,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex10() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);
        txProof[0] = 0x24f873b47ae80c05f69983aace4819e4a005ab024673cc39313788f7a17d305b;
        txProof[1] = 0x591ff5b157a63b6c10acb4331c80fe4c013f946c177848663e17c995d065ab6c;
        txProof[2] = 0x8097f9b2b4adcb7ea03968a76be829838c7e54478a37edf3c2060e1626be7fb9;
        txProof[3] = 0x31994ea0b0c611d5c8673e93d7acac8ce3c40c1a7ff9612645345abc39d59975;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;
        executeData.txProof = txProof;

        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;

        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 50000000,
            nonce: 11,
            timestamp: 1766392479,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.FREE_TIER
        });
    }

    function _getExecuteDataForIndex0() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0xaa343f658768354a32adde8928537360916413cc47445617177a82024c422cf7;
        txProof[1] = 0xd5ec552c4f23fb2dbf907bf031e9e0d2e7c4a81c756071675b4a0625ad37f04c;
        txProof[2] = 0xea1b9fa23ead5569d3206b76771c4f20e36694822032d195804bebccca4aec51;
        txProof[3] = 0xb57edcb183a69f8f06421d1c7de51760cd1973914376637f50f10c3ed0fafeb2;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 1,
            timestamp: 1766392469,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex1() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0xa230e58e7054695cc88f543500b68c91e2bf2460ea4f50ac925640251a0e9c45;
        txProof[1] = 0xd5ec552c4f23fb2dbf907bf031e9e0d2e7c4a81c756071675b4a0625ad37f04c;
        txProof[2] = 0xea1b9fa23ead5569d3206b76771c4f20e36694822032d195804bebccca4aec51;
        txProof[3] = 0xb57edcb183a69f8f06421d1c7de51760cd1973914376637f50f10c3ed0fafeb2;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 2,
            timestamp: 1766392470,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex2() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0x8d2fc6d794ed4c205b3516a6c58f6f87eac5b6324dc4e6f88d46ca0cd622e523;
        txProof[1] = 0x33fe1a228e60193eb5abdba6048af955b49d849dc59ab5766873907ad10ad7f6;
        txProof[2] = 0xea1b9fa23ead5569d3206b76771c4f20e36694822032d195804bebccca4aec51;
        txProof[3] = 0xb57edcb183a69f8f06421d1c7de51760cd1973914376637f50f10c3ed0fafeb2;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 3,
            timestamp: 1766392471,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex3() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0x520268ed8b0dc9d3da345cf990135351322b673e52f2f58656bce527e24ecb4f;
        txProof[1] = 0x33fe1a228e60193eb5abdba6048af955b49d849dc59ab5766873907ad10ad7f6;
        txProof[2] = 0xea1b9fa23ead5569d3206b76771c4f20e36694822032d195804bebccca4aec51;
        txProof[3] = 0xb57edcb183a69f8f06421d1c7de51760cd1973914376637f50f10c3ed0fafeb2;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 4,
            timestamp: 1766392472,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex4() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0x31d36b489cdd2b5dbeb0e095f19a3db47bf729f1dc646977c3347a530dfd638f;
        txProof[1] = 0xee6a9ff5e1399fa946da5482a6f5d659903e7309c8747f7d22f554d54fc097e2;
        txProof[2] = 0xcbc1b17bd75d49c23213016ca8a662f2adaee9977ad570f2930a8275b25bb398;
        txProof[3] = 0xb57edcb183a69f8f06421d1c7de51760cd1973914376637f50f10c3ed0fafeb2;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 5,
            timestamp: 1766392473,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex5() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0xe19c6d48248dbca0b142cf85dd63eee8608c91acfefebbdc15b0efd3708d53ff;
        txProof[1] = 0xee6a9ff5e1399fa946da5482a6f5d659903e7309c8747f7d22f554d54fc097e2;
        txProof[2] = 0xcbc1b17bd75d49c23213016ca8a662f2adaee9977ad570f2930a8275b25bb398;
        txProof[3] = 0xb57edcb183a69f8f06421d1c7de51760cd1973914376637f50f10c3ed0fafeb2;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 6,
            timestamp: 1766392474,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex6() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0x9f8a7e4c0b8338ac03dd39fb2d6fa8082cf1d32badb2fa29fa959f626793e191;
        txProof[1] = 0xb3b6b7cdecd8ccdf8ba346985f530fbc878292d55f0ac9cda8689b4744570c7f;
        txProof[2] = 0xcbc1b17bd75d49c23213016ca8a662f2adaee9977ad570f2930a8275b25bb398;
        txProof[3] = 0xb57edcb183a69f8f06421d1c7de51760cd1973914376637f50f10c3ed0fafeb2;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 7,
            timestamp: 1766392475,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex7() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0x3d5be0058769e8f9e9d472a4f48190b04ccfa6e7aa2fa412653ed22b7649c75c;
        txProof[1] = 0xb3b6b7cdecd8ccdf8ba346985f530fbc878292d55f0ac9cda8689b4744570c7f;
        txProof[2] = 0xcbc1b17bd75d49c23213016ca8a662f2adaee9977ad570f2930a8275b25bb398;
        txProof[3] = 0xb57edcb183a69f8f06421d1c7de51760cd1973914376637f50f10c3ed0fafeb2;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 8,
            timestamp: 1766392476,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex8() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0x5215e0e0db139e499cdf1c49c9eb5b1ec1de1eb4e527b8a5c9566128f5c20f05;
        txProof[1] = 0x4c263c99b9e277450d7f2ef634c883775456dd4dffb96f46ae22fffa0ba532b1;
        txProof[2] = 0x8097f9b2b4adcb7ea03968a76be829838c7e54478a37edf3c2060e1626be7fb9;
        txProof[3] = 0x31994ea0b0c611d5c8673e93d7acac8ce3c40c1a7ff9612645345abc39d59975;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 9,
            timestamp: 1766392477,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex9() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](5);        txProof[0] = 0xc8570da104d31b70fa27d5a6db45ef393d9150795802006294ee05aaaf99ff4c;
        txProof[1] = 0x4c263c99b9e277450d7f2ef634c883775456dd4dffb96f46ae22fffa0ba532b1;
        txProof[2] = 0x8097f9b2b4adcb7ea03968a76be829838c7e54478a37edf3c2060e1626be7fb9;
        txProof[3] = 0x31994ea0b0c611d5c8673e93d7acac8ce3c40c1a7ff9612645345abc39d59975;
        txProof[4] = 0xc4b8283ef7ff08ddc4b02fd8a783c2b52430b7a7b359b905c99b2c99248471dc;

        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 100000000,
            nonce: 10,
            timestamp: 1766392478,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.DELAYED
        });
    }

    function _getExecuteDataForIndex16() internal pure returns (ExecuteData memory executeData) {
        bytes32[] memory txProof = new bytes32[](3);        txProof[0] = 0xed3ccf36419833c97271315356d4320595eee8cc5119ee118bcdf1e2775bc52f;
        txProof[1] = 0x587b51946820bae3febac952ae82d0a10a2c1991bc887caf0c9831de2adb24bb;
        txProof[2] = 0xb6576b13bfbf97dae871a1b20d938a53329e10800ce093213abb811e236b7f6c;
        executeData.txProof = txProof;
        bytes32[] memory wlProof = new bytes32[](1);
        wlProof[0] = 0x7ceb58780fb137bb02223b79c88bc6404f736f8bb4d1f0895d9884122804fb73;
        executeData.wlProof = wlProof;
        executeData.data = Types.TransferData({
            from: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            to: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            amount: 1000000000000000,
            nonce: 17,
            timestamp: 1766392485,
            recipientCount: 1,
            batchId: 1,
            txType: Types.TxType.INSTANT
        });
    }
}
