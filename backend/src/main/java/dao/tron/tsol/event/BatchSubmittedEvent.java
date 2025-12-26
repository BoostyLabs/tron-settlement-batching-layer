package dao.tron.tsol.event;

/**
 * DTO representing the Settlement BatchSubmitted event.
 *
 * Solidity:
 * event BatchSubmitted(uint64 batchId, bytes32 merkleRoot, uint32 txCount, uint48 timestamp);
 *
 * NOTE:
 * - Older contracts emitted all params as non-indexed (all values in log.data)
 * - Newer contracts index batchId + merkleRoot (so those are in topics, while txCount+timestamp are in log.data)
 *
 * This record represents the fully decoded values independent of how they were indexed.
 */
public record BatchSubmittedEvent(
        long batchId,
        String merkleRootHex,
        int txCount,
        long timestamp
) {}


