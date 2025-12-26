package dao.tron.tsol.repository;

import dao.tron.tsol.model.LocalBatch;
import org.springframework.stereotype.Repository;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

@Repository
public class InMemoryBatchRepository implements BatchRepository {

    // key: localId
    private final Map<Long, LocalBatch> batchesByLocalId = new ConcurrentHashMap<>();

    // key: on-chain batchId
    private final Map<Long, Long> localIdByOnChainId = new ConcurrentHashMap<>();

    // key: merkleRootHex
    private final Map<String, Long> localIdByMerkleRoot = new ConcurrentHashMap<>();

    // key: submitTxId
    private final Map<String, Long> localIdBySubmitTxId = new ConcurrentHashMap<>();

    // key: merkleRootHex -> batchId (requested mapping)
    private final Map<String, Long> batchIdByMerkleRoot = new ConcurrentHashMap<>();

    // key: submitTxId -> batchId (requested mapping)
    private final Map<String, Long> batchIdBySubmitTxId = new ConcurrentHashMap<>();

    private final AtomicLong localIdSeq = new AtomicLong(1);

    @Override
    public synchronized void save(LocalBatch batch) {
        // assign localId if new
        if (batch.getLocalId() == 0L) {
            batch.setLocalId(localIdSeq.getAndIncrement());
        }

        batchesByLocalId.put(batch.getLocalId(), batch);

        if (batch.getOnChainBatchId() != 0L) {
            localIdByOnChainId.put(batch.getOnChainBatchId(), batch.getLocalId());
        }

        if (batch.getMerkleRootHex() != null) {
            localIdByMerkleRoot.put(batch.getMerkleRootHex(), batch.getLocalId());
            if (batch.getOnChainBatchId() != 0L) {
                batchIdByMerkleRoot.put(batch.getMerkleRootHex(), batch.getOnChainBatchId());
            }
        }

        if (batch.getSubmitTxId() != null && !batch.getSubmitTxId().isBlank()) {
            localIdBySubmitTxId.put(batch.getSubmitTxId(), batch.getLocalId());
            if (batch.getOnChainBatchId() != 0L) {
                batchIdBySubmitTxId.put(batch.getSubmitTxId(), batch.getOnChainBatchId());
            }
        }

    }

    @Override
    public List<LocalBatch> findAll() {
        return new ArrayList<>(batchesByLocalId.values());
    }

    @Override
    public Optional<LocalBatch> findByLocalId(long localId) {
        return Optional.ofNullable(batchesByLocalId.get(localId));
    }

    @Override
    public Optional<LocalBatch> findByOnChainBatchId(long onChainBatchId) {
        Long localId = localIdByOnChainId.get(onChainBatchId);
        if (localId == null) return Optional.empty();
        return Optional.ofNullable(batchesByLocalId.get(localId));
    }

    @Override
    public Optional<LocalBatch> findByMerkleRoot(String merkleRootHex) {
        Long localId = localIdByMerkleRoot.get(merkleRootHex);
        if (localId == null) return Optional.empty();
        return Optional.ofNullable(batchesByLocalId.get(localId));
    }
}
