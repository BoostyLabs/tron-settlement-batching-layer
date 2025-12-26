package dao.tron.tsol.controller;

import dao.tron.tsol.model.LocalBatch;
import dao.tron.tsol.model.StoredTransfer;
import dao.tron.tsol.model.TransferData;
import dao.tron.tsol.service.TransferIntentService;
import dao.tron.tsol.service.BatchService;
import dao.tron.tsol.service.MerkleTreeService;
import dao.tron.tsol.config.SchedulerProperties;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.*;
import java.util.stream.Stream;

/**
 * Comprehensive monitoring endpoint for batches, transfers, and Merkle trees
 * Shows all information from the repository
 */
@Slf4j
@RestController
@RequestMapping("/api/monitor")
public class BatchMonitoringController {

    private final BatchService batchService;
    private final MerkleTreeService merkleTreeService;
    private final TransferIntentService intentService;
    private final SchedulerProperties schedulerProps;

    public BatchMonitoringController(BatchService batchService, 
                                     MerkleTreeService merkleTreeService,
                                     dao.tron.tsol.service.SettlementContractClient settlementClient,
                                     TransferIntentService intentService,
                                     SchedulerProperties schedulerProps) {
        this.batchService = batchService;
        this.merkleTreeService = merkleTreeService;
        this.intentService = intentService;
        this.schedulerProps = schedulerProps;
    }



    /**
     * GET /api/monitor/batches
     * Get all batches with complete information
     */
    @GetMapping("/batches")
    public ResponseEntity<Map<String, Object>> getAllBatches() {
        Map<String, Object> response = new LinkedHashMap<>();
        
        try {
            List<LocalBatch> batches = batchService.getBatches();
            
            List<Map<String, Object>> batchInfo = new ArrayList<>();
            
            for (LocalBatch batch : batches) {
                Map<String, Object> info = buildBatchInfo(batch);
                batchInfo.add(info);
            }
            
            response.put("status", "SUCCESS");
            response.put("totalBatches", batches.size());
            response.put("batches", batchInfo);
            
            // Summary statistics
            int totalTransfers = batches.stream()
                    .mapToInt(b -> b.getTransfers() != null ? b.getTransfers().size() : 0)
                    .sum();
            
            int executedTransfers = batches.stream()
                    .flatMap(b -> b.getTransfers() != null ? b.getTransfers().stream() : java.util.stream.Stream.empty())
                    .mapToInt(t -> t.isExecuted() ? 1 : 0)
                    .sum();
            
            response.put("statistics", Map.of(
                    "totalBatches", batches.size(),
                    "totalTransfers", totalTransfers,
                    "executedTransfers", executedTransfers,
                    "pendingTransfers", totalTransfers - executedTransfers
            ));
            
        } catch (Exception e) {
            log.error("Error getting all batches", e);
            response.put("status", "ERROR");
            response.put("error", e.getMessage());
            return ResponseEntity.status(500).body(response);
        }
        
        return ResponseEntity.ok(response);
    }

    /**
     * GET /api/monitor/stats
     *
     * Script-friendly endpoint used by test scripts in repo root.
     */
    @GetMapping("/stats")
    public ResponseEntity<Map<String, Object>> getStats() {
        Map<String, Object> response = new LinkedHashMap<>();

        List<LocalBatch> batches = batchService.getBatches();
        int pendingIntents = intentService.getPendingCount();

        int totalBatches = batches.size();
        long completedBatches = batches.stream().filter(b -> b.getStatus() != null && b.getStatus().name().equals("COMPLETED")).count();

        int totalTransfersInBatches = batches.stream()
                .mapToInt(b -> b.getTransfers() != null ? b.getTransfers().size() : 0)
                .sum();

        int executedTransfers = batches.stream()
                .flatMap(b -> b.getTransfers() != null ? b.getTransfers().stream() : Stream.<StoredTransfer>empty())
                .mapToInt(t -> t.isExecuted() ? 1 : 0)
                .sum();

        response.put("status", "SUCCESS");
        response.put("schedulers", Map.of(
                "batching", Map.of(
                        "enabled", schedulerProps.getBatching().isEnabled(),
                        "maxIntents", schedulerProps.getBatching().getMaxIntents(),
                        "maxDelaySeconds", schedulerProps.getBatching().getMaxDelaySeconds()
                ),
                "execution", Map.of(
                        "enabled", schedulerProps.getExecution().isEnabled()
                )
        ));

        response.put("statistics", Map.of(
                "totalTransfers", totalTransfersInBatches + pendingIntents,
                "pendingTransfers", pendingIntents,
                "executedTransfers", executedTransfers,
                "totalBatches", totalBatches,
                "completedBatches", completedBatches
        ));

        return ResponseEntity.ok(response);
    }

