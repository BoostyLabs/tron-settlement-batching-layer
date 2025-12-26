// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Types} from "../libraries/Types.sol";

/**
 * @title IFeeModule
 * @notice Interface for fee calculation and application used by the settlement layer
 * @dev Implementations should track fees per transfer and optionally a free-tier allowance
 */
interface IFeeModule {
    /**
     * @notice Calculate fee for a transaction and return details in a struct
     * @param sender The address initiating the transfer
     * @param txType The type of transaction (see Types.TxType)
     * @param volume The volume of the transfer (used for volume-based fees)
     * @param recipientCount Number of recipients for batched transfers (1 for single transfers)
     * @return info A FeeInfo containing the fee and related info
     */
    function calculateFee(address sender, Types.TxType txType, uint256 volume, uint256 recipientCount)
        external
        view
        returns (Types.FeeInfo memory info);

    /**
     * @notice Apply a previously calculated fee to a transfer
     * @param sender The address paying the fee
     * @param fee Fee amount to apply (in wei / smallest token unit)
     * @param transferHash Unique hash identifying the transfer
     * @param batchId Batch identifier
     * @param txType The type of transaction (see Types.TxType)
     */
    function applyFee(address sender, uint256 fee, bytes32 transferHash, uint64 batchId, Types.TxType txType) external;

    /**
     * @notice Set the Settlement contract address
     * @param settlement Address of the Settlement contract
     */
    function setSettlement(address settlement) external;

    /**
     * @notice Get the fee applied to a specific transfer
     * @param transferHash Unique hash identifying the transfer
     * @return fee The fee previously applied to the given transfer
     */
    function getFeeOfTransaction(bytes32 transferHash) external view returns (uint256 fee);

    /**
     * @notice Get total fees collected by the module
     * @notice Returns CALCULATED fees for statistical purposes only
     * @dev WARNING: Fees are NOT actually collected or transferred
     */
    function getTotalFeesCollected() external view returns (uint256 total);

    /**
     * @notice Get remaining number of free-tier transactions for a given sender
     * @param sender Address to query
     * @return remaining Number of free-tier transactions remaining
     */
    function getRemainingFreeTierTransactions(address sender) external view returns (uint256 remaining);

    /**
     * @notice Get the Settlement contract address
     * @return Address of the Settlement contract
     */
    function getSettlement() external view returns (address);

    /**
     * @notice Get the contract owner
     * @return Address of the owner
     */
    function getOwner() external view returns (address);

    /**
     * @notice Get the free transaction usage info for a user
     * @param user Address to query
     * @return FreeTxInfo struct containing day and count
     */
    function getFreeTxUsage(address user) external view returns (Types.FreeTxInfo memory);

    /**
     * @notice Get total fees collected for a specific batch
     * @param batchId ID of the batch
     * @return total Total fees for the batch in wei
     */
    function getBatchTotalFees(uint64 batchId) external view returns (uint256 total);

    /**
     * @notice Emitted when a fee is applied to a transfer
     * @param sender The address who paid the fee
     * @param fee The fee amount applied
     * @param transferHash Transfer identifier for which the fee was applied
     * @param batchId Batch identifier if this was part of a batched transfer
     */
    event FeeApplied(address indexed sender, uint256 fee, bytes32 transferHash, uint64 batchId);

    /**
     * @notice Emitted when a free-tier allowance is consumed
     * @param sender The address that used a free-tier transaction
     * @param remainingFreeTx Remaining free-tier transactions after use
     */
    event FreeTierUsed(address indexed sender, uint256 remainingFreeTx);

    /**
     * @notice Emitted when the settlement contract address is updated
     * @param settlement The new settlement contract address
     */
    event SettlementUpdated(address indexed settlement);
}
