// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IFeeModule} from "./interfaces/IFeeModule.sol";
import {Types} from "./libraries/Types.sol";
import {Errors} from "./libraries/Errors.sol";

/**
 * @title FeeModule
 * @notice Statistical fee calculation module
 * @dev ⚠️ IMPORTANT: This module does NOT collect actual fees
 *      All fee calculations are for UI/analytics display purposes only
 *      No TRX/tokens are transferred or deducted during fee application
 */
contract FeeModule is IFeeModule, Ownable {
    /// @dev Mapping of batch ID to transfer hash to fee amount paid
    mapping(bytes32 transferHash => uint256 fee) private s_transferFees;

    /// @dev Mapping of batch ID to total fees collected for that batch
    mapping(uint64 batchId => uint256 fee) private s_batchTotalFees;

    /// @dev Mapping of user address to their free transaction usage information
    mapping(address => Types.FreeTxInfo) private s_freeTxUsage;

    /* -------------------------------------------------------------------------- */
    /*                           STATE VARIABLES                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Total fees collected across all transactions
    uint256 private s_totalFees;

    /// @dev Address of the Settlement contract authorized to apply fees
    address private s_settlement;

    /// @dev Base fee for delayed transactions (0.1 TRX)
    uint256 private constant BASE_FEE = 100_000;

    /// @dev Fee per recipient for batched transactions (0.05 TRX)
    uint256 private constant BATCH_FEE = 50_000;

    /// @dev Fee for instant transactions (0.2 TRX)
    uint256 private constant INSTANT_FEE = 200_000;

    /// @dev Number of free transactions per day for eligible users
    uint256 private constant FREE_TX_AMOUNT = 10;

    /// @dev Volume threshold for large transactions (no fee applied)
    uint256 private constant LARGE_VOLUME = 1_000_000_000;

    /* -------------------------------------------------------------------------- */
    /*                               CONSTRUCTOR                                  */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Contract constructor
     * @dev Sets the deployer as the owner
     */
    constructor() Ownable(msg.sender) {}

    /* -------------------------------------------------------------------------- */
    /*                               FUNCTIONS                                    */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Calculates the fee for a transaction based on type and parameters
     * @dev Resets quota daily based on block.timestamp
     *      Users near day boundaries may access up to 20 transactions within a short window
     *      This is an accepted edge case to avoid complex timestamp tracking
     * @param sender Address initiating the transaction
     * @param txType Type of transaction (FREE_TIER, DELAYED, INSTANT, or BATCHED)
     * @param volume Transaction volume/amount
     * @param recipientCount Number of recipients (must be >1 for BATCHED, =1 for others)
     * @return info FeeInfo struct containing fee amount, transaction type, and remaining free quota
     */
    function calculateFee(address sender, Types.TxType txType, uint256 volume, uint256 recipientCount)
        external
        view
        returns (Types.FeeInfo memory info)
    {
        _validateCalculateFeeInput(sender, volume, recipientCount);
        _validateTxType(txType);
        _validateRecipientCount(txType, recipientCount);

        if (volume >= LARGE_VOLUME) {
            info.fee = 0;
            info.txType = txType;
            info.freeQuota = _getRemainingFreeTxQuota(sender);
            return info;
        }

        if (txType == Types.TxType.DELAYED || txType == Types.TxType.FREE_TIER) {
            return _calculateDelayedOrFreeFee(sender, txType);
        } else if (txType == Types.TxType.INSTANT) {
            return _calculateInstantFee(sender);
        } else if (txType == Types.TxType.BATCHED) {
            return _calculateBatchedFee(sender, recipientCount);
        }

        return info;
    }

    /**
     * @notice Applies the calculated fee to a transaction
     * @dev Can only be called by the authorized Settlement contract
     * @param sender Address initiating the transaction
     * @param fee Fee amount to apply
     * @param transferHash Unique hash of the transfer
     * @param batchId ID of the batch containing this transaction
     * @param txType Type of transaction being processed
     */
    function applyFee(address sender, uint256 fee, bytes32 transferHash, uint64 batchId, Types.TxType txType) external {
        if (sender == address(0) || transferHash == bytes32(0) || batchId == 0) {
            revert Errors.FeeModule__InvalidInput();
        }

        if (msg.sender != s_settlement) {
            revert Errors.FeeModule__NotAuthorized();
        }

        if (txType == Types.TxType.FREE_TIER) {
            _consumeFreeTxQuota(sender);
        }

        s_transferFees[transferHash] = fee;
        unchecked {
            s_batchTotalFees[batchId] += fee;
            s_totalFees += fee;
        }

        emit FeeApplied(sender, fee, transferHash, batchId);
    }

    /*   SETTERS   */

    /**
     * @notice Sets the Settlement contract address
     * @dev Can only be called by owner. Only this address can call applyFee
     * @param settlement Address of the Settlement contract
     */
    function setSettlement(address settlement) external onlyOwner {
        if (settlement == address(0)) {
            revert Errors.FeeModule__InvalidInput();
        }

        if (s_settlement == settlement) {
            revert Errors.FeeModule__AlreadySettlement();
        }

        s_settlement = settlement;

        emit SettlementUpdated(settlement);
    }

    /*   INTERNAL   */

    /**
     * @notice Validates basic input parameters for fee calculation
     * @param sender Address initiating the transaction
     * @param volume Transaction volume/amount
     * @param recipientCount Number of recipients
     */
    function _validateCalculateFeeInput(address sender, uint256 volume, uint256 recipientCount) internal pure {
        if (sender == address(0) || volume == 0 || recipientCount == 0) {
            revert Errors.FeeModule__InvalidInput();
        }
    }

    /**
     * @notice Validates transaction type is one of the allowed types
     * @param txType Type of transaction to validate
     */
    function _validateTxType(Types.TxType txType) internal pure {
        if (
            txType != Types.TxType.FREE_TIER && txType != Types.TxType.DELAYED && txType != Types.TxType.INSTANT
                && txType != Types.TxType.BATCHED
        ) {
            revert Errors.FeeModule__InvalidTxType();
        }
    }

    /**
     * @notice Validates recipient count matches transaction type requirements
     * @param txType Type of transaction
     * @param recipientCount Number of recipients
     */
    function _validateRecipientCount(Types.TxType txType, uint256 recipientCount) internal pure {
        if (txType == Types.TxType.BATCHED && recipientCount <= 1) {
            revert Errors.FeeModule__InvalidRecipientCount();
        }

        if (txType != Types.TxType.BATCHED && recipientCount > 1) {
            revert Errors.FeeModule__InvalidRecipientCount();
        }
    }

    /**
     * @notice Calculates fee for delayed or free tier transactions
     * @param sender Address initiating the transaction
     * @param txType Type of transaction (FREE_TIER or DELAYED)
     * @return info FeeInfo struct with fee details
     */
    function _calculateDelayedOrFreeFee(address sender, Types.TxType txType)
        internal
        view
        returns (Types.FeeInfo memory info)
    {
        uint256 remainingQuota = _getRemainingFreeTxQuota(sender);

        if (remainingQuota != 0) {
            info.fee = 0;
            info.txType = Types.TxType.FREE_TIER;
            info.freeQuota = remainingQuota;
        } else {
            if (txType == Types.TxType.FREE_TIER) {
                revert Errors.FeeModule__FreeTierLimitExceeded();
            }
            info.fee = BASE_FEE;
            info.txType = Types.TxType.DELAYED;
            info.freeQuota = 0;
        }
    }

    /**
     * @notice Calculates fee for instant transactions
     * @param sender Address initiating the transaction
     * @return info FeeInfo struct with fee details
     */
    function _calculateInstantFee(address sender) internal view returns (Types.FeeInfo memory info) {
        info.fee = INSTANT_FEE;
        info.txType = Types.TxType.INSTANT;
        info.freeQuota = _getRemainingFreeTxQuota(sender);
    }

    /**
     * @notice Calculates fee for batched transactions
     * @param sender Address initiating the transaction
     * @param recipientCount Number of recipients in the batch
     * @return info FeeInfo struct with fee details
     */
    function _calculateBatchedFee(address sender, uint256 recipientCount)
        internal
        view
        returns (Types.FeeInfo memory info)
    {
        info.fee = BATCH_FEE * recipientCount;
        info.txType = Types.TxType.BATCHED;
        info.freeQuota = _getRemainingFreeTxQuota(sender);
    }

    /**
     * @notice Internal function to get remaining free transaction quota for a user
     * @dev Resets quota daily based on block.timestamp
     *      Users near day boundaries may access up to 20 transactions within a short window
     *      This is an accepted edge case to avoid complex timestamp tracking
     * @param sender Address to check quota for
     * @return Remaining number of free transactions available
     */
    function _getRemainingFreeTxQuota(address sender) internal view returns (uint256) {
        Types.FreeTxInfo storage usage = s_freeTxUsage[sender];
        uint256 currentDay;
        unchecked {
            currentDay = block.timestamp / 1 days;
        }

        if (usage.day < currentDay) {
            return FREE_TX_AMOUNT;
        }

        if (usage.count < FREE_TX_AMOUNT) {
            unchecked {
                return FREE_TX_AMOUNT - usage.count;
            }
        }

        return 0;
    }

    /**
     * @notice Internal function to consume one free transaction from user's quota
     * @dev Updates daily counter and emits event. Reverts if quota exceeded
     * @param sender Address consuming the free transaction
     */
    function _consumeFreeTxQuota(address sender) internal {
        Types.FreeTxInfo storage usage = s_freeTxUsage[sender];
        uint256 currentDay;
        unchecked {
            currentDay = block.timestamp / 1 days;
        }

        if (usage.day < currentDay) {
            // Safe: days since epoch fits in uint128 for trillions of years
            if (currentDay > type(uint128).max) {
                revert Errors.FeeModule__InvalidInput();
            }
            usage.day = uint128(currentDay);
            usage.count = 0;
        }

        if (usage.count < FREE_TX_AMOUNT) {
            unchecked {
                usage.count += 1;
                uint256 remaining = FREE_TX_AMOUNT - usage.count;
                emit FreeTierUsed(sender, remaining);
            }
        } else {
            revert Errors.FeeModule__FreeTierLimitExceeded();
        }
    }

    /* -------------------------------------------------------------------------- */
    /*                              GETTERS                                       */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Returns the Settlement contract address
     * @return Address of the Settlement contract
     */
    function getSettlement() external view returns (address) {
        return s_settlement;
    }

    /**
     * @notice Returns the contract owner
     * @return Address of the owner
     */
    function getOwner() external view returns (address) {
        return owner();
    }

    /**
     * @notice Returns the free transaction usage info for a user
     * @param user Address to query
     * @return FreeTxInfo struct containing day and count
     */
    function getFreeTxUsage(address user) external view returns (Types.FreeTxInfo memory) {
        return s_freeTxUsage[user];
    }

    /**
     * @notice Returns the fee paid for a specific transaction
     * @param transferHash Hash of the transfer
     * @return fee Fee amount in wei
     */
    function getFeeOfTransaction(bytes32 transferHash) external view returns (uint256 fee) {
        return s_transferFees[transferHash];
    }

    /**
     * @notice Returns CALCULATED fees for statistical purposes only
     * @dev WARNING: Fees are NOT actually collected or transferred
     */
    function getTotalFeesCollected() external view returns (uint256 total) {
        return s_totalFees;
    }

    /**
     * @notice Returns total fees collected for a specific batch
     * @param batchId ID of the batch
     * @return total Total fees for the batch in wei
     */
    function getBatchTotalFees(uint64 batchId) external view returns (uint256 total) {
        return s_batchTotalFees[batchId];
    }

    /**
     * @notice Returns remaining free tier transactions for a user today
     * @param sender Address to query
     * @return remaining Number of free transactions remaining
     */
    function getRemainingFreeTierTransactions(address sender) external view returns (uint256 remaining) {
        Types.FreeTxInfo storage usage = s_freeTxUsage[sender];
        uint256 currentDay = block.timestamp / 1 days;

        uint256 count = usage.day < currentDay ? 0 : usage.count;
        return FREE_TX_AMOUNT > count ? FREE_TX_AMOUNT - count : 0;
    }
}
