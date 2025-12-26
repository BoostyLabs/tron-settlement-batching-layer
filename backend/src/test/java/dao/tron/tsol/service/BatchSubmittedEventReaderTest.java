package dao.tron.tsol.service;

import dao.tron.tsol.event.BatchSubmittedEvent;
import dao.tron.tsol.event.BatchSubmittedEventReader;
import org.junit.jupiter.api.Test;

import java.math.BigInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;

class BatchSubmittedEventReaderTest {

    @Test
    void decodeLogData_decodesAllFields() {
        long batchId = 7L;
        String merkleRoot = "0x" + "11".repeat(32);
        int txCount = 2;
        long timestamp = 123456L;

        String dataHex =
                "0x"
                        + pad32(BigInteger.valueOf(batchId))
                        + strip0x(merkleRoot)
                        + pad32(BigInteger.valueOf(txCount))
                        + pad32(BigInteger.valueOf(timestamp));

        BatchSubmittedEvent ev = BatchSubmittedEventReader.decodeLogData(dataHex);
        assertEquals(batchId, ev.batchId());
        assertEquals(merkleRoot.toLowerCase(), ev.merkleRootHex().toLowerCase());
        assertEquals(txCount, ev.txCount());
        assertEquals(timestamp, ev.timestamp());
    }

    @Test
    void decodeIndexedLog_decodesIndexedBatchIdAndRoot_plusDataFields() {
        long batchId = 9L;
        String merkleRoot = "0x" + "aa".repeat(32);
        int txCount = 5;
        long timestamp = 999L;

        String topicBatchId = "0x" + pad32(BigInteger.valueOf(batchId));
        String topicMerkleRoot = merkleRoot;
        String dataHex =
                "0x"
                        + pad32(BigInteger.valueOf(txCount))
                        + pad32(BigInteger.valueOf(timestamp));

        BatchSubmittedEvent ev = BatchSubmittedEventReader.decodeIndexedLog(topicBatchId, topicMerkleRoot, dataHex);
        assertEquals(batchId, ev.batchId());
        assertEquals(merkleRoot.toLowerCase(), ev.merkleRootHex().toLowerCase());
        assertEquals(txCount, ev.txCount());
        assertEquals(timestamp, ev.timestamp());
    }

    private static String pad32(BigInteger v) {
        String h = v.toString(16);
        return "0".repeat(64 - h.length()) + h;
    }

    private static String strip0x(String h) {
        return h.startsWith("0x") ? h.substring(2) : h;
    }
}


