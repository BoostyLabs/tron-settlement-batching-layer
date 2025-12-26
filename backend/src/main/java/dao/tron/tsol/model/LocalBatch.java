package dao.tron.tsol.model;

import lombok.Data;

import java.util.List;

@Data
public class LocalBatch {

    private long localId;
    private long onChainBatchId;
    private String submitTxId;
    private String merkleRootHex;
    private int txCount;
    private long submittedAt; // unix seconds (from BatchSubmitted event)
    private long unlockTime; // unix seconds
    /**
     * Salt used when computing txHash/leaf hashes for this batch.
     * MUST match the value passed to on-chain submitBatch(..., batchSalt).
     *
     * Note: batchId is NOT part of txHash anymore; only batchSalt is.
     */
    private long batchSalt;
    private BatchStatus status;
    private List<StoredTransfer> transfers;
}
