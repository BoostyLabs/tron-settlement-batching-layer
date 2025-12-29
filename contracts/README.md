## TSBL-contracts

This folder contains the **on-chain core of the TRON Settlement Batching Layer (TSBL)** — a set of smart contracts that implement **batch-based token transfer execution** using Merkle trees, delayed finality (time-lock), and modular fee logic.
The contracts are designed so that **all critical validation happens on-chain**.  
The backend acts only as an **aggregator/operator**, not as a trusted execution component.

### **WhitelistRegistry.sol**

    ──────── STATE VARIABLES ────────
    ├── bytes32 merkleRoot
    ├── uint256 lastUpdate
    ──────── FUNCTIONS ────────
    ├── function verifyWhitelist(user, proof)
    ├── function updateMerkleRoot(newRoot, sig)
    ├── function requestWhitelist(proof)
    ──────── EVENTS ────────
    ├── emits WhitelistUpdated, WhitelistRequested

### Purpose

`WhitelistRegistry` manages **permissioned access for batched transactions** (`TxType.BATCHED`) using **Merkle tree–based whitelists**.

Whitelist verification is **only required for batched transactions**.  
Non-batched transaction types do not depend on this contract.

### Core idea

- The whitelist is represented by a **single Merkle root stored on-chain**
- Users prove inclusion via a **Merkle proof**, without storing addresses on-chain
- Updates to the whitelist are **authorized via ECDSA signatures** and protected by a nonce
- Users may submit whitelist requests by paying a small fee (anti-spam + signaling)

### **FeeModule.sol**

    ──────── TYPES ────────
    ├── enum TxType
    ├── mapping(address => uint256) dailyTxCount
    ├── mapping(address => uint256) lastResetTimestamp
    ├── mapping(bytes32 transferHash => FeeRecord) feeRecords
    ├── mapping(address => bytes32[]) userFeeHistory
    ├── mapping(bytes32 batchId => uint256) batchTotalFees
    ──────── STATE VARIABLES ────────
    ├── ITSOLWhitelistRegistry public whitelistRegistry
    ├── uint256 public totalFeesCollected
    ├── uint256 FREE_TIER_LIMIT = 10 tx/day
    ├── uint256 INSTANT_FEE = 0.2 TRX
    ├── uint256 BATCH_FEE_PER_RECIPIENT = 0.05 TRX/rcpt
    ├── uint256 BASE_FEE = 0.1 TRX
    ──────── FUNCTIONS ────────
    ├── function calculateFee(sender, TxType, volume, recipientCount)
        ├── 1. Check whitelist status (for batch processing)
        ├── 2. Check large volume → ENERGY-FREE
        ├── 3. Check daily free tier (for small users)
        ├── 4. Calculate fee based on TxType
        └── 5. Return fee & whitelist status
    ├── function applyFee(sender, fee, TxType, transferHash, batchId)
    ──────── EVENTS ────────
    ├── emits FeeCalculated, FeeApplied, FreeTierUsed

### Purpose

`FeeModule` is responsible for **on-chain fee calculation and accounting**, but **does not collect or transfer real funds**.

> ⚠️ **Important**  
> This module is **purely logical and statistical**:
> - It calculates *what the fee should be*
> - It records fee usage for analytics and UX
> - It does **not** deduct TRX or tokens

### Core idea

- Fee calculation depends on:
    - transaction type (`TxType`)
    - recipient count (`recipientCount`)
    - transfer volume
    - user free-tier quota
- **Backend never calculates fees** — it only calls `calculateFee`
- Fee logic is deterministic and fully verifiable on-chain

### **Settlement.sol**

    ──────── TYPES ────────
    ├── struct Batch
    ├── struct TransferData
    ├── mapping(bytes32 batchId => Batch) batches
    ├── mapping (uint256 => bool) executedTransfers
    ├── mapping(address => bool) approvedAggregators
    ──────── STATE VARIABLES ────────
    ├── ITSOLFeeModule public feeModule
    ├── ITSOLWhitelistRegistry public whitelistRegistry
    ├── uint256 maxTxPerBatch
    ├── uint256 public timeLockDuration
    ──────── MODIFIERS ────────
    ├── modifier onlyOwner()
    ├── modifier onlyApprovedAggregator()
    ──────── FUNCTIONS ────────
    ├── function submitBatch(rootHash, txCount, batchMetadata) onlyApprovedAggregator
        ├── 1. Validate
        ├── 2. Store batch
        ├── 3. Time lock (delayed finality)
        └── 4. Emit BatchSubmitted event
    ├── function executeTransfer(proof, transactionData) 
        ├── 1. Get batch merkleRoot from metadata
        ├── 2. Validate batch exists and time lock passed
        ├── 3. Generate transfer hash
        ├── 4. Check not executed
        ├── 5. Verify Merkle proof
        ├── 6. Calculate fee (with whitelist check)
        ├── 7. Apply fee
        ├── 8. Execute token transfer
        ├── 9. Mark as executed
        └── 10. Emit TransferExecuted event
    ├── function _verifyMerkleProof(root, leaf, proof)
    ├── function setFeeModule(_feeModule) onlyOwner
    ├── function setWhitelistRegistry(_registry) onlyOwner
    ├── function approveAggregator(aggregator, approved) onlyOwner
    ├── function setMaxTxPerBatch(_max) onlyOwner
    ├── function setTimeLockDuration(_duration) onlyOwner
    ──────── EVENTS ────────
    ├── emits BatchSubmitted, TransferExecuted

### Purpose

`Settlement` is the **execution layer of the protocol**.

It is responsible for:
- accepting batches (Merkle roots)
- enforcing delayed finality (time-lock)
- executing **exactly one transfer per Merkle leaf**

### Core idea

> **Batch ≠ multi-send transaction**

A batch is a **commitment (Merkle root)** to many transfers.  
Each transfer is executed **individually**, using its own Merkle proof.

This design preserves:
- replay protection
- deterministic execution
- partial batch execution safety

## On-chain Execution Flow

```text
Aggregator / Backend
    |
    | submitBatch(merkleRoot, txCount)
    v
Settlement
    |   (time-lock delay)
    |
    | executeTransfer(proof, data)
    v
Merkle verification → fee calculation → token transfer
