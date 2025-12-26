// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Settlement} from "../../src/Settlement.sol";
import {ISettlement} from "../../src/interfaces/ISettlement.sol";

import {TestConstants as TC} from "../utils/TestConstants.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract SettlementUnitTest is Test {
    Settlement settlement;
    address feeModule;
    address registry;
    address recipient;
    address token;
    address user;
    address owner;

    function setUp() public {
        owner = makeAddr("owner");
        feeModule = makeAddr("feeModule");
        registry = makeAddr("registry");
        recipient = makeAddr("recipient");
        token = makeAddr("token");
        user = makeAddr("user");

        vm.startPrank(owner);

        settlement = new Settlement();
        settlement.setWhitelistRegistry(registry);
        settlement.setFeeModule(feeModule);
        settlement.setToken(token);

        settlement.setMaxTxPerBatch(uint32(TC.MAX_TX_PER_BATCH));
        settlement.setTimelockDuration(uint48(TC.TIMELOCK_DURATION));
        vm.stopPrank();
    }

    /* -------------------------------------------------------------------------- */
    /*                             HELPERS                                        */
    /* -------------------------------------------------------------------------- */

    function _createBatchData() internal pure returns (bytes32 merkleRoot, uint32 txCount) {
        merkleRoot = keccak256(abi.encodePacked("merkle root"));
        txCount = uint32(TC.MAX_TX_PER_BATCH);
    }

    function _createTransferData() internal view returns (Types.TransferData memory) {
        Types.TransferData memory txData = Types.TransferData({
            from: user,
            to: recipient,
            amount: 1000,
            nonce: 1,
            timestamp: uint48(block.timestamp),
            recipientCount: 1,
            batchId: 0,
            txType: Types.TxType.DELAYED
        });
        return txData;
    }

    function _createMerkleProofs()
        internal
        pure
        returns (bytes32[] memory validTxProof, bytes32[] memory validWhitelistProof)
    {
        validTxProof = new bytes32[](3);
        validTxProof[0] = keccak256(abi.encodePacked("tx proof 1"));
        validTxProof[1] = keccak256(abi.encodePacked("tx proof 2"));
        validTxProof[2] = keccak256(abi.encodePacked("tx proof 3"));

        validWhitelistProof = new bytes32[](3);
        validWhitelistProof[0] = keccak256(abi.encodePacked("whitelist proof 1"));
        validWhitelistProof[1] = keccak256(abi.encodePacked("whitelist proof 2"));
        validWhitelistProof[2] = keccak256(abi.encodePacked("whitelist proof 3"));
    }

    /* -------------------------------------------------------------------------- */
    /*                             INITIAL STATE                                  */
    /* -------------------------------------------------------------------------- */

    function test_Constructor_InitialValues() public view {
        assertEq(settlement.getWhitelistRegistry(), address(registry));
        assertEq(settlement.getFeeModule(), address(feeModule));
        assertEq(settlement.getToken(), address(token));
        assertEq(settlement.getMaxTxPerBatch(), TC.MAX_TX_PER_BATCH);
        assertEq(settlement.getTimelockDuration(), TC.TIMELOCK_DURATION);
        assertTrue(settlement.isConfigured());
    }

    function test_IsConfigured() public {
        Settlement unconfiguredSettlement = new Settlement();
        assertFalse(unconfiguredSettlement.isConfigured());

        unconfiguredSettlement.setWhitelistRegistry(registry);
        unconfiguredSettlement.setFeeModule(feeModule);
        unconfiguredSettlement.setToken(token);

        assertTrue(unconfiguredSettlement.isConfigured());
    }

    /* -------------------------------------------------------------------------- */
    /*                            submitBatch                                     */
    /* -------------------------------------------------------------------------- */

    function test_SubmitBatch_AggregatorNotApproved() public {
        (bytes32 merkleRoot, uint256 txCount) = _createBatchData();

        vm.prank(user);
        vm.expectRevert(Errors.Settlement__AggregatorNotApproved.selector);
        settlement.submitBatch(merkleRoot, uint32(txCount), 1);
    }

    function test_SubmitBatch_InvalidInput() public {
        (bytes32 merkleRoot, uint32 txCount) = _createBatchData();
        uint32 zeroTxCount = 0;
        bytes32 zeroMerkleRoot = bytes32(0);

        vm.startPrank(owner);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(zeroMerkleRoot, txCount, 1);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(merkleRoot, zeroTxCount, 1);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(merkleRoot, txCount + 1, 1);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(zeroMerkleRoot, zeroTxCount, 1);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.submitBatch(zeroMerkleRoot, txCount + 1, 1);

        vm.stopPrank();
    }

    function test_SubmitBatch_AlreadySubmitted() public {
        (bytes32 merkleRoot, uint32 txCount) = _createBatchData();

        vm.startPrank(owner);
        settlement.submitBatch(merkleRoot, txCount, 1);

        vm.expectRevert(Errors.Settlement__BatchAlreadySubmitted.selector);
        settlement.submitBatch(merkleRoot, txCount, 1);

        vm.stopPrank();
    }

    function test_SubmitBatch_SuccessAndEmits() public {
        uint256 initialBatchId = settlement.getCurrentBatchId();
        assertEq(initialBatchId, 0);
        (bytes32 merkleRoot, uint32 txCount) = _createBatchData();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ISettlement.BatchSubmitted(1, merkleRoot, txCount, uint48(block.timestamp));

        (bool success, uint64 returnedBatchId) = settlement.submitBatch(merkleRoot, txCount, 1);

        assertTrue(success);
        assertEq(returnedBatchId, 1);

        uint256 newBatchId = settlement.getCurrentBatchId();

        Types.Batch memory submittedBatch = settlement.getBatchById(uint64(newBatchId));
        assertEq(newBatchId, initialBatchId + 1);
        assertEq(submittedBatch.merkleRoot, merkleRoot);
        assertEq(submittedBatch.txCount, txCount);
        assertEq(submittedBatch.timestamp, block.timestamp);
        assertEq(submittedBatch.unlockTime, block.timestamp + settlement.getTimelockDuration());

        assertEq(settlement.getBatchIdByRoot(merkleRoot), newBatchId);
    }

    /* -------------------------------------------------------------------------- */
    /*                          executeTransfer                                   */
    /* -------------------------------------------------------------------------- */

    function test_ExecuteTransfer_NotConfigured() public {
        Settlement unconfiguredSettlement = new Settlement();

        (bytes32[] memory txProof, bytes32[] memory whitelistProof) = _createMerkleProofs();
        Types.TransferData memory txData = _createTransferData();

        vm.expectRevert(Errors.Settlement__NotConfigured.selector);
        unconfiguredSettlement.executeTransfer(txProof, whitelistProof, txData);
    }

    function test_ExecuteTransfer_InvalidInput() public {
        bytes32[] memory invalidTxProof = new bytes32[](0);
        bytes32[] memory invalidWhitelistProof = new bytes32[](0);

        (bytes32[] memory validTxProof, bytes32[] memory validWhitelistProof) = _createMerkleProofs();
        Types.TransferData memory txData = _createTransferData();

        // invalid txProof
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.executeTransfer(invalidTxProof, validWhitelistProof, txData);

        // invalid whitelistProof
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.executeTransfer(validTxProof, invalidWhitelistProof, txData);

        // invalid both
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.executeTransfer(invalidTxProof, invalidWhitelistProof, txData);

        // zero batch
        txData.batchId = 0;
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.executeTransfer(validTxProof, validWhitelistProof, txData);

        // zero amount
        txData.amount = 0;
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.executeTransfer(validTxProof, validWhitelistProof, txData);
    }

    function test_ExecuteTransfer_InvalidTxData() public {
        (bytes32[] memory txProof, bytes32[] memory whitelistProof) = _createMerkleProofs();

        Types.TransferData memory invalidFromData = _createTransferData();
        invalidFromData.from = address(0);

        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.executeTransfer(txProof, whitelistProof, invalidFromData);

        Types.TransferData memory invalidToData = _createTransferData();
        invalidToData.to = address(0);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.executeTransfer(txProof, whitelistProof, invalidToData);

        Types.TransferData memory invalidData = _createTransferData();
        invalidData.from = address(0);
        invalidData.to = address(0);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.executeTransfer(txProof, whitelistProof, invalidData);
    }

    // Settlement__InvalidBatch
    function test_ExecuteTransfer_InvalidBatch() public {
        (bytes32[] memory txProof, bytes32[] memory whitelistProof) = _createMerkleProofs();

        Types.TransferData memory txData = _createTransferData();
        txData.batchId = 999;

        vm.expectRevert(Errors.Settlement__InvalidBatch.selector);
        settlement.executeTransfer(txProof, whitelistProof, txData);
    }

    // Settlement__BatchLocked
    function test_ExecuteTransfer_BatchLocked() public {
        (bytes32 merkleRoot, uint32 txCount) = _createBatchData();

        vm.prank(owner);
        settlement.submitBatch(merkleRoot, txCount, 1);

        (bytes32[] memory txProof, bytes32[] memory whitelistProof) = _createMerkleProofs();

        Types.TransferData memory txData = _createTransferData();
        txData.batchId = 1;

        vm.expectRevert(Errors.Settlement__BatchLocked.selector);
        settlement.executeTransfer(txProof, whitelistProof, txData);
    }

    /* -------------------------------------------------------------------------- */
    /*                        approveAggregator                                   */
    /* -------------------------------------------------------------------------- */

    function test_ApproveAggregator_InvalidInput() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.approveAggregator(address(0));
    }

    function test_ApproveAggregator_AlreadyAggregator() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__AlreadyAggregator.selector);
        settlement.approveAggregator(owner);
    }

    function test_ApproveAggregator_ApprovesAndEmits() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ISettlement.AggregatorApproved(user);
        settlement.approveAggregator(user);

        bool isApproved = settlement.isApprovedAggregator(user);
        assertTrue(isApproved);
    }

    /* -------------------------------------------------------------------------- */
    /*                     disapproveAggregator                                   */
    /* -------------------------------------------------------------------------- */

    function test_DisapproveAggregator_InvalidInput() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.disapproveAggregator(address(0));
    }

    function test_DisapproveAggregator_NotAggregator() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__AggregatorNotApproved.selector);
        settlement.disapproveAggregator(user);
    }

    function test_DisapproveAggregator_DisapprovesAndEmits() public {
        vm.prank(owner);
        settlement.approveAggregator(user);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ISettlement.AggregatorDisapproved(user);
        settlement.disapproveAggregator(user);

        bool isApproved = settlement.isApprovedAggregator(user);
        assertFalse(isApproved);
    }

    /*                              onlyOwner                                     */

    function test_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settlement.approveAggregator(user);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settlement.setWhitelistRegistry(registry);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settlement.setFeeModule(feeModule);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settlement.setMaxTxPerBatch(1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settlement.setTimelockDuration(1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        settlement.setToken(token);
    }

    /* -------------------------------------------------------------------------- */
    /*                            pause/unpause                                   */
    /* -------------------------------------------------------------------------- */

    function test_PauseUnpause_NotAuthorized() public {
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user, settlement.getOwner())
        );
        settlement.pause();

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user, settlement.getOwner())
        );
        settlement.unpause();
        vm.stopPrank();
    }

    function test_PauseUnpause_Success() public {
        vm.prank(owner);
        settlement.pause();
        assertTrue(settlement.paused());

        vm.prank(owner);
        settlement.unpause();
        assertFalse(settlement.paused());
    }

    function test_ExecuteTransfer_EnforcedPause() public {
        vm.prank(owner);
        settlement.pause();

        (bytes32[] memory txProof, bytes32[] memory whitelistProof) = _createMerkleProofs();
        Types.TransferData memory txData = _createTransferData();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        settlement.executeTransfer(txProof, whitelistProof, txData);
    }

    /* -------------------------------------------------------------------------- */
    /*                               SETTERS                                      */
    /* -------------------------------------------------------------------------- */

    /*                        setWhitelistRegistry                                */

    function test_SetWhitelistRegistry_InvalidInput() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.setWhitelistRegistry(address(0));
    }

    function test_SetWhitelistRegistry_AlreadyRegistry() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__AlreadyRegistry.selector);
        settlement.setWhitelistRegistry(registry);
    }

    function test_SetWhitelistRegistry_SetsAndEmits() public {
        address newRegistry = makeAddr("newRegistry");
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ISettlement.WhitelistRegistryUpdated(newRegistry);
        settlement.setWhitelistRegistry(newRegistry);

        address actual = settlement.getWhitelistRegistry();
        assertEq(actual, newRegistry);
    }

    /*                         setFeeModule                                      */

    function test_SetFeeModule_InvalidInput() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.setFeeModule(address(0));
    }

    function test_SetFeeModule_AlreadyFeeModule() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__AlreadyFeeModule.selector);
        settlement.setFeeModule(feeModule);
    }

    function test_SetFeeModule_SetsAndEmits() public {
        address newFeeModule = makeAddr("newFeeModule");
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ISettlement.FeeModuleUpdated(newFeeModule);
        settlement.setFeeModule(newFeeModule);

        address actual = settlement.getFeeModule();
        assertEq(actual, newFeeModule);
    }

    /*                         setMaxTxPerBatch                                      */

    function test_SetMaxTxPerBatch_InvalidInput() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.setMaxTxPerBatch(0);
    }

    function test_SetMaxTxPerBatch_AlreadySet() public {
        vm.prank(owner);
        settlement.setMaxTxPerBatch(100);

        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__AlreadySet.selector);
        settlement.setMaxTxPerBatch(100);
    }

    function test_SetMaxTxPerBatch_SetsAndEmits() public {
        uint32 maxTx = 150;

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ISettlement.MaxTxPerBatchUpdated(maxTx);
        settlement.setMaxTxPerBatch(uint32(maxTx));

        uint32 actual = settlement.getMaxTxPerBatch();
        assertEq(actual, maxTx);
    }

    /*                         setTimelockDuration                                      */

    function test_SetTimelockDuration_AllowZero() public {
        vm.startPrank(owner);
        settlement.setTimelockDuration(1);
        settlement.setTimelockDuration(0);
        vm.stopPrank();

        uint256 actual = settlement.getTimelockDuration();
        assertEq(actual, 0);
    }

    function test_SetTimelockDuration_AlreadyTimelock_Zero() public {
        vm.prank(owner);
        settlement.setTimelockDuration(0);

        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__AlreadyTimelockDuration.selector);
        settlement.setTimelockDuration(0);
    }

    function test_SetTimelockDuration_AlreadyTimelock() public {
        vm.startPrank(owner);

        vm.expectRevert(Errors.Settlement__AlreadyTimelockDuration.selector);
        settlement.setTimelockDuration(uint32(TC.TIMELOCK_DURATION));

        settlement.setTimelockDuration(600);

        vm.expectRevert(Errors.Settlement__AlreadyTimelockDuration.selector);
        settlement.setTimelockDuration(600);

        vm.stopPrank();
    }

    function test_SetTimelockDuration_SetsAndEmits() public {
        uint48 duration = 600;
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ISettlement.TimelockDurationUpdated(duration);
        settlement.setTimelockDuration(duration);

        uint48 actual = settlement.getTimelockDuration();
        assertEq(actual, duration);
    }

    /*                         setToken                                          */

    function test_SetToken_InvalidInput() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.setToken(address(0));
    }

    function test_SetToken_AlreadyToken() public {
        vm.prank(owner);
        vm.expectRevert(Errors.Settlement__AlreadyToken.selector);
        settlement.setToken(token);
    }

    function test_SetToken_SetsAndEmits() public {
        address newToken = makeAddr("newToken");

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ISettlement.TokenUpdated(newToken);
        settlement.setToken(newToken);

        address actual = settlement.getToken();
        assertEq(actual, newToken);
    }

    /* -------------------------------------------------------------------------- */
    /*                               GETTERS                                      */
    /* -------------------------------------------------------------------------- */

    function test_AllGetters() public {
        assertEq(settlement.getOwner(), owner);

        // getBatchIdByHash root==0
        vm.expectRevert(Errors.Settlement__InvalidInput.selector);
        settlement.getBatchIdByRoot(bytes32(0));

        vm.prank(owner);
        address newAggregator = address(0xBEEF);
        settlement.approveAggregator(newAggregator);
        assertTrue(settlement.isApprovedAggregator(newAggregator));

        vm.prank(owner);
        settlement.disapproveAggregator(newAggregator);
        assertFalse(settlement.isApprovedAggregator(newAggregator));

        vm.prank(owner);
        bytes32 root = keccak256("root");
        (bool ok, uint256 batchId) = settlement.submitBatch(root, 3, 1);
        assertTrue(ok);

        assertEq(settlement.getCurrentBatchId(), batchId);
        assertEq(settlement.getBatchIdByRoot(root), batchId);
        assertEq(settlement.getRootByBatchId(uint64(batchId)), root);

        Types.Batch memory batch = settlement.getBatchById(uint64(batchId));
        assertEq(batch.merkleRoot, root);
        assertEq(batch.txCount, 3);
        assertEq(batch.timestamp, block.timestamp);
        assertEq(batch.unlockTime, block.timestamp + settlement.getTimelockDuration());

        Types.TransferData memory txData = Types.TransferData({
            from: address(this),
            to: address(0x1234),
            amount: 1,
            nonce: 1,
            timestamp: uint48(block.timestamp),
            recipientCount: 1,
            batchId: uint64(batchId),
            txType: Types.TxType.DELAYED
        });

        bytes32 txHash = keccak256(
            abi.encodePacked(
                txData.from,
                txData.to,
                txData.amount,
                txData.nonce,
                txData.timestamp,
                txData.recipientCount,
                txData.txType
            )
        );

        assertFalse(settlement.isExecutedTransfer(txHash));
    }
}
