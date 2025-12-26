// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {Errors} from "./libraries/Errors.sol";

/**
 * @title WhitelistRegistry
 * @notice Contract for managing whitelisted addresses for batched transfers using Merkle tree verification
 * @dev Uses ECDSA signatures for authorized updates, role-based access control, and collects fees for whitelist requests
 */
contract WhitelistRegistry is AccessControl, IWhitelistRegistry, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using MerkleProof for bytes32[];

    /* -------------------------------------------------------------------------- */
    /*                             TYPES                                          */
    /* -------------------------------------------------------------------------- */

    mapping(address => bool) private s_authorizedUpdaters;
    mapping(address => uint48) private s_lastRequestedTime;

    /* -------------------------------------------------------------------------- */
    /*                            STATE VARIABLES                                 */
    /* -------------------------------------------------------------------------- */

    bytes32 private s_merkleRoot;
    // Packed into single slot (saves 2 storage slots):
    uint128 private s_totalCollectedFees; // Max: 3.4×10^32 TRX - safe for trillions of years
    uint64 private s_nonce; // Max: 18 quintillion updates - more than sufficient
    uint48 private s_lastUpdate; // Timestamp - safe until year ~8.9M AD
    uint256 private constant REQUEST_COOLDOWN = 24 hours;
    uint256 private constant REQUEST_FEE = 10e6; // 10 TRX

    bytes32 private constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    /* -------------------------------------------------------------------------- */
    /*                              CONSTRUCTOR                                   */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Contract constructor
     * @dev Sets up initial admin and updater roles for the specified address
     * @param updater Address to grant admin, withdraw, and updater roles
     */
    constructor(address updater) {
        if (updater == address(0)) {
            revert Errors.WhitelistRegistry__InvalidInput();
        }
        _setRoleAdmin(WITHDRAW_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, updater);
        _grantRole(WITHDRAW_ROLE, updater);
        s_authorizedUpdaters[updater] = true;
    }

    /* -------------------------------------------------------------------------- */
    /*                              FUNCTIONS                                     */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Updates the Merkle root for the whitelist
     * @dev Requires valid signature from authorized updater. Increments nonce after successful update
     * @param newRoot New Merkle root hash
     * @param nonce The next nonce value (must match contract state after update)
     * @param signature ECDSA signature from authorized updater
     */
    function updateMerkleRoot(bytes32 newRoot, uint64 nonce, bytes calldata signature) external whenNotPaused {
        bytes32 oldRoot = s_merkleRoot;

        if (newRoot == s_merkleRoot) {
            revert Errors.WhitelistRegistry__DuplicateUpdate();
        }

        _onlyAuthorizedUpdater(newRoot, nonce, signature);
        s_merkleRoot = newRoot;
        // Safe: block.timestamp fits in uint48 until year ~8.9M AD
        s_lastUpdate = uint48(block.timestamp);

        emit WhitelistUpdated(oldRoot, newRoot, nonce);
    }

    /**
     * @notice Requests whitelist inclusion by paying a fee
     * @dev Enforces 24-hour cooldown between requests and minimum fee of 10 TRX
     * @return success True if request was successfully recorded
     */
    function requestWhitelist() external payable whenNotPaused returns (bool success) {
        if (msg.value < REQUEST_FEE) {
            revert Errors.WhitelistRegistry__InsufficientFee();
        }

        uint256 lastRequest = uint48(s_lastRequestedTime[msg.sender]);
        if (lastRequest != 0 && block.timestamp < lastRequest + REQUEST_COOLDOWN) {
            revert Errors.WhitelistRegistry__RequestTooFrequent();
        }

        s_lastRequestedTime[msg.sender] = uint48(block.timestamp);
        unchecked {
            // Safe: REQUEST_FEE is small (10 TRX), total won't exceed uint128 max
            s_totalCollectedFees += uint128(msg.value);
        }

        emit WhitelistRequested(msg.sender);

        return true;
    }

    /**
     * @notice Withdraws all collected fees to caller
     * @dev Can only be called by addresses with WITHDRAW_ROLE
     */
    function withdraw() external {
        if (!hasRole(WITHDRAW_ROLE, msg.sender)) {
            revert Errors.WhitelistRegistry__NotAuthorized();
        }

        uint256 balance = s_totalCollectedFees;

        if (balance == 0) {
            revert Errors.WhitelistRegistry__NothingToWithdraw();
        }

        s_totalCollectedFees = 0;
        (bool success,) = msg.sender.call{value: balance}("");

        if (!success) {
            revert Errors.WhitelistRegistry__WithdrawFailed();
        }

        emit WithdrawSuccess(msg.sender, balance);
    }

    /**
     * @notice Adds a new authorized updater
     * @dev Can only be called by DEFAULT_ADMIN_ROLE
     * @param updater Address to authorize for Merkle root updates
     */
    function addAuthorizedUpdater(address updater) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Errors.WhitelistRegistry__NotAuthorized();
        }
        if (updater == address(0)) {
            revert Errors.WhitelistRegistry__InvalidInput();
        }
        if (s_authorizedUpdaters[updater]) {
            revert Errors.WhitelistRegistry__AlreadyAuthorized();
        }

        s_authorizedUpdaters[updater] = true;
        emit AuthorizedUpdaterAdded(updater);
    }

    /**
     * @notice Removes an authorized updater
     * @dev Can only be called by DEFAULT_ADMIN_ROLE
     * @param updater Address to remove from authorized updaters
     */
    function removeAuthorizedUpdater(address updater) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Errors.WhitelistRegistry__NotAuthorized();
        }
        if (updater == address(0)) {
            revert Errors.WhitelistRegistry__InvalidInput();
        }
        if (!s_authorizedUpdaters[updater]) {
            revert Errors.WhitelistRegistry__NotAuthorized();
        }

        s_authorizedUpdaters[updater] = false;
        emit AuthorizedUpdaterRemoved(updater);
    }

    /**
     * @notice Internal function to verify authorized updater signature
     * @dev Validates nonce, signature, and signer authorization. Increments nonce on success
     * @param newRoot Proposed new Merkle root
     * @param nonce Nonce value from caller
     * @param signature ECDSA signature to verify
     */
    function _onlyAuthorizedUpdater(bytes32 newRoot, uint64 nonce, bytes calldata signature) internal {
        if (newRoot == bytes32(0) || signature.length == 0) {
            revert Errors.WhitelistRegistry__InvalidInput();
        }

        if (nonce != s_nonce) {
            revert Errors.WhitelistRegistry__InvalidNonce();
        }

        bytes32 hash = keccak256(abi.encodePacked(newRoot, nonce, block.chainid, address(this)));
        bytes32 signedHash = hash.toEthSignedMessageHash();
        address signer = ECDSA.recover(signedHash, signature);

        if (signer == address(0)) {
            revert Errors.WhitelistRegistry__InvalidInput();
        }

        if (!s_authorizedUpdaters[signer]) {
            revert Errors.WhitelistRegistry__NotAuthorized();
        }

        s_nonce++;
    }

    /**
     * @notice Pauses the contract
     * @dev Can only be called by DEFAULT_ADMIN_ROLE. Prevents state-changing operations
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     * @dev Can only be called by DEFAULT_ADMIN_ROLE
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /* -------------------------------------------------------------------------- */
    /*                              GETTERS                                       */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Returns the current Merkle root
     * @return Current Merkle root hash
     */
    function getCurrentMerkleRoot() external view returns (bytes32) {
        return s_merkleRoot;
    }

    /**
     * @notice Returns total fees collected from whitelist requests
     * @return Total collected fees in wei
     */
    function getTotalCollectedFees() external view returns (uint128) {
        return s_totalCollectedFees;
    }

    /**
     * @notice Returns the timestamp of the last Merkle root update
     * @return Timestamp of last update
     */
    function getLastUpdateTime() external view returns (uint48) {
        return s_lastUpdate;
    }

    /**
     * @notice Returns the current nonce value
     * @return Current nonce
     */
    function getCurrentNonce() external view returns (uint64) {
        return s_nonce;
    }

    /**
     * @notice Checks if an address is an authorized updater
     * @param updater Address to check
     * @return True if authorized, false otherwise
     */
    function isAuthorizedUpdater(address updater) external view returns (bool) {
        return s_authorizedUpdaters[updater];
    }

    /**
     * @notice Returns the last time an address requested whitelist inclusion
     * @param requester Address to check
     * @return Timestamp of last request
     */
    function getLastRequestedTime(address requester) external view returns (uint48) {
        return uint48(s_lastRequestedTime[requester]);
    }

    /**
     * @notice Returns the cooldown period between whitelist requests
     * @return Cooldown duration in seconds (24 hours)
     */
    function getRequestCooldown() external pure returns (uint256) {
        return REQUEST_COOLDOWN;
    }

    /**
     * @notice Returns the fee required for whitelist requests
     * @return Fee amount in wei (10 TRX)
     */
    function getRequestFee() external pure returns (uint256) {
        return REQUEST_FEE;
    }

    /**
     * @notice Verifies if an address is whitelisted using Merkle proof
     * @param proof Merkle proof array
     * @param user Address to verify
     * @return valid True if address is whitelisted, false otherwise
     */
    function verifyWhitelist(bytes32[] calldata proof, address user) external view returns (bool valid) {
        if (proof.length == 0 || user == address(0)) {
            revert Errors.WhitelistRegistry__InvalidInput();
        }

        bytes32 leaf;
        assembly {
            mstore(0x0, user)
            leaf := keccak256(0x0, 0x20)
        }
        valid = MerkleProof.verify(proof, s_merkleRoot, leaf);
    }

    /**
     * @notice Returns the WITHDRAW_ROLE identifier
     * @return WITHDRAW_ROLE bytes32 identifier
     */
    function getWithdrawRole() external pure returns (bytes32) {
        return WITHDRAW_ROLE;
    }

    /**
     * @notice Returns the DEFAULT_ADMIN_ROLE identifier
     * @return DEFAULT_ADMIN_ROLE bytes32 identifier
     */
    function getDefaultAdminRole() external pure returns (bytes32) {
        return DEFAULT_ADMIN_ROLE;
    }

    /**
     * @notice Checks if an address has DEFAULT_ADMIN_ROLE
     * @param account Address to check
     * @return True if address is admin, false otherwise
     */
    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    /**
     * @notice Checks if an address has WITHDRAW_ROLE
     * @param account Address to check
     * @return True if address can withdraw, false otherwise
     */
    function isWithdrawer(address account) external view returns (bool) {
        return hasRole(WITHDRAW_ROLE, account);
    }
}
