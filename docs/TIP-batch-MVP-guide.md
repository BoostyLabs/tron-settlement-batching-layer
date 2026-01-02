# TIP-batch MVP guide

- [TIP-batch MVP guide](#tip-batch-mvp-guide)
  - [General technical guide](#general-technical-guide)
    - [Purpose and scope](#purpose-and-scope)
    - [Audience](#audience)
      - [Primary audience](#primary-audience)
      - [Secondary audience](#secondary-audience)
    - [MVP scope versus proposal scope](#mvp-scope-versus-proposal-scope)
      - [What the protocol does in this MVP](#what-the-protocol-does-in-this-mvp)
      - [What the protocol does not do in this MVP](#what-the-protocol-does-not-do-in-this-mvp)
    - [Conventions and normative language](#conventions-and-normative-language)
    - [System model](#system-model)
      - [Component map](#component-map)
      - [Roles and responsibilities](#roles-and-responsibilities)
      - [Architecture sketch alignment](#architecture-sketch-alignment)
      - [Architecture diagrams](#architecture-diagrams)
    - [On-chain contracts](#on-chain-contracts)
      - [Settlement contract](#settlement-contract)
      - [Whitelist registry contract](#whitelist-registry-contract)
      - [Fee module contract](#fee-module-contract)
    - [Off-chain components](#off-chain-components)
      - [Batch builder and executor service (Java application)](#batch-builder-and-executor-service-java-application)
      - [Merkle tooling scripts (Python and Java)](#merkle-tooling-scripts-python-and-java)
    - [Data model](#data-model)
      - [Transfer leaf payload](#transfer-leaf-payload)
      - [Whitelist leaf payload](#whitelist-leaf-payload)
    - [Protocol flows](#protocol-flows)
      - [Flow A: whitelist root update](#flow-a-whitelist-root-update)
      - [Flow B: batch commit](#flow-b-batch-commit)
      - [Flow C: approve and transfer execution](#flow-c-approve-and-transfer-execution)
    - [Optional versus required elements](#optional-versus-required-elements)
      - [Required for MVP operation](#required-for-mvp-operation)
      - [Optional in the MVP design](#optional-in-the-mvp-design)
    - [Security and trust model](#security-and-trust-model)
      - [Centralization and operator trust](#centralization-and-operator-trust)
      - [Allowance-based risk surface](#allowance-based-risk-surface)
      - [Unlock time semantics](#unlock-time-semantics)
      - [TRON resource considerations](#tron-resource-considerations)
  - [Developer-oriented notes](#developer-oriented-notes)
    - [Design decisions](#design-decisions)
      - [Merkle root as batch commitment](#merkle-root-as-batch-commitment)
      - [Per-transfer execution instead of single-call settlement](#per-transfer-execution-instead-of-single-call-settlement)
      - [Sponsored execution via transferFrom](#sponsored-execution-via-transferfrom)
      - [Whitelist gating via Merkle proof](#whitelist-gating-via-merkle-proof)
      - [Unlock time as a review window](#unlock-time-as-a-review-window)
      - [Off-chain state as in-memory storage](#off-chain-state-as-in-memory-storage)
    - [Integration notes](#integration-notes)
      - [Integration roles](#integration-roles)
      - [Integration sequence for a dApp](#integration-sequence-for-a-dapp)
    - [Edge cases](#edge-cases)
      - [Allowance and balance changes between commit and execution](#allowance-and-balance-changes-between-commit-and-execution)
      - [Nonce collisions and replay](#nonce-collisions-and-replay)
      - [Token contract behavior](#token-contract-behavior)
      - [Batch composition risks](#batch-composition-risks)
    - [Limitations and non-goals](#limitations-and-non-goals)
  - [Reference and examples](#reference-and-examples)
    - [Terms](#terms)
    - [Examples](#examples)
      - [Transfer leaf payload](#transfer-leaf-payload)
      - [Example whitelist input](#example-whitelist-input)
      - [Sequence diagram: whitelist root update](#sequence-diagram-whitelist-root-update)
      - [Sequence diagram: batch commit and execution](#sequence-diagram-batch-commit-and-execution)
      - [Pseudocode: batch boundary selection](#pseudocode-batch-boundary-selection)
      - [Pseudocode: Merkle commitment and per-leaf execution](#pseudocode-merkle-commitment-and-per-leaf-execution)
    - [Failure classes](#failure-classes)

This document describes the general provisions of TIP-batch MVP and consists of the following components:

1. General technical guide.
2. Developer-oriented notes.
3. Reference and examples.

## General technical guide {#general-technical-guide}

### Purpose and scope {#purpose-and-scope}

This document describes the implemented MVP of TIP-batch (TRON settlement batching layer), based on developer transcripts and a high-level architecture sketch. \
This document targets protocol-level readers and describes current MVP behavior, not the full proposal design.

### Audience {#audience}

#### Primary audience {#primary-audience}

* TRON core developers and maintainers.
* Protocol and blockchain engineers.
* Infrastructure engineers and L1/L2 engineers.
* Developers who work with TRON TVM, Energy/Bandwidth, and Stake 2.0.
* TRON community members who author or review TIPs.

#### Secondary audience {#secondary-audience}

* dApp developers who build sponsored execution (MetaFee-like) flows and gasless UX on TRON.
* Auditors and researchers who analyze protocol designs and MVP implementations.

### MVP scope versus proposal scope {#mvp-scope-versus-proposal-scope}

#### What the protocol does in this MVP {#what-the-protocol-does-in-this-mvp}

* The system commits a Merkle root for a set of TRC-20 transfers to an on-chain settlement contract.
* The system enforces an unlock time (time lock) before transfer execution.
* The system executes each transfer on-chain after the caller supplies a Merkle inclusion proof.
* The system optionally gates a “batch-transfer” type via a whitelist Merkle proof for the sender address (txData.from).
* The system computes “virtual” fees via a fee module contract, without enforcing real fee collection in the MVP.

#### What the protocol does not do in this MVP {#what-the-protocol-does-not-do-in-this-mvp}

* The system does not execute an entire batch with a single on-chain token transfer call.
* The system does not implement a full dispute mechanism (fraud-proof and on-chain rollback).
* The system does not define a complete user-signed intent scheme in the transcripts.
* Existence of user-signed transfer intents in code, including signature verification and authorization rules.
* Existence of on-chain dispute hooks, batch invalidation, or batch cancellation.
* Exact mapping between the published proposal terminology and the deployed MVP contracts.

### Conventions and normative language {#conventions-and-normative-language}

* MUST, MUST NOT, SHOULD, SHOULD NOT, MAY indicate normative requirements for the MVP flows described in this guide.
* “Batch commitment” means the on-chain record that anchors a batch root and related metadata.
* “Transfer leaf” means the off-chain representation that the Merkle tree uses as a leaf payload, and that the settlement contract verifies via an inclusion proof.
* “Sender” means txData.from in the transfer payload passed to Settlement.executeTransfer.
* “Executor” means the account that submits on-chain transactions (submitBatch, executeTransfer) and consumes TRON resources (Energy/Bandwidth).
* “Whitelist gating” means a membership check for the sender (txData.from) under the WhitelistRegistry Merkle root, when the transaction type uses batch-transfer gating.

### System model {#system-model}

#### Component map {#component-map}

On-chain components:

* Settlement contract.
* Whitelist registry contract.
* Fee module contract.

Off-chain components:

* Batch builder and executor service (Java application in the MVP).
* Merkle tooling scripts (Python and Java in the MVP).
* TRON node RPC endpoint (external node, as described in transcripts).

#### Roles and responsibilities {#roles-and-responsibilities}

Batch builder (off-chain):

* Collects transfer requests into a queue.
* Chooses batch boundaries (count threshold or time window).
* Builds a Merkle tree and produces a batch root.
* Produces Merkle proofs for each transfer leaf.
* Submits the batch root to the settlement contract.

Executor (off-chain):

* Calls executeTransfer on the settlement contract for each transfer leaf after unlock time.
* Pays TRON resource costs (Energy/Bandwidth) for the on-chain transactions.
* Treats whitelist proofs as proofs for the sender (txData.from), not for the executor address.

Root signer (off-chain key role):

* Signs the whitelist Merkle root, which authorizes an on-chain update of the whitelist root.

Settlement contract (on-chain):

* Stores batch commitments (root and metadata).
* Enforces unlock time for each committed batch.
* Verifies Merkle inclusion proofs for transfer leaves.
* Calls TRC-20 transferFrom to execute token transfers.
* Marks executed transfers to prevent replay.
* Calls the fee module for virtual fee computation.
* Queries the whitelist registry for sender whitelist gating (txData.from) when required by transaction type.

Whitelist registry contract (on-chain):

* Stores a whitelist Merkle root for eligible sender addresses (txData.from).
* Verifies authorization for updating the root via a role system and a root signature check.
* Emits an event for “request whitelist” as an off-chain signal.

Fee module contract (on-chain):

* Computes virtual fees by transaction type and parameters.
* Restricts fee application calls to the settlement contract.
* Does not enforce real fee collection in the MVP.

#### Architecture sketch alignment {#architecture-sketch-alignment}

The architecture sketch shows the following call direction:

* The node commits a batch to the settlement contract.
* The settlement contract calls the whitelist registry and fee module.
* The settlement contract executes TRC-20 transfers via transferFrom.

#### Architecture diagrams {#architecture-diagrams}

System flow diagram:

![System flow diagram.png](System%20flow%20diagram.png)

On-chain contract dependencies:

![On-chain contract dependencies.png](On-chain%20contract%20dependencies.png)

Contract structure overview:

![Contract structure overview.png](Contract%20structure%20overview.png)

### On-chain contracts {#on-chain-contracts}


#### Settlement contract {#settlement-contract}

Responsibilities:

* Accept a batch commitment (Merkle root and batch metadata).
* Enforce an unlock time (challenge window) before executing transfers for that batch.
* Execute a single transfer per call, based on a verified Merkle proof.
* Prevent replay by marking a transfer as executed.

Key operations:

* Submit batch: store the batch root and metadata, and set an unlock time.
* Execute transfer: verify inclusion, verify optional whitelist membership for txData.from, compute fee, execute transferFrom, mark executed.

Batch id semantics: \
Settlement derives batchId during batch submission and uses batchId as the on-chain key for batches[batchId]. \
Off-chain systems MAY treat batchId as a logical handle for monitoring, indexing, and API correlation. \
Transfer leaf hashing does not require batchId when leaf encoding includes a root-binding mechanism (for example, batchSalt in metadata or an equivalent binding), because the Merkle proof already ties the leaf to the committed root.

Per-transfer execution model:

* The settlement contract executes exactly one TRC-20 transfer per executeTransfer call.
* Recipient count affects fee computation and tree structure metadata, but recipient count does not reduce the number of on-chain token transfer calls.

#### Whitelist registry contract {#whitelist-registry-contract}

Responsibilities:

* Store a whitelist root that represents eligible sender addresses (txData.from).
* Provide a proof-based membership check for batch-transfer gating of txData.from.
* Provide administrative control over root updates via roles and signature checks.

Root update model:

* The root signer signs a new whitelist root off-chain.
* Any account MAY submit the signed root to the whitelist registry contract.
* The contract verifies the root signature and updates the stored whitelist root.
* An admin role manages which accounts can manage updater roles, as described in transcripts.

Request whitelist model:

* A user MAY call a requestWhitelist-like function and pay a small fee.
* The contract emits an event.
* An off-chain process MUST observe this event and decide whether to include the address in the next root.
* Exact role identifiers and role hierarchy in the whitelist registry.
* Fee handling for request whitelist, including fee recipient and accounting.
* Off-chain policy and SLA for processing request whitelist events.

#### Fee module contract {#fee-module-contract}

Responsibilities:

* Compute virtual fees for analytics and future enforcement.
* Apply fee accounting only when the settlement contract calls the fee module.

Fee types described in transcripts:
* Base fee for a standard transfer type.
* Batch fee for a batch-transfer type, lower than other types.
* Instant fee for an “instant” type, without actual prioritization in the MVP.
* Free tier of 10 transfers per day for each user, gated by a transaction type choice.
* Volume-based fee adjustments based on fixed constants defined in the contract.
* Exact constants and thresholds, including “volume” definition.
* Exact rules for “10 free transfers per day”, including day boundary and per-user accounting state.
* Whether the MVP stores fee counters on-chain or treats fees as off-chain metrics only.

### Off-chain components {#off-chain-components}

#### Batch builder and executor service (Java application) {#batch-builder-and-executor-service-java-application}

Batch boundary rules in the MVP: \
The MVP uses two batch boundary conditions, and either condition triggers batch creation.

* Count condition: the service creates a batch when the queue reaches a fixed number of transfers (example value: 5 transfers).
* Time condition: the service creates a batch when a fixed time window elapses (example value: 30 seconds), even if the queue contains fewer transfers.

State storage in the MVP:

* The MVP stores batches and transfers in memory and locally, without a database.
* The MVP accepts this limitation due to delivery time constraints.

TRON connectivity in the MVP:

* The MVP uses a Java library described as “3Dent” to access TRON nodes and interact with smart contracts.
* The service sends requests to an external TRON node.
* Exact library name, artifact coordinates, and supported features (signing, contract calls, event decoding).
* Exact RPC node type (full node, solidity node) and network (Nile testnet, Shasta, mainnet).

Operational visibility:

* The service exposes controllers that report batch status and per-batch transaction ids.
* The service supports opening transaction ids in a TRON block explorer for testnet validation.

#### Merkle tooling scripts (Python and Java) {#merkle-tooling-scripts-python-and-java}

Responsibilities:

* Generate the whitelist Merkle root from an address list.
* Generate the batch Merkle root from transfer leaf payloads.
* Generate inclusion proofs for transfer execution.
* Support deployment and end-to-end demo flows, as described in transcripts.
* Leaf encoding rules, hash function, and concatenation rules.
* Sorting rules, padding rules, and odd-leaf handling.
* Cross-language consistency checks between Python and Java implementations.

### Data model {#data-model}

#### Transfer leaf payload {#transfer-leaf-payload}

The transcripts describe the following logical fields for a transfer leaf:
* Sender address (from, equals txData.from).
* Recipient address (to).
* Token amount (amount).
* Timestamp (timestamp).
* Nonce (nonce).
* Transaction type (type).
* Recipient count (recipientCount), used for fee computation, not for on-chain execution fan-out.
* Batch reference fields (batchId) as off-chain metadata, where Settlement defines batchId at submit time, and leaf hashing can omit batchId when root-binding exists.

#### Whitelist leaf payload {#whitelist-leaf-payload}

* The whitelist leaf represents a sender address membership element, typically an address or an address hash.
* Whether the tree uses raw addresses or hashed addresses as leaves.
* Whether the contract normalizes addresses before hashing.

### Protocol flows {#protocol-flows}

#### Flow A: whitelist root update {#flow-a-whitelist-root-update}

1. The off-chain process collects eligible sender addresses (txData.from candidates).
2. The off-chain process builds a whitelist Merkle tree and produces a whitelist root.
3. The root signer signs the whitelist root.
4. A submitter sends the signed root to the whitelist registry contract.
5. The whitelist registry contract verifies the signature and stores the new root.

#### Flow B: batch commit {#flow-b-batch-commit}

1. The batch builder collects transfer requests into a queue.
2. The batch builder selects a batch boundary by count or time window.
3. The batch builder builds a batch Merkle tree and produces a batch root.
4. The submitter commits the batch root to the settlement contract.
5. The settlement contract stores the commitment and sets an unlock time.
6. The settlement contract defines batchId as an internal identifier, and off-chain systems treat batchId as a logical handle for monitoring and correlation.

#### Flow C: approve and transfer execution {#flow-c-approve-and-transfer-execution}

1. The sender submits a TRC-20 approve transaction that grants allowance to the settlement contract.
2. The executor waits until the unlock time passes.
3. The executor calls executeTransfer for a specific transfer leaf and supplies the leaf payload and Merkle proof.
4. The executor supplies a whitelist proof for the sender address (txData.from) when the transaction type requires whitelist gating.
5. The settlement contract verifies proofs, computes a virtual fee, and calls TRC-20 transferFrom.
6. The settlement contract marks the transfer as executed and rejects repeated execution attempts.

### Optional versus required elements {#optional-versus-required-elements}

#### Required for MVP operation {#required-for-mvp-operation}

* Settlement contract deployment and configuration.
* Off-chain batch builder that produces batch roots and proofs.
* A funded executor account that can pay TRON resources for on-chain calls.
* TRC-20 approve from each sender address, sized to the intended transfer amounts.

#### Optional in the MVP design {#optional-in-the-mvp-design}

* Whitelist gating for batch-transfer types.
* Fee module integration beyond analytics and virtual accounting.
* Request whitelist flow, beyond event emission.
* Operational controllers and dashboards.

### Security and trust model {#security-and-trust-model}

#### Centralization and operator trust {#centralization-and-operator-trust}

* The MVP assumes a trusted operator group for batch creation and root submission.
* The MVP uses contract ownership and role-based access control for administrative actions.
* This trust assumption acts as an explicit MVP trade-off, and Merkle commitments plus per-leaf execution provide a baseline for a later permissionless model with additional constraints.

#### Allowance-based risk surface {#allowance-based-risk-surface}

* The settlement contract uses transferFrom, so sender allowances define the maximum amount the settlement contract can transfer.
* A sender SHOULD scope allowances to intended amounts to limit exposure.
* Existence of per-transfer user signatures, and how the contract verifies them.
* Existence of additional constraints that bind leaf “from” to an authenticated actor.

#### Unlock time semantics {#unlock-time-semantics}

* The settlement contract enforces a time lock before execution.
* The MVP does not implement an on-chain fraud proof or on-chain batch rollback in transcripts.
* Unlock time acts as an operational review window for the operator group or automated checks.
* Whether the system supports batch cancellation before unlock.
* Whether the system supports marking a batch invalid after commit.

#### TRON resource considerations {#tron-resource-considerations}

* The executor account pays Energy/Bandwidth for commit batch and execute transfer calls.
* Stake 2.0 resource provisioning determines sustainable throughput for the executor.
* Measured Energy/Bandwidth usage per commit batch and per execute transfer.
* Maximum batch size limits and expected commit cadence.

## Developer-oriented notes {#developer-oriented-notes}

### Design decisions {#design-decisions}

#### Merkle root as batch commitment {#merkle-root-as-batch-commitment}

* The MVP uses a Merkle root to anchor a set of transfers with constant-size on-chain storage per batch.
* The MVP verifies inclusion per transfer via a Merkle proof and executes transfers individually.

#### Per-transfer execution instead of single-call settlement {#per-transfer-execution-instead-of-single-call-settlement}

* The MVP prioritizes correctness and implementation speed by executing one transfer per executeTransfer call.
* The MVP does not compress multiple transfers into one on-chain state transition.

#### Sponsored execution via transferFrom {#sponsored-execution-via-transferfrom}

* The MVP uses TRC-20 approve and transferFrom so an executor can sponsor transfer execution.
* The sender pays for approval, and the executor pays for executeTransfer resource costs.

#### Whitelist gating via Merkle proof {#whitelist-gating-via-merkle-proof}

* The MVP stores whitelist membership as a Merkle root to avoid large on-chain address lists.
* The MVP requires a whitelist proof only for batch-transfer types, and the whitelist proof targets the sender address (txData.from).

#### Unlock time as a review window {#unlock-time-as-a-review-window}

* The MVP inserts a time delay between commit and execution.
* The MVP uses unlock time as a control point for operator review, without an on-chain dispute mechanism.

#### Off-chain state as in-memory storage {#off-chain-state-as-in-memory-storage}

* The MVP uses in-memory and local storage for speed of delivery.
* The MVP accepts restart and durability risks in exchange for a short lead time.

### Integration notes {#integration-notes}

#### Integration roles {#integration-roles}

* The batch builder service acts as an aggregator and as an executor in the MVP.
* A production system MAY separate aggregator and executor roles for isolation and security.

#### Integration sequence for a dApp {#integration-sequence-for-a-dapp}

* The dApp collects transfer parameters off-chain and forwards them to the batch builder.
* The dApp prompts the user to submit a TRC-20 approve transaction for the settlement contract.
* The batch builder commits a batch and executes transfers after unlock time.
* The dApp reads status via the batch builder controllers and on-chain events.
* Existence of a stable API surface for the batch builder service, including request schemas and authentication.
* Existence of an intent signature scheme or attestations for transfer authorization.

### Edge cases {#edge-cases}

#### Allowance and balance changes between commit and execution {#allowance-and-balance-changes-between-commit-and-execution}

* A sender MAY reduce allowance after commit, which causes transferFrom to fail.
* A sender MAY spend tokens after commit, which reduces balance and causes transferFrom to fail.
* The executor SHOULD handle partial execution failures and report per-transfer status.

#### Nonce collisions and replay {#nonce-collisions-and-replay}

* A transfer leaf SHOULD carry a nonce that prevents replay.
* The settlement contract MUST reject repeated execution attempts for the same leaf or nonce, depending on implementation.
* Whether the contract tracks nonces per sender or tracks leaf hashes.
* Whether the contract rejects duplicate leaf payloads across batches.

#### Token contract behavior {#token-contract-behavior}

* TRC-20 tokens differ in revert patterns and return values.
* The settlement contract SHOULD handle non-standard TRC-20 behaviors if the design targets multiple tokens.
* Whether the MVP targets USDT/USDC only, or arbitrary TRC-20 tokens.
* Whether the settlement contract uses safe wrappers for token calls.

#### Batch composition risks {#batch-composition-risks}

* A trusted operator defines batch contents in the MVP.
* Operator errors in leaf construction cause execution failures or unintended transfers.

### Limitations and non-goals {#limitations-and-non-goals}

* The MVP does not implement a full rollup dispute system.
* The MVP does not minimize on-chain transfer calls, because each leaf executes separately.
* The MVP does not define a complete permissionless batch submission model in transcripts.
* The MVP does not define a decentralized whitelist update mechanism in transcripts.

## Reference and examples {#reference-and-examples}

### Terms {#terms}

* Batch: a set of transfer leaves anchored by a Merkle root.
* Batch commitment: an on-chain record of a batch root and metadata.
* Transfer leaf: a payload that represents one TRC-20 transfer, hashed into the Merkle tree.
* Inclusion proof: a Merkle path that proves membership of a leaf under a root.
* Whitelist root: a Merkle root that represents eligible sender addresses (txData.from) for a gated transfer type.
* Unlock time: a time lock after commit and before execution.
* Executor: an account that submits commit and executes transactions, and pays TRON resources.

### Examples {#examples}

#### Transfer leaf payload {#transfer-leaf-payload}

The MVP transcripts do not define the exact field ordering, types, and hashing rules.

```
```{ \
"from": "T...sender", \
"to": "T...recipient", \
"token": "T...trc20Contract", \
"amount": "1000000", \
"nonce": 11, \
"timestamp": 1730000000, \
"type": "BATCH", \
"recipientCount": 3, \
"batchId": "0x...optional_logical_handle" \
}
```

#### Example whitelist input {#example-whitelist-input}

```
[
"T...addr1", \
"T...addr2", \
"T...addr3" \
]
```


#### Sequence diagram: whitelist root update {#sequence-diagram-whitelist-root-update}

Actors: Root signer, Submitter, Whitelist registry contract.



1. Root signer -> Off-chain tooling: Build whitelist Merkle root.
2. Root signer -> Off-chain tooling: Sign whitelist Merkle root.
3. Submitter -> Whitelist registry contract: Update root with signed root.
4. Whitelist registry contract -> On-chain state: Store new whitelist root.


#### Sequence diagram: batch commit and execution {#sequence-diagram-batch-commit-and-execution}

Actors: Batch builder, Settlement contract, Whitelist registry, Fee module, TRC-20 token.



1. Batch builder -> Off-chain state: Collect transfer requests.
2. Batch builder -> Off-chain tooling: Build batch Merkle root and proofs.
3. Batch builder -> Settlement contract: Commit batch root and metadata.
4. Settlement contract -> On-chain state: Store commitment and unlock time.
5. Sender -> TRC-20 token: Approve settlement contract allowance.
6. Batch builder -> Settlement contract: Call executeTransfer with leaf + proof (+ whitelist proof when required).
7. Settlement contract -> Whitelist registry: Verify whitelist membership for the sender address (txData.from) when required.
8. Settlement contract -> Fee module: Compute virtual fee.
9. Settlement contract -> TRC-20 token: Call transferFrom(from, to, amount).
10. Settlement contract -> On-chain state: Mark leaf as executed.


#### Pseudocode: batch boundary selection {#pseudocode-batch-boundary-selection}

```
state queue := [] \
state windowStart := now()

onTransferRequest(req): \
enqueue(queue, req) \
if size(queue) >= COUNT_THRESHOLD: \
createBatchAndCommit(queue) \
clear(queue) \
windowStart := now() \
return \
if now() - windowStart >= TIME_WINDOW: \
createBatchAndCommit(queue) \
clear(queue) \
windowStart := now() \
return
```


#### Pseudocode: Merkle commitment and per-leaf execution {#pseudocode-merkle-commitment-and-per-leaf-execution}

```
function createBatchAndCommit(queue): \
leaves := map(queue, encodeLeafPayload) \
root := merkleRoot(leaves) \
metadata := buildBatchMetadata(queue) \
sendTx(settlement.commitBatch, root, metadata) \
batchId := readEvent(BatchSubmitted).batchId

function executeLeaf(batchId, leafPayload, merkleProof, whitelistProofOpt): \
assert(now() >= settlement.unlockTime(batchId)) \
assert(settlement.verifyInclusion(leafPayload, merkleProof)) \
if leafPayload.type == "BATCH": \
assert(whitelistRegistry.verifyWhitelist(leafPayload.from, whitelistProofOpt)) \
fee := feeModule.compute(leafPayload) \
assert(trc20.allowance(leafPayload.from, settlement.address) >= leafPayload.amount) \
sendTx(settlement.executeTransfer, leafPayload, merkleProof, whitelistProofOpt)
```


### Failure classes {#failure-classes}

* Batch not found or not committed.
* Batch locked due to unlock time.
* Merkle proof is invalid for the supplied leaf.
* Whitelist proof missing or invalid for a gated type.
* Transfer already executed (replay attempt).
* Nonce invalid or reused, depending on implementation.
* TRC-20 allowance insufficient or balance insufficient.
* TRC-20 token call failure due to non-standard behavior.