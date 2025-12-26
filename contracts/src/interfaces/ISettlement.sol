// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Types} from "../libraries/Types.sol";

/**
 * @title ISettlement
 * @notice Interface for batch submission and verified transfer execution
 * @dev Admin setters must be access controlled
 */
interface ISettlement {
    /**
     * @notice Submit a batch by Merkle root
     * @dev Validates limits stores metadata emits BatchSubmitted
     * @param merkleRoot Batch root
     * @param txCount Transactions count
     * @param batchSalt Salt used by backend to build merkle root
     * @return success True if accepted
     * @return batchId Assigned ID
     */
    function submitBatch(bytes32 merkleRoot, uint32 txCount, uint64 batchSalt) external returns (bool, uint64);

    /**
     * @notice Execute a proven transfer
     * @dev Verifies txProof optional whitelistProof applies fees emits TransferExecuted
     * @param txProof Proof for txData
     * @param whitelistProof Proof for sender whitelist
     * @param txData Transfer data
     * @return success True if executed
     */
    function executeTransfer(
        bytes32[] calldata txProof,
        bytes32[] calldata whitelistProof,
        Types.TransferData memory txData
    ) external returns (bool);

    /**
     * @notice Approve aggregator
     * @dev Admin only Emits AggregatorApproved
     * @param aggregator Address to approve
     */
    function approveAggregator(address aggregator) external;

    /**
     * @notice Disapprove aggregator
     * @dev Admin only Emits AggregatorDisapproved
     * @param aggregator Address to disapprove
     */
    function disapproveAggregator(address aggregator) external;

    /**
     * @notice Pause the contract
     * @dev Admin only Prevents executeTransfer calls
     */
    function pause() external;

    /**
     * @notice Unpause the contract
     * @dev Admin only
     */
    function unpause() external;

    /**
     * @notice Set whitelist registry
     * @dev Admin only Emits WhitelistRegistryUpdated
     * @param whitelistRegistry Registry address
     */
    function setWhitelistRegistry(address whitelistRegistry) external;

    /**
     * @notice Set fee module
     * @dev Admin only Emits FeeModuleUpdated
     * @param feeModule Fee module address
     */
    function setFeeModule(address feeModule) external;

    /**
     * @notice Set max tx per batch
     * @dev Admin only Emits MaxTxPerBatchUpdated
     * @param maxTx New limit
     */
    function setMaxTxPerBatch(uint32 maxTx) external;

    /**
     * @notice Set timelock duration
     * @dev Admin only Emits TimelockDurationUpdated
     * @param duration Seconds
     */
    function setTimelockDuration(uint48 duration) external;

    /**
     * @notice Set token address
     * @dev Admin only Emits TokenUpdated
     * @param tokenAddress Token address
     */
    function setToken(address tokenAddress) external;

    /**
     * @notice Get owner
     * @return Address of owner
     */
    function getOwner() external view returns (address);

    /**
     * @notice Get whitelist registry
     * @return Address of registry
     */
    function getWhitelistRegistry() external view returns (address);

    /**
     * @notice Get fee module
     * @return Address of fee module
     */
    function getFeeModule() external view returns (address);

    /**
     * @notice Get token
     * @return Address of token
     */
    function getToken() external view returns (address);

    /**
     * @notice Get current batch ID
     * @return Current batch ID counter
     */
    function getCurrentBatchId() external view returns (uint64);

    /**
     * @notice Check approved aggregator
     * @param aggregator Address to check
     * @return True if approved
     */
    function isApprovedAggregator(address aggregator) external view returns (bool);

    /**
     * @notice Get max tx per batch
     * @return maxTx Limit
     */
    function getMaxTxPerBatch() external view returns (uint32);

    /**
     * @notice Get timelock duration
     * @return duration Seconds
     */
    function getTimelockDuration() external view returns (uint48);

    /**
     * @notice Get batch ID by root
     * @param rootHash Batch root
     * @return batchId ID
     */
    function getBatchIdByRoot(bytes32 rootHash) external view returns (uint64);

    /**
     * @notice Get batch by ID
     * @param batchId Batch ID
     * @return batch Stored metadata
     */
    function getBatchById(uint64 batchId) external view returns (Types.Batch memory);

    /**
     * @notice Check if transfer executed
     * @param transferHash Transfer hash
     * @return True if executed
     */
    function isExecutedTransfer(bytes32 transferHash) external view returns (bool);

    /**
     * @notice Get Merkle root by batch ID
     * @param batchId Batch ID
     * @return Merkle root of the batch
     */
    function getRootByBatchId(uint64 batchId) external view returns (bytes32);

    /**
     * @notice Check if contract is configured
     * @return True if configured
     */
    function isConfigured() external view returns (bool);

    /**
     * @notice Emitted on batch submission
     * @param batchId Assigned ID
     * @param merkleRoot Batch root
     * @param txCount Count
     * @param timestamp Block time
     */
    event BatchSubmitted(uint64 indexed batchId, bytes32 indexed merkleRoot, uint32 txCount, uint48 timestamp);

    /**
     * @notice Emitted on transfer execution
     * @param from Sender
     * @param to Recipient
     * @param amount Amount
     * @param nonce Nonce
     */
    event TransferExecuted(address indexed from, address indexed to, uint256 amount, uint64 nonce);

    /**
     * @notice Emitted on whitelist registry update
     * @param whitelistRegistry New address
     */
    event WhitelistRegistryUpdated(address indexed whitelistRegistry);

    /**
     * @notice Emitted on fee module update
     * @param feeModule New address
     */
    event FeeModuleUpdated(address indexed feeModule);

    /**
     * @notice Emitted on aggregator approval
     * @param aggregator Approved address
     */
    event AggregatorApproved(address indexed aggregator);

    /**
     * @notice Emitted on aggregator disapproval
     * @param aggregator Disapproved address
     */
    event AggregatorDisapproved(address indexed aggregator);

    /**
     * @notice Emitted on max tx per batch update
     * @param maxTx New limit
     */
    event MaxTxPerBatchUpdated(uint32 indexed maxTx);

    /**
     * @notice Emitted on timelock duration update
     * @param duration New seconds
     */
    event TimelockDurationUpdated(uint48 indexed duration);

    /**
     * @notice Emitted on token address update
     * @param tokenAddress New token
     */
    event TokenUpdated(address indexed tokenAddress);
}
