package dao.tron.tsol.repository;


import dao.tron.tsol.model.LocalBatch;

import java.util.List;
import java.util.Optional;

public interface BatchRepository {

    void save(LocalBatch batch);

    List<LocalBatch> findAll();

    Optional<LocalBatch> findByLocalId(long localId);

    Optional<LocalBatch> findByOnChainBatchId(long onChainBatchId);

    Optional<LocalBatch> findByMerkleRoot(String merkleRootHex);
}