    /**
     * POST /api/monitor/create-batch-now
     *
     * Script-friendly manual trigger for batching.
     */
    @PostMapping("/create-batch-now")
    public ResponseEntity<Map<String, Object>> createBatchNow() {
        Map<String, Object> response = new LinkedHashMap<>();

        try {
            int pending = intentService.getPendingCount();
            if (pending < 2) {
                response.put("success", false);
                response.put("error", "Need at least 2 pending intents to create a valid batch (current=" + pending + ")");
                return ResponseEntity.badRequest().body(response);
            }

            int maxIntents = schedulerProps.getBatching().getMaxIntents();
            int before = batchService.getBatches().size();

            batchService.createAndSubmitBatch(maxIntents);

            List<LocalBatch> afterBatches = batchService.getBatches();
            if (afterBatches.size() <= before) {
                response.put("success", false);
                response.put("error", "Batch was not created (no new LocalBatch stored)");
                return ResponseEntity.status(500).body(response);
            }

            LocalBatch newest = afterBatches.stream()
                    .max(Comparator.comparingLong(LocalBatch::getLocalId))
                    .orElseThrow();

            response.put("success", true);
            response.put("batchId", newest.getOnChainBatchId());
            response.put("merkleRoot", newest.getMerkleRootHex());
            response.put("txCount", newest.getTxCount());
            return ResponseEntity.ok(response);
        } catch (Exception e) {
            response.put("success", false);
            response.put("error", e.getMessage());
            return ResponseEntity.status(500).body(response);
        }
    }

    /**
     * GET /api/monitor/batch/{batchId}
     * Get complete information about a specific batch
     */
    @GetMapping("/batch/{batchId}")
    public ResponseEntity<Map<String, Object>> getBatchDetails(@PathVariable Long batchId) {
        Map<String, Object> response = new LinkedHashMap<>();
        
        try {
            LocalBatch batch = batchService.getByOnChainBatchId(batchId);
            
            Map<String, Object> info = buildBatchInfo(batch);
            
            response.put("status", "SUCCESS");
            // Script compatibility: scripts expect a top-level "batch" object
            response.put("batch", info);
            // Also keep legacy flat keys for humans/debugging
            response.putAll(info);
            
        } catch (IllegalArgumentException e) {
            response.put("status", "NOT_FOUND");
            response.put("error", e.getMessage());
            return ResponseEntity.status(404).body(response);
        } catch (Exception e) {
            log.error("Error getting batch details", e);
            response.put("status", "ERROR");
            response.put("error", e.getMessage());
            return ResponseEntity.status(500).body(response);
        }
        
        return ResponseEntity.ok(response);
    }

    /**
     * GET /api/monitor/merkle-root/{rootHash}
     * Get batch by Merkle root hash
     */
    @GetMapping("/merkle-root/{rootHash}")
    public ResponseEntity<Map<String, Object>> getBatchByMerkleRoot(@PathVariable String rootHash) {
        Map<String, Object> response = new LinkedHashMap<>();
        
        try {
            // Ensure root has 0x prefix
            if (!rootHash.startsWith("0x")) {
                rootHash = "0x" + rootHash;
            }
            
            LocalBatch batch = batchService.getByMerkleRoot(rootHash);
            
            Map<String, Object> info = buildBatchInfo(batch);
            
            response.put("status", "SUCCESS");
            response.putAll(info);
            
        } catch (IllegalArgumentException e) {
            response.put("status", "NOT_FOUND");
            response.put("error", e.getMessage());
            return ResponseEntity.status(404).body(response);
        } catch (Exception e) {
            log.error("Error getting batch by merkle root", e);
            response.put("status", "ERROR");
            response.put("error", e.getMessage());
            return ResponseEntity.status(500).body(response);
        }
        
        return ResponseEntity.ok(response);
    }

    /**
     * GET /api/monitor/transfers
     * Get all transfers across all batches
     */
    @GetMapping("/transfers")
    public ResponseEntity<Map<String, Object>> getAllTransfers() {
        Map<String, Object> response = new LinkedHashMap<>();
        
        try {
            List<LocalBatch> batches = batchService.getBatches();
            List<Map<String, Object>> allTransfers = new ArrayList<>();
            
            for (LocalBatch batch : batches) {
                if (batch.getTransfers() == null) continue;
                
                for (int i = 0; i < batch.getTransfers().size(); i++) {
                    StoredTransfer st = batch.getTransfers().get(i);
                    Map<String, Object> transferInfo = buildTransferInfo(st, i, batch);
                    allTransfers.add(transferInfo);
                }
            }
            
            response.put("status", "SUCCESS");
            response.put("totalTransfers", allTransfers.size());
            response.put("transfers", allTransfers);
            
            // Group by status
            long executed = allTransfers.stream().filter(t -> Boolean.TRUE.equals(t.get("executed"))).count();
            long pending = allTransfers.size() - executed;
            
            response.put("summary", Map.of(
                    "total", allTransfers.size(),
                    "executed", executed,
                    "pending", pending
            ));
            
        } catch (Exception e) {
            log.error("Error getting all transfers", e);
            response.put("status", "ERROR");
            response.put("error", e.getMessage());
            return ResponseEntity.status(500).body(response);
        }
        
        return ResponseEntity.ok(response);
    }

