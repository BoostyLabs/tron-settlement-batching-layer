package dao.tron.tsol.service;

/**
 * Result of submitBatch() including txId and resolved batchId.
 */
public record BatchSubmission(
        String submitTxId,
        long batchId,
        String merkleRootHex,
        int txCount,
        long submittedAt,
        long unlockTime
) {}





