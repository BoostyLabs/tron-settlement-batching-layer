### TSBL-backend

Spring Boot backend for submitting **transfer intents**, batching them into a **Merkle tree**, submitting the batch to an on-chain **Settlement** contract on TRON, and executing transfers using Merkle proofs (optionally with whitelist proofs for batched tx types).

### What this service does

- **Accept intents**: REST endpoint to submit transfer intents (from/to/amount/nonce/etc.).
- **Batching**: scheduler groups pending intents into batches (size/time based).
- **Merkle**: builds leaf hashes + Merkle root + per-transfer proofs.
- **Settlement submission**: submits the batch (root + tx count) to the Settlement contract.
- **Execution**: after timelock/unlock, executes each transfer on-chain using proofs.
- **Whitelist support**: for `txType=2` (BATCHED) the backend generates a whitelist proof and also syncs whitelist root on startup.
- **Monitoring APIs**: endpoints under `/api/monitor/*` for scripts and debugging.

### Tech stack

- **Java**: JDK **25** (Gradle toolchain is set to 25)
- **Framework**: Spring Boot 4 (WebMVC + Validation)
- **TRON client**: Trident (`io.github.tronprotocol:trident`)
- **Crypto utilities**: web3j (ECDSA/ABI decoding)

### Requirements

- **JDK 25** installed (or a Gradle toolchain configured on your machine to provision it)
- **bash + curl + jq** (the repo’s `test-*.sh` scripts use `jq`)

### Quick start

- **Run locally** (default port `8080`):

```bash
./gradlew bootRun
```

- **Run tests**:

```bash
./gradlew test
```

- **Build a runnable jar**:

```bash
./gradlew bootJar
java -jar build/libs/tsol-backend-0.0.1-SNAPSHOT.jar
```

### Configuration

Runtime config lives in `src/main/resources/application.yaml` and is driven by:

- **(1) Environment variables**
- **(2) `.env` file** (supported via `spring-dotenv`)
- **(3) Defaults in `application.yaml`**

Create a `.env` in the repo root (do **not** commit it):

```bash
# Server
PORT=8080

# TRON gRPC endpoint (Nile default)
NODE_ENDPOINT=grpc.nile.trongrid.io:50051
CHAIN_ID=3448148188

# Settlement contract + aggregator key
SETTLEMENT_ADDRESS=YOUR_SETTLEMENT_CONTRACT_BASE58
UPDATER_PRIVATE_KEY=YOUR_64_CHAR_HEX_PRIVATE_KEY_NO_0x

# Optional
UPDATER_ADDRESS=YOUR_AGGREGATOR_BASE58

# Whitelist (required for txType=2 / BATCHED)
WHITELIST_REGISTRY_ADDRESS=YOUR_WHITELIST_REGISTRY_BASE58
WL_NEW_ROOT=0xYOUR_WHITELIST_ROOT_HEX
WL_NONCE=0
WHITELIST_ADDRESSES=BASE58_ADDR_1,BASE58_ADDR_2

# Fee module + token
FEE_MODULE_ADDRESS=YOUR_FEE_MODULE_BASE58
TOKEN_ADDRESS=TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf
```

### API

#### Submit a transfer intent

- **Endpoint**: `POST /api/intents`
- **Response**: `202 Accepted`

Example:

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

Request fields:

- **from**: TRON address (base58)
- **to**: TRON address (base58)
- **amount**: string decimal (commonly token smallest-unit as a string)
- **nonce**: integer
- **timestamp**: unix seconds
- **recipientCount**: used by fee logic (scripts use `1` for txType `0/1`, and `>1` for txType `2`)
- **txType**: integer mapped to Solidity `uint8` (scripts commonly use `0`=DELAYED, `1`=INSTANT, `2`=BATCHED)

#### Monitoring endpoints (script-friendly)

- **GET** `/api/monitor/stats`: scheduler status + summary counts
- **GET** `/api/monitor/batches`: all batches with transfers and stats
- **GET** `/api/monitor/batch/{batchId}`: one batch by on-chain batchId
- **GET** `/api/monitor/merkle-root/{rootHash}`: find batch by Merkle root
- **GET** `/api/monitor/transfers`: all transfers across all batches
- **POST** `/api/monitor/create-batch-now`: manual batching trigger (requires at least 2 pending intents)

### Repo test scripts

These scripts assume the backend is running on `http://localhost:8080` and your `.env` config is set for Nile.

- `test-two-intents-full-flow.sh`: submits 2 intents, forces batching, monitors execution
- `test-two-intents-batched-flow.sh`: same as above but uses `txType=2` and validates whitelist proof generation
- `test-20-intents.sh`: submits 20 intents (alternating txType 0/1) and waits for batching+execution
- `test-10-intents-batched.sh`: submits 10 intents with `txType=2`, forces batches, waits for completion

Run example:

```bash
./test-two-intents-full-flow.sh
```

### Important notes / troubleshooting

- **No private key = no on-chain ops**: if `UPDATER_PRIVATE_KEY` is missing/invalid, the app will start but blockchain operations (submit/execute/event reads) will be disabled.
- **Minimum batch size is 2**: the scheduler and `/create-batch-now` require at least 2 pending intents (single-tx batches don’t produce valid Merkle proofs in this implementation).
- **txType=2 requires whitelist**:
  - `WHITELIST_ADDRESSES` must include the `from` address
  - `WHITELIST_REGISTRY_ADDRESS` and `WL_NEW_ROOT` must be correct
  - Restart the backend after changing whitelist config (root sync runs on startup)
- **Persistence**: current repository is **in-memory** (`InMemoryBatchRepository`) — restarting the service clears batch state.

### Docs

- `FUNCTIONALITY_TABLE.md`: high-level “done vs missing” feature tracking
- `HELP.md`: Spring/Gradle reference links (generated template)


