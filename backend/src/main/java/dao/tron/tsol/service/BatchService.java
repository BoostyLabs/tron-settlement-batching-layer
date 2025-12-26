package dao.tron.tsol.service;

import dao.tron.tsol.model.*;
import dao.tron.tsol.repository.BatchRepository;
import dao.tron.tsol.util.CryptoUtil;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

@Slf4j
@Service
public class BatchService {

    private final TransferIntentService intentService;
    private final MerkleTreeService merkleTreeService;
    private final SettlementContractClient settlementClient;
    private final BatchRepository batchRepository;
    private final WhitelistService whitelistService;

    public BatchService(TransferIntentService intentService,
                        MerkleTreeService merkleTreeService,
                        SettlementContractClient settlementClient,
                        BatchRepository batchRepository,
                        WhitelistService whitelistService) {
        this.intentService = intentService;
        this.merkleTreeService = merkleTreeService;
        this.settlementClient = settlementClient;
        this.batchRepository = batchRepository;
        this.whitelistService = whitelistService;
    }

    public synchronized void createAndSubmitBatch(int maxTxPerBatch) {
        List<TransferIntentRequest> intents = intentService.drainUpTo(maxTxPerBatch);
        if (intents.isEmpty()) return;

        // Per-batch salt used for txHash / Merkle leaf hashing (batchId is NOT hashed anymore)
        long batchSalt = CryptoUtil.randomUint64PositiveNonZero();

        // map to TransferData
        // NOTE: batchId is NOT part of Merkle tree calculation in new Settlement contract
        List<TransferData> txs = new ArrayList<>();
        for (TransferIntentRequest req : intents) {
            TransferData d = new TransferData();
            d.setFrom(req.getFrom());
            d.setTo(req.getTo());
            d.setAmount(req.getAmount());
            d.setNonce(req.getNonce());
            d.setTimestamp(req.getTimestamp());
            d.setRecipientCount(req.getRecipientCount());
            d.setTxType(req.getTxType());
            txs.add(d);
        }

        // leaves - now with correct batchId in each leaf hash
        List<byte[]> leaves = new ArrayList<>();
        for (TransferData d : txs) {
            leaves.add(merkleTreeService.leafHash(d, batchSalt));
        }

        String rootHex = merkleTreeService.computeMerkleRoot(leaves);

        // stored transfers with proofs
        List<StoredTransfer> stored = new ArrayList<>();
        for (int i = 0; i < txs.size(); i++) {
            TransferData tx = txs.get(i);
            StoredTransfer st = new StoredTransfer();
            st.setTxData(tx);
            st.setTxProof(merkleTreeService.buildProof(leaves, i));
            
            // Generate whitelist proof for BATCHED transactions (txType=2)
            if (tx.getTxType() == 2) { // BATCHED
                List<String> whitelistProof = whitelistService.generateWhitelistProof(tx.getFrom());
                st.setWhitelistProof(whitelistProof);
            } else {
                // DELAYED (0), INSTANT (1), FREE_TIER (3) don't need whitelist proof
                st.setWhitelistProof(List.of());
            }
            
            st.setExecuted(false);
            stored.add(st);
        }

        // Call contract: submitBatch(root, txCount)
        BatchSubmission submission = settlementClient.submitBatchWithTxId(rootHex, txs.size(), batchSalt);
        long onChainBatchId = submission.batchId();

        // Set batchId in each TransferData (for storage/tracking purposes only, NOT for hash)
        stored.forEach(st -> st.getTxData().setBatchId(onChainBatchId));

        // Build LocalBatch and save in repository
        LocalBatch batch = new LocalBatch();
        batch.setOnChainBatchId(onChainBatchId);
        batch.setSubmitTxId(submission.submitTxId());
        batch.setMerkleRootHex(rootHex);
        batch.setTxCount(submission.txCount());
        batch.setStatus(BatchStatus.SUBMITTED_ONCHAIN);
        batch.setSubmittedAt(submission.submittedAt());
        batch.setUnlockTime(submission.unlockTime());
        batch.setBatchSalt(batchSalt);
        batch.setTransfers(stored);

        batchRepository.save(batch);
    }

    public List<LocalBatch> getBatches() {
        return batchRepository.findAll();
    }

    public LocalBatch getByOnChainBatchId(long onChainBatchId) {
        return batchRepository.findByOnChainBatchId(onChainBatchId)
                .orElseThrow(() -> new IllegalArgumentException("Batch not found: " + onChainBatchId));
    }

    public LocalBatch getByMerkleRoot(String merkleRootHex) {
        return batchRepository.findByMerkleRoot(merkleRootHex)
                .orElseThrow(() -> new IllegalArgumentException("Batch not found for root: " + merkleRootHex));
    }
}
