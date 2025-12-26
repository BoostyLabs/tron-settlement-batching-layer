// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISettlement} from "./interfaces/ISettlement.sol";
import {IFeeModule} from "./interfaces/IFeeModule.sol";
import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {Types} from "./libraries/Types.sol";
import {Errors} from "./libraries/Errors.sol";

/**
 * @title Settlement
 * @notice Contract for batch processing and execution of token transfers using Merkle Trees
 * @dev Uses Merkle proofs for transaction verification, timelock for security, and whitelist for access control
 */
contract Settlement is ISettlement, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* -------------------------------------------------------------------------- */
    /*                              TYPES                                         */
    /* -------------------------------------------------------------------------- */

    /// @dev Mapping of batch ID to batch data
    mapping(uint64 batchId => Types.Batch) private s_batches;

    /// @dev Mapping of Merkle root to batch ID for quick lookup
    mapping(bytes32 => uint64) private s_batchIdsByRoot;

    /// @dev Mapping of transaction hashes to execution status (prevents replay attacks)
    mapping(bytes32 txHash => bool executed) private s_executedTransfers;

    /// @dev Mapping of aggregator addresses to approval status
    mapping(address => bool) private s_approvedAggregators;

    /* -------------------------------------------------------------------------- */
    /*                             STATE VARIABLES                                */
    /* -------------------------------------------------------------------------- */

    /// @dev Module for calculating and applying fees
    IFeeModule private s_feeModule;

    /// @dev Whitelist registry for user verification
    IWhitelistRegistry private s_registry;

    /// @dev ERC20 token used for transfers
    IERC20 private s_token;

    /// @dev Batch ID counter
    uint64 private s_batchIds;

    /// @dev Maximum number of transactions per batch
    uint32 private s_maxTxPerBatch;

    /// @dev Timelock duration (delay before batch can be executed)
    uint48 private s_timelockDuration;

    /// @dev Configuration status
    bool private s_configured;

    /* -------------------------------------------------------------------------- */
    /*                               CONSTRUCTOR                                  */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Contract constructor
     * @dev Sets the deployer as owner and approved aggregator
     */
    constructor() Ownable(msg.sender) {
        s_approvedAggregators[msg.sender] = true;
    }

    /* -------------------------------------------------------------------------- */
    /*                             FUNCTIONS                                      */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Submits a new batch of transactions
     * @dev Can only be called by approved aggregators. Creates a new batch with timelock
     * @param merkleRoot The Merkle root of the transaction batch
     * @param txCount The number of transactions in the batch
     * @return success Boolean indicating success
     * @return batchId The ID of the created batch
     */
    function submitBatch(bytes32 merkleRoot, uint32 txCount, uint64 batchSalt) external returns (bool, uint64) {
        _requireConfigured();
        _onlyApprovedAggregator();

        if (merkleRoot == bytes32(0) || txCount == 0 || txCount > s_maxTxPerBatch) {
            revert Errors.Settlement__InvalidInput();
        }

        if (s_batchIdsByRoot[merkleRoot] != 0) {
            revert Errors.Settlement__BatchAlreadySubmitted();
        }

        if (block.timestamp > type(uint48).max) {
            revert Errors.Settlement__InvalidInput();
        }

        uint256 calculatedUnlockTime = block.timestamp + s_timelockDuration;
        if (calculatedUnlockTime > type(uint48).max) {
            revert Errors.Settlement__InvalidInput();
        }

        ++s_batchIds;
        uint64 batchId = s_batchIds;

        s_batches[batchId] = Types.Batch({
            merkleRoot: merkleRoot,
            // Safe: block.timestamp fits in uint48 until year ~8.9M AD
            timestamp: uint48(block.timestamp),
            txCount: txCount,
            // Safe: overflow checked above (line 106)
            unlockTime: uint48(calculatedUnlockTime),
            batchSalt: batchSalt
        });

        s_batchIdsByRoot[merkleRoot] = batchId;

        emit BatchSubmitted(batchId, merkleRoot, txCount, uint48(block.timestamp));
        return (true, batchId);
    }

    /**
     * @notice Executes a transfer from a submitted batch
     * @dev Verifies Merkle proof, whitelist status, and timelock before executing transfer
     * @param txProof Merkle proof for the transaction
     * @param whitelistProof Merkle proof for whitelist verification
     * @param txData Transfer data including from, to, amount, and other parameters
     * @return success Boolean indicating successful execution
     */
    function executeTransfer(
        bytes32[] memory txProof,
        bytes32[] memory whitelistProof,
        Types.TransferData memory txData
    ) external nonReentrant whenNotPaused returns (bool) {
        IFeeModule feeModule = s_feeModule;
        IERC20 token = s_token;

        _validateTransferInput(txData);
        _validateBatched(whitelistProof, txData);

        bytes32 txHash = _validateBatchAndProof(txProof, txData);

        Types.FeeInfo memory fee =
            feeModule.calculateFee(txData.from, txData.txType, txData.amount, txData.recipientCount);

        if (token.balanceOf(txData.from) < txData.amount) {
            revert Errors.Settlement__InsufficientBalance();
        }

        if (token.allowance(txData.from, address(this)) < txData.amount) {
            revert Errors.Settlement__InsufficientAllowance();
        }

        feeModule.applyFee(txData.from, fee.fee, txHash, txData.batchId, fee.txType);

        token.safeTransferFrom(txData.from, txData.to, txData.amount);
        s_executedTransfers[txHash] = true;

        emit TransferExecuted(txData.from, txData.to, txData.amount, txData.nonce);
        return true;
    }

    /**
     * @notice Approves a new aggregator
     * @dev Can only be called by owner
     * @param aggregator Address of the aggregator to approve
     */
    function approveAggregator(address aggregator) external onlyOwner {
        if (aggregator == address(0)) {
            revert Errors.Settlement__InvalidInput();
        }

        if (s_approvedAggregators[aggregator]) {
            revert Errors.Settlement__AlreadyAggregator();
        }

        s_approvedAggregators[aggregator] = true;
        emit AggregatorApproved(aggregator);
    }

    /**
     * @notice Removes approval from an aggregator
     * @dev Can only be called by owner
     * @param aggregator Address of the aggregator to disapprove
     */
    function disapproveAggregator(address aggregator) external onlyOwner {
        if (aggregator == address(0)) {
            revert Errors.Settlement__InvalidInput();
        }

        if (!s_approvedAggregators[aggregator]) {
            revert Errors.Settlement__AggregatorNotApproved();
        }

        s_approvedAggregators[aggregator] = false;
        emit AggregatorDisapproved(aggregator);
    }

    /**
     * @notice Pauses the contract
     * @dev Can only be called by owner. Prevents executeTransfer calls
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     * @dev Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /*   SETTERS   */

    /**
     * @notice Sets the whitelist registry address
     * @dev Can only be called by owner
     * @param whitelistRegistry Address of the whitelist registry contract
     */
    function setWhitelistRegistry(address whitelistRegistry) external onlyOwner {
        if (whitelistRegistry == address(0)) {
            revert Errors.Settlement__InvalidInput();
        }

        if (s_registry == IWhitelistRegistry(whitelistRegistry)) {
            revert Errors.Settlement__AlreadyRegistry();
        }

        s_registry = IWhitelistRegistry(whitelistRegistry);
        _recomputeConfigured();
        emit WhitelistRegistryUpdated(whitelistRegistry);
    }

    /**
     * @notice Sets the fee module address
     * @dev Can only be called by owner
     * @param feeModule Address of the fee module contract
     */
    function setFeeModule(address feeModule) external onlyOwner {
        if (feeModule == address(0)) {
            revert Errors.Settlement__InvalidInput();
        }

        if (s_feeModule == IFeeModule(feeModule)) {
            revert Errors.Settlement__AlreadyFeeModule();
        }

        s_feeModule = IFeeModule(feeModule);
        _recomputeConfigured();
        emit FeeModuleUpdated(feeModule);
    }

    /**
     * @notice Sets the maximum number of transactions per batch
     * @dev Can only be called by owner
     * @param maxTx Maximum transaction count
     */
    function setMaxTxPerBatch(uint32 maxTx) external onlyOwner {
        if (maxTx == 0) {
            revert Errors.Settlement__InvalidInput();
        }

        if (s_maxTxPerBatch == maxTx) {
            revert Errors.Settlement__AlreadySet();
        }

        s_maxTxPerBatch = maxTx;
        emit MaxTxPerBatchUpdated(maxTx);
    }

    /**
     * @notice Sets the timelock duration for batches
     * @dev Can only be called by owner. Duration in seconds
     * @param duration Timelock duration in seconds
     */
    function setTimelockDuration(uint48 duration) external onlyOwner {
        if (duration == s_timelockDuration) {
            revert Errors.Settlement__AlreadyTimelockDuration();
        }

        s_timelockDuration = uint48(duration);
        emit TimelockDurationUpdated(duration);
    }

    /**
     * @notice Sets the token address for transfers
     * @dev Can only be called by owner
     * @param tokenAddress Address of the ERC20 token contract
     */
    function setToken(address tokenAddress) external onlyOwner {
        if (tokenAddress == address(0)) {
            revert Errors.Settlement__InvalidInput();
        }

        if (s_token == IERC20(tokenAddress)) {
            revert Errors.Settlement__AlreadyToken();
        }

        s_token = IERC20(tokenAddress);
        _recomputeConfigured();
        emit TokenUpdated(tokenAddress);
    }

    /*   INTERNAL   */

    /**
     * @notice Internal function to check if caller is an approved aggregator
     * @dev Reverts if caller is not approved
     */
    function _onlyApprovedAggregator() internal view {
        if (!s_approvedAggregators[msg.sender]) {
            revert Errors.Settlement__AggregatorNotApproved();
        }
    }

    /**
     * @notice Validates if the transaction is batched and checks whitelist status
     * @param whitelistProof Merkle proof for whitelist verification
     * @param txData Transfer data structure
     */
    function _validateBatched(bytes32[] memory whitelistProof, Types.TransferData memory txData) internal view {
        if (txData.txType == Types.TxType.BATCHED) {
            if (whitelistProof.length == 0) {
                revert Errors.Settlement__NotWhitelisted();
            }

            if (!s_registry.verifyWhitelist(whitelistProof, txData.from)) {
                revert Errors.Settlement__NotWhitelisted();
            }
        }
    }

    /**
     * @notice Calculates the hash of a transfer
     * @dev Uses keccak256 to hash all transfer parameters including batchSalt
     * @param txData Transfer data structure
     * @param batchSalt Salt used by backend to build merkle root
     * @return txHash The calculated transaction hash
     */
    function _calculateTxHash(Types.TransferData memory txData, uint64 batchSalt)
        internal
        pure
        returns (bytes32 txHash)
    {
        txHash = keccak256(
            abi.encodePacked(
                txData.from,
                txData.to,
                txData.amount,
                txData.nonce,
                txData.timestamp,
                txData.recipientCount,
                txData.txType,
                batchSalt
            )
        );
    }

    /**
     * @notice Recomputes the configuration status of the contract
     * @dev Sets s_configured to true if all required modules are set
     */
    function _recomputeConfigured() internal {
        s_configured =
        (address(s_registry) != address(0) && address(s_feeModule) != address(0) && address(s_token) != address(0));
    }

    /**
     * @notice Ensures the contract is fully configured
     * @dev Reverts if not configured
     */
    function _requireConfigured() internal view {
        if (!s_configured) {
            revert Errors.Settlement__NotConfigured();
        }
    }

    /**
     * @notice Validates basic transfer inputs
     * @param txData Transfer data structure
     */
    function _validateTransferInput(Types.TransferData memory txData) internal view {
        _requireConfigured();

        if (txData.from == address(0) || txData.to == address(0) || txData.batchId == 0) {
            revert Errors.Settlement__InvalidInput();
        }
    }

    /**
     * @notice Validates batch and Merkle proof
     * @param txProof Merkle proof for the transaction
     * @param txData Transfer data structure
     * @return txHash The calculated transaction hash
     */
    function _validateBatchAndProof(bytes32[] memory txProof, Types.TransferData memory txData)
        internal
        view
        returns (bytes32 txHash)
    {
        Types.Batch storage batch = s_batches[txData.batchId];
        bytes32 merkleRoot = batch.merkleRoot;
        uint256 unlockTime = batch.unlockTime;
        uint64 batchSalt = batch.batchSalt;

        if (txProof.length == 0 || txData.amount == 0) {
            revert Errors.Settlement__InvalidInput();
        }

        if (merkleRoot == bytes32(0)) {
            revert Errors.Settlement__InvalidBatch();
        }

        if (block.timestamp < unlockTime) {
            revert Errors.Settlement__BatchLocked();
        }

        txHash = _calculateTxHash(txData, batchSalt);
        if (!MerkleProof.verify(txProof, merkleRoot, txHash)) {
            revert Errors.Settlement__InvalidMerkleProof();
        }

        if (s_executedTransfers[txHash]) {
            revert Errors.Settlement__TransferAlreadyExecuted();
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                              GETTERS                                       */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Returns the contract owner
     * @return Owner address
     */
    function getOwner() external view returns (address) {
        return owner();
    }

    /**
     * @notice Returns the whitelist registry address
     * @return Whitelist registry address
     */
    function getWhitelistRegistry() external view returns (address) {
        return address(s_registry);
    }

    /**
     * @notice Returns the fee module address
     * @return Fee module address
     */
    function getFeeModule() external view returns (address) {
        return address(s_feeModule);
    }

    /**
     * @notice Returns the token address
     * @return Token address
     */
    function getToken() external view returns (address) {
        return address(s_token);
    }

    /**
     * @notice Returns the current batch ID counter
     * @return Current batch ID
     */
    function getCurrentBatchId() external view returns (uint64) {
        return s_batchIds;
    }

    /**
     * @notice Returns the maximum transactions per batch
     * @return Maximum transaction count per batch
     */
    function getMaxTxPerBatch() external view returns (uint32) {
        return s_maxTxPerBatch;
    }

    /**
     * @notice Returns the timelock duration
     * @return Timelock duration in seconds
     */
    function getTimelockDuration() external view returns (uint48) {
        return s_timelockDuration;
    }

    /**
     * @notice Checks if an address is an approved aggregator
     * @param aggregator Address to check
     * @return True if approved, false otherwise
     */
    function isApprovedAggregator(address aggregator) external view returns (bool) {
        return s_approvedAggregators[aggregator];
    }

    /**
     * @notice Returns batch ID by Merkle root hash
     * @param rootHash Merkle root hash
     * @return Batch ID
     */
    function getBatchIdByRoot(bytes32 rootHash) external view returns (uint64) {
        if (rootHash == bytes32(0)) {
            revert Errors.Settlement__InvalidInput();
        }
        return s_batchIdsByRoot[rootHash];
    }

    /**
     * @notice Returns batch data by ID
     * @param batchId Batch ID
     * @return Batch data structure
     */
    function getBatchById(uint64 batchId) external view returns (Types.Batch memory) {
        return s_batches[batchId];
    }

    /**
     * @notice Checks if a transfer has been executed in a specific batch
     * @param transferHash Transfer hash
     * @return True if executed, false otherwise
     */
    function isExecutedTransfer(bytes32 transferHash) external view returns (bool) {
        return s_executedTransfers[transferHash];
    }

    /**
     * @notice Returns the Merkle root for a given batch ID
     * @param batchId Batch ID
     * @return Merkle root of the batch
     */
    function getRootByBatchId(uint64 batchId) external view returns (bytes32) {
        if (batchId == 0 || batchId > s_batchIds) {
            revert Errors.Settlement__InvalidInput();
        }
        return s_batches[batchId].merkleRoot;
    }

    /**
     * @notice Checks if the contract is fully configured
     * @return True if configured, false otherwise
     */
    function isConfigured() external view returns (bool) {
        return s_configured;
    }
}
