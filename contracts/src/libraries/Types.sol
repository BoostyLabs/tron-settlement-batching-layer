// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title Types
 * @notice Core types and data structures used across the protocol
 */
library Types {
    /**
     * @notice Transaction processing modes that determine fee calculation
     * @dev Single-recipient: DELAYED (standard), INSTANT (premium)
     *      Multi-recipient: BATCHED (per-recipient fee)
     *      Special: FREE_TIER (limited daily quota)
     */
    enum TxType {
        DELAYED, // Standard processing with lower fee
        INSTANT, // Premium processing with higher fee
        BATCHED, // Multi-recipient with per-recipient fee
        FREE_TIER // Uses daily free transaction quota
    }

    /**
     * @notice Fee calculation result
     * @param fee Amount in smallest token unit (e.g., wei/sun)
     * @param txType Actual transaction type applied
     * @param freeQuota Remaining free transactions for the day
     */
    struct FeeInfo {
        uint256 fee;
        TxType txType;
        uint256 freeQuota;
    }

    /**
     * @notice Free-tier transaction usage tracking
     * @param count Number of free transactions used today
     * @param day Last day (timestamp) when free transactions were used
     */
    struct FreeTxInfo {
        uint128 count;
        uint128 day;
    }

    /**
     * @notice Batch processing information
     */
    struct Batch {
        bytes32 merkleRoot; // Root of merkle tree containing transactions
        uint48 timestamp; // Batch creation time
        uint32 txCount; // Number of transactions in batch
        uint48 unlockTime; // Time when batch can be processed
        uint64 batchSalt; // Salt used by backend to build merkle root
    }

    /**
     * @notice Individual transfer details
     */
    struct TransferData {
        address from; // Sender address
        address to; // Recipient address
        uint256 amount; // Transfer amount
        uint64 nonce; // Unique identifier per sender
        uint48 timestamp; // Transfer initiation time
        uint32 recipientCount; // Number of recipients (used for BATCHED fee calc)
        uint64 batchId; // Batch identifier
        TxType txType; // Processing mode
    }
}
