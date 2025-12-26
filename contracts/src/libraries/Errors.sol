// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title Errors
 * @notice Custom error definitions for the protocol
 * @dev Using custom errors instead of require strings saves gas
 */
library Errors {
    error WhitelistRegistry__NotAuthorized();
    error WhitelistRegistry__InsufficientFee();
    error WhitelistRegistry__RequestTooFrequent();
    error WhitelistRegistry__InvalidNonce();
    error WhitelistRegistry__WithdrawFailed();
    error WhitelistRegistry__InvalidInput();
    error WhitelistRegistry__AlreadyAuthorized();
    error WhitelistRegistry__DuplicateUpdate();
    error WhitelistRegistry__NothingToWithdraw();

    error FeeModule__InvalidInput();
    error FeeModule__InvalidRecipientCount();
    error FeeModule__FreeTierLimitExceeded();
    error FeeModule__InvalidTxType();
    error FeeModule__NotAuthorized();
    error FeeModule__AlreadySettlement();

    error Settlement__AggregatorNotApproved();
    error Settlement__InvalidInput();
    error Settlement__AlreadyRegistry();
    error Settlement__BatchLocked();
    error Settlement__BatchAlreadySubmitted();
    error Settlement__InvalidBatch();
    error Settlement__InvalidMerkleProof();
    error Settlement__AlreadyFeeModule();
    error Settlement__AlreadySet();
    error Settlement__AlreadyTimelockDuration();
    error Settlement__AlreadyToken();
    error Settlement__TransferAlreadyExecuted();
    error Settlement__NotWhitelisted();
    error Settlement__InsufficientBalance();
    error Settlement__InsufficientAllowance();
    error Settlement__AlreadyAggregator();
    error Settlement__NotConfigured();
    error Settlement__InsufficientAllowance();
}
