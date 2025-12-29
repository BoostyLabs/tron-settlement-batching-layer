### Functionality table (based on `description.text`) — Done vs Should be added

| Area | Functionality | Status | Where it exists now | What should be added (gap) |
|---|---|---|---|---|
| **Intents** | Accept transfer intents via API | **Done** | `POST /api/intents` (`TransferIntentController`), `TransferIntentService` | Signed intents (canonical format + signature verification), nonce/replay protection, rate limits |
| **Batching** | Create batches from pending intents (timer/quantity) | **Done (basic)** | `BatchingScheduler`, `BatchService` | More flexible batching policy (priority flags, max-wait per intent), single-intent support if required |
| **Merkle** | Compute tx leaf hash + Merkle root + proofs | **Done** | `MerkleTreeService` + scripts in `sc/script/merkle/` | Formal test vectors + cross-language verifier library |
| **On-chain Settlement** | Submit batch (root+count) | **Done** | `Settlement.sol` + `SettlementContractClientTrident.submitBatchWithTxId` | Production reconciliation (detect stuck submits, backfill event scanning) |
| **Timelock / Deferred** | Unlock time gating before execution | **Done** | `Settlement.sol` unlockTime, `ExecutionScheduler` | Operational controls (pause/resume execution), SLA monitoring |
| **Execution** | Execute transfer with proofs | **Done** | `Settlement.sol.executeTransfer`, `SettlementContractClientTrident.executeTransfer` | **Idempotency check** using `isExecutedTransfer(bytes32)` before sending; better error decoding; retry strategy |
| **Whitelist** | Whitelist Merkle root registry | **Done** | `WhitelistRegistry.sol` | Automated whitelist scoring + scheduled root updates (analytics node) |
| **Whitelist enforcement** | Require whitelist proof only for batched txType | **Done** | `Settlement.sol._validateBatched`, Java `BatchService` proof selection | Tools/SDK to generate proofs for external clients |
| **Fee module** | Fee calculation based on txType + free tier quota | **Done (analytics-only)** | `FeeModule.sol` | If “real fees” are required: actual fee collection/transfer + accounting + reporting |
| **Monitoring** | API to view batches/transfers/state | **Done** | `BatchMonitoringController` | Prometheus metrics, dashboards, alerts, audit logs |
| **Persistence** | Store batches/transfers reliably | **Not done** | Current: `InMemoryBatchRepository` | Postgres (or other DB), migrations, restart recovery, indexing strategy |
| **Security model (full vision)** | Rollup/channels, fraud proofs or ZK proofs | **Not done** | — | Off-chain ledger, state root commitments, challenge window (optimistic) or ZK proof pipeline |
| **Router / Custody (full vision)** | Contract accepts deposits, buffers, routes, withdrawals | **Not done** | — | Router contract + event ingestion + exit/withdraw flows |
| **Governance (full vision)** | DAO changes parameters (timings, batch rules, free tier) | **Partial** | Owner/admin controls in contracts | DAO/multisig integration + timelocked parameter changes |
| **Verifier library (full vision)** | OSS verifier for signatures, Merkle proofs, nonce rules | **Not done** | — | Publish libs (JS + backend language) + test vectors + CI |