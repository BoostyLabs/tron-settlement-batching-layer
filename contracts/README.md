## TSBL-contracts

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
    

**flow:**

```
On-chain:  submitBatch(merkleRoot) → time lock 1 min
           ↓
           executeTransfer(proof, data) → Merkle verify → transfer tokens
```
