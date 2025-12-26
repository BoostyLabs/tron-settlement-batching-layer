// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

library TestConstants {
    uint256 internal constant BASE_FEE = 100_000; // Base fee = 0.1 TRX
    uint256 internal constant BATCH_FEE = 50_000; // Batch fee = 0.05 TRX per recipient
    uint256 internal constant INSTANT_FEE = 200_000; // Instant fee = 0.2 TRX
    uint256 internal constant FREE_TX_AMOUNT = 10; // Free tier = first 10 tx/day for unbatched small users
    uint256 internal constant LARGE_VOLUME = 1_000_000_000;
    uint256 internal constant VOLUME = 10_000;

    uint256 internal constant REQUEST_COOLDOWN = 24 hours;
    uint256 internal constant REQUEST_FEE = 10e6; // 10 TRX
    bytes32 internal constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 internal constant MAX_TX_PER_BATCH = 22;
    uint256 internal constant TIMELOCK_DURATION = 1 days;

    address internal constant UPDATER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
}
