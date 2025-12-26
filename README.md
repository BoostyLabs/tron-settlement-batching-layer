# TRON Settlement Batching Layer (TSOL)

This repository is a **monorepo** implementing the **TRON Settlement Batching Layer (TSOL)** — a hybrid off-chain/on-chain system for collecting transfer intents, batching them into Merkle trees, and executing transfers on TRON using Merkle proofs with optional whitelist-based batching.

The system consists of two main parts:

* **Backend (`/backend`)** — off-chain intent collection, batching, Merkle tree construction, and on-chain orchestration.
* **Smart contracts (`/contracts`)** — on-chain settlement, fee calculation, whitelist verification, and secure execution.

---

## Repository structure

```text
tron-settlement-batching-layer/
│
├── backend/        # Spring Boot backend (intent intake, batching, Merkle, execution)
├── contracts/      # Solidity smart contracts (Foundry-based)
├── docs/           # (optional) architecture & protocol docs
└── README.md       # this file
```

---

## High-level flow

```
User / App
   ↓
Backend API (submit intent)
   ↓
Intent batching (off-chain)
   ↓
Merkle tree construction
   ↓
submitBatch(root) ───────────▶ Settlement.sol
                                 │
                                 │ (time lock)
                                 ▼
executeTransfer(proof, data) ─▶ Merkle verification
                                 Fee calculation
                                 Token transfer
```

---

# Backend (`/backend`)

Spring Boot backend responsible for **intent submission**, **batching**, **Merkle tree construction**, and **interaction with on-chain contracts**.

### What the backend does

* **Accepts transfer intents**

  * REST API for submitting `(from, to, amount, nonce, txType, …)`
* **Batching**

  * Periodic scheduler groups pending intents (size- or time-based)
* **Merkle**

  * Builds Merkle trees, computes root and per-transfer proofs
* **Settlement submission**

  * Submits batch metadata to `Settlement.sol`
* **Execution**

  * Executes individual transfers on-chain using Merkle proofs
* **Whitelist support**

  * For `txType = 2 (BATCHED)`:

    * Generates whitelist Merkle proofs
    * Syncs whitelist root on startup
* **Monitoring APIs**

  * Script-friendly endpoints for debugging and automation

---

## Backend tech stack

* **Java**: JDK **25** (via Gradle toolchain)
* **Framework**: Spring Boot 4 (WebMVC, Validation)
* **TRON client**: Trident (`io.github.tronprotocol:trident`)
* **Crypto utilities**: web3j (ECDSA, ABI decoding)
* **Build**: Gradle

---

## Backend requirements

* JDK **25**
* `bash`, `curl`, `jq` (used by test scripts)

---

## Backend quick start

```bash
cd backend
./gradlew bootRun
```

* Default port: `8080`

### Run tests

```bash
./gradlew test
```

### Build runnable JAR

```bash
./gradlew bootJar
java -jar build/libs/tsol-backend-0.0.1-SNAPSHOT.jar
```

---

## Backend configuration

Configuration is resolved in the following order:

1. **Environment variables**
2. **`.env` file** (via `spring-dotenv`)
3. **Defaults in `application.yaml`**

Example `.env` (do **not** commit):

```bash
# Server
PORT=8080

# TRON network
NODE_ENDPOINT=grpc.nile.trongrid.io:50051
CHAIN_ID=3448148188

# Settlement
SETTLEMENT_ADDRESS=YOUR_SETTLEMENT_CONTRACT_BASE58
UPDATER_PRIVATE_KEY=YOUR_64_CHAR_HEX_PRIVATE_KEY_NO_0x
UPDATER_ADDRESS=YOUR_AGGREGATOR_BASE58

# Whitelist (for txType=2)
WHITELIST_REGISTRY_ADDRESS=YOUR_WHITELIST_REGISTRY_BASE58
WL_NEW_ROOT=0xYOUR_WHITELIST_ROOT_HEX
WL_NONCE=0
WHITELIST_ADDRESSES=BASE58_ADDR_1,BASE58_ADDR_2

# Fee module
FEE_MODULE_ADDRESS=YOUR_FEE_MODULE_BASE58
TOKEN_ADDRESS=TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf
```

---

## Backend API

### Submit transfer intent

**POST** `/api/intents` → `202 Accepted`

```bash
curl -X POST "http://localhost:8080/api/intents" \
  -H "Content-Type: application/json" \
  -d '{
    "from": "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",
    "to": "TFZMxv9HUzvsL3M7obrvikSQkuvJsopgMU",
    "amount": "1000000",
    "nonce": 123,
    "timestamp": 1735000000,
    "recipientCount": 1,
    "txType": 0
  }'
```

**txType mapping:**

* `0` — DELAYED
* `1` — INSTANT
* `2` — BATCHED (requires whitelist)

---

### Monitoring endpoints

* `GET /api/monitor/stats`
* `GET /api/monitor/batches`
* `GET /api/monitor/batch/{batchId}`
* `GET /api/monitor/merkle-root/{rootHash}`
* `GET /api/monitor/transfers`
* `POST /api/monitor/create-batch-now`

---

## Backend test scripts

Located in `/backend`:

* `test-two-intents-full-flow.sh`
* `test-two-intents-batched-flow.sh`
* `test-20-intents.sh`
* `test-10-intents-batched.sh`

Run example:

```bash
./test-two-intents-full-flow.sh
```

---

## Backend notes

* **No private key → no on-chain ops**
* **Minimum batch size = 2**
* **txType=2 requires whitelist**
* **Persistence is in-memory** (restart clears state)

---

# Smart Contracts (`/contracts`)

Solidity contracts implementing **on-chain settlement, fee logic, and whitelist verification**.

Built and tested using **Foundry**.

---

## Core contracts

### WhitelistRegistry.sol

* Stores whitelist Merkle root
* Verifies whitelist proofs
* Allows controlled root updates

**Key functions**

* `verifyWhitelist(user, proof)`
* `updateMerkleRoot(newRoot, sig)`
* `requestWhitelist(proof)`

---

### FeeModule.sol

Responsible for **fee calculation and accounting**.

**Features**

* Free tier limits
* Fee logic based on `TxType`
* Batch-level and per-user fee tracking
* Whitelist-aware batching discounts

---

### Settlement.sol

Core on-chain settlement logic.

**Responsibilities**

* Accept batched Merkle roots
* Enforce time lock (delayed finality)
* Verify Merkle proofs
* Apply fees
* Execute token transfers
* Prevent double execution

---

## On-chain execution flow

```
submitBatch(merkleRoot, txCount)
        ↓
   time lock
        ↓
executeTransfer(proof, data)
        ↓
Merkle verification
Fee calculation
Token transfer
```

---

## Development (contracts)

```bash
cd contracts
forge build
forge test
```

---

## Summary

This monorepo cleanly separates:

* **Protocol logic (on-chain)** — deterministic, auditable, minimal
* **Operational logic (off-chain)** — batching, scheduling, orchestration

Together they form a **scalable, auditable, and gas-efficient settlement layer** for TRON.
