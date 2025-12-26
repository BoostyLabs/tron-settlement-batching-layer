// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title IWhitelistRegistry
 * @notice Registry used to manage and verify a Merkle-tree based whitelist
 * @dev Implementations should allow updating the merkle root (with authorization)
 *      and enable verification/requests against the stored root
 */
interface IWhitelistRegistry {
    /**
     * @notice Update the Merkle root used for whitelist proofs
     * @dev A signature or other authorization proof may be supplied to prove the
     *      caller is allowed to update the root (implementation-specific)
     * @param newRoot New Merkle root to set
     * @param signature Authorization signature or proof for the update (implementation-specific)
     */
    function updateMerkleRoot(bytes32 newRoot, uint64 nonce, bytes calldata signature) external;

    /**
     * @notice Request whitelist access (implementation may emit an event)
     * @dev Implementations may require additional off-chain verification or queueing logic
     * @return success True if the request was accepted
     */
    function requestWhitelist() external payable returns (bool success);

    /**
     * @notice Withdraw accumulated funds from the contract
     * @dev Caller must have appropriate permissions (implementation-specific)
     */
    function withdraw() external;

    /**
     * @notice Add an authorized updater
     * @dev Admin only Emits AuthorizedUpdaterAdded
     * @param updater Address to authorize
     */
    function addAuthorizedUpdater(address updater) external;

    /**
     * @notice Remove an authorized updater
     * @dev Admin only Emits AuthorizedUpdaterRemoved
     * @param updater Address to remove authorization
     */
    function removeAuthorizedUpdater(address updater) external;

    /**
     * @notice Pause the contract
     * @dev Admin only
     */
    function pause() external;

    /**
     * @notice Unpause the contract
     * @dev Admin only
     */
    function unpause() external;

    /**
     * @notice Get the currently active Merkle root used for whitelist verification
     * @return root Current Merkle root
     */
    function getCurrentMerkleRoot() external view returns (bytes32 root);

    /**
     * @notice Verify whether a given user is included in the whitelist
     * @param proof Merkle proof (array of sibling hashes) proving inclusion
     * @param user Address to verify
     * @return valid True if the user is included according to the current merkle root
     */
    function verifyWhitelist(bytes32[] calldata proof, address user) external view returns (bool valid);

    /**
     * @notice Get total collected fees
     * @return Total fees collected
     */
    function getTotalCollectedFees() external view returns (uint128);

    /**
     * @notice Get last update time
     * @return Last update timestamp
     */
    function getLastUpdateTime() external view returns (uint48);

    /**
     * @notice Get current nonce
     * @return Current nonce value
     */
    function getCurrentNonce() external view returns (uint64);

    /**
     * @notice Check if address is authorized updater
     * @param updater Address to check
     * @return True if authorized
     */
    function isAuthorizedUpdater(address updater) external view returns (bool);

    /**
     * @notice Get last requested time for a requester
     * @param requester Address to check
     * @return Last request timestamp
     */
    function getLastRequestedTime(address requester) external view returns (uint48);

    /**
     * @notice Get request cooldown period
     * @return Cooldown duration in seconds
     */
    function getRequestCooldown() external pure returns (uint256);

    /**
     * @notice Get request fee amount
     * @return Fee amount required for requests
     */
    function getRequestFee() external pure returns (uint256);

    /**
     * @notice Get withdraw role identifier
     * @return Withdraw role bytes32 identifier
     */
    function getWithdrawRole() external pure returns (bytes32);

    /**
     * @notice Get default admin role identifier
     * @return Default admin role bytes32 identifier
     */
    function getDefaultAdminRole() external pure returns (bytes32);

    /**
     * @notice Check if account has admin role
     * @param account Address to check
     * @return True if account is admin
     */
    function isAdmin(address account) external view returns (bool);

    /**
     * @notice Check if account has withdraw role
     * @param account Address to check
     * @return True if account can withdraw
     */
    function isWithdrawer(address account) external view returns (bool);

    /**
     * @notice Emitted when the whitelist Merkle root is updated
     * @param oldRoot The previous Merkle root
     * @param newRoot The new Merkle root that was set
     * @param nonce The nonce used in the update
     */
    event WhitelistUpdated(bytes32 oldRoot, bytes32 newRoot, uint64 nonce);

    /**
     * @notice Emitted when an address requests to be added to the whitelist
     * @param requester Address that requested whitelist access
     */
    event WhitelistRequested(address indexed requester);

    /**
     * @notice Emitted when funds are withdrawn from the contract
     * @param requester Address that initiated the withdrawal
     * @param amount Amount of funds withdrawn
     */
    event WithdrawSuccess(address indexed requester, uint256 amount);
    /**
     * @notice Emitted when a new authorized updater is added
     * @param updater Address of the authorized updater added
     */
    event AuthorizedUpdaterAdded(address indexed updater);

    /**
     * @notice Emitted when an authorized updater is removed
     * @param updater Address of the authorized updater removed
     */
    event AuthorizedUpdaterRemoved(address indexed updater);
}
