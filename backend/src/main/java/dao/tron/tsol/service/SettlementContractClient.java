package dao.tron.tsol.service;


public interface SettlementContractClient {

    long submitBatch(String merkleRootHex, int txCount, long batchSalt);

    BatchSubmission submitBatchWithTxId(String merkleRootHex, int txCount, long batchSalt);

    long getUnlockTime(long batchId);

    void executeTransfer(dao.tron.tsol.model.StoredTransfer transfer);
}