    private Map<String, Object> buildBatchInfo(LocalBatch batch) {
        Map<String, Object> info = new LinkedHashMap<>();
        
        info.put("batchId", batch.getOnChainBatchId());
        info.put("submitTxId", batch.getSubmitTxId());
        info.put("merkleRoot", batch.getMerkleRootHex());
        info.put("txCount", batch.getTxCount());
        info.put("submittedAt", batch.getSubmittedAt());
        info.put("submittedAtReadable", batch.getSubmittedAt() > 0 ?
                new Date(batch.getSubmittedAt() * 1000).toString() : "N/A");
        info.put("status", batch.getStatus() != null ? batch.getStatus().toString() : "UNKNOWN");
        info.put("unlockTime", batch.getUnlockTime());
        info.put("unlockTimeReadable", batch.getUnlockTime() > 0 ? 
                new Date(batch.getUnlockTime() * 1000).toString() : "N/A");
        
        if (batch.getTransfers() != null) {
            info.put("transferCount", batch.getTransfers().size());
            
            List<Map<String, Object>> transfers = new ArrayList<>();
            for (int i = 0; i < batch.getTransfers().size(); i++) {
                StoredTransfer st = batch.getTransfers().get(i);
                transfers.add(buildTransferInfo(st, i, batch));
            }
            info.put("transfers", transfers);
            
            // Transfer execution summary
            long executed = batch.getTransfers().stream().filter(StoredTransfer::isExecuted).count();
            info.put("executionSummary", Map.of(
                    "total", batch.getTransfers().size(),
                    "executed", executed,
                    "pending", batch.getTransfers().size() - executed
            ));
        } else {
            info.put("transferCount", 0);
            info.put("transfers", Collections.emptyList());
        }
        
        return info;
    }

    private Map<String, Object> buildTransferInfo(StoredTransfer st, int index, LocalBatch batch) {
        Map<String, Object> info = new LinkedHashMap<>();
        
        TransferData td = st.getTxData();
        
        info.put("index", index);
        info.put("batchId", batch.getOnChainBatchId());
        // Script compatibility: scripts expect transfer.txData.{from,to,amount,...}
        Map<String, Object> txData = new LinkedHashMap<>();
        txData.put("from", td.getFrom());
        txData.put("to", td.getTo());
        txData.put("amount", td.getAmount());
        txData.put("nonce", td.getNonce());
        txData.put("timestamp", td.getTimestamp());
        txData.put("recipientCount", td.getRecipientCount());
        txData.put("txType", td.getTxType());
        txData.put("batchId", td.getBatchId());
        info.put("txData", txData);

        // Keep legacy flattened fields for existing users
        info.put("from", td.getFrom());
        info.put("to", td.getTo());
        info.put("amount", td.getAmount());
        info.put("nonce", td.getNonce());
        info.put("timestamp", td.getTimestamp());
        info.put("timestampReadable", new Date(td.getTimestamp() * 1000).toString());
        info.put("recipientCount", td.getRecipientCount());
        info.put("txType", td.getTxType());
        info.put("executed", st.isExecuted());
        info.put("executionTxId", st.getExecutionTxId());
        info.put("proofSize", st.getTxProof() != null ? st.getTxProof().size() : 0);
        // Helpful for txType=2 monitoring (BATCHED requires a whitelist proof).
        // Keep only the size (do not expose full proof array in monitoring response).
        int wlSize = st.getWhitelistProof() != null ? st.getWhitelistProof().size() : 0;
        info.put("whitelistProofSize", wlSize);
        
        // Calculate tx hash for reference
        byte[] txHash = merkleTreeService.leafHash(td, batch.getBatchSalt());
        info.put("txHash", "0x" + bytesToHex(txHash));
        
        return info;
    }

    @SuppressWarnings("unused")
    private Map<String, Object> buildDetailedTransferInfo(StoredTransfer st, int index, LocalBatch batch) {
        Map<String, Object> info = buildTransferInfo(st, index, batch);
        
        if (st.getTxProof() != null && !st.getTxProof().isEmpty()) {
            info.put("merkleProof", st.getTxProof());
        } else {
            info.put("merkleProof", Collections.emptyList());
        }
        
        if (st.getWhitelistProof() != null && !st.getWhitelistProof().isEmpty()) {
            info.put("whitelistProof", st.getWhitelistProof());
        } else {
            info.put("whitelistProof", Collections.emptyList());
        }
        
        info.put("batch", Map.of(
                "batchId", batch.getOnChainBatchId(),
                "merkleRoot", batch.getMerkleRootHex(),
                "status", batch.getStatus() != null ? batch.getStatus().toString() : "UNKNOWN"
        ));
        
        return info;
    }

    private String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02x", b & 0xff));
        }
        return sb.toString();
    }
}

