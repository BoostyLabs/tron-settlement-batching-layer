package dao.tron.tsol.event;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.tron.trident.core.ApiWrapper;
import org.tron.trident.proto.Response;
import org.tron.trident.utils.Numeric;
import org.web3j.abi.FunctionReturnDecoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.datatypes.Type;
import org.web3j.abi.datatypes.generated.Bytes32;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.abi.datatypes.generated.Uint32;
import org.web3j.abi.datatypes.generated.Uint64;
import org.web3j.crypto.Hash;

import java.time.Duration;
import java.util.concurrent.ThreadLocalRandom;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Optional;

/**
 * Reads Settlement BatchSubmitted event from TRON tx receipt logs using Trident.
 * <p>
 * Requirements:
 * - poll ApiWrapper.getTransactionInfoById(txid)
 * - scan TransactionInfo.log[] topics for topic0 == keccak256("BatchSubmitted(uint64,bytes32,uint32,uint48)")
 * - decode indexed params from topics when present (new contracts index batchId and merkleRoot)
 * - decode log.data for non-indexed params (txCount, timestamp)
 * - fallback handled elsewhere
 */
@Slf4j
@Service
public class BatchSubmittedEventReader {

    public static final String EVENT_SIGNATURE = "BatchSubmitted(uint64,bytes32,uint32,uint48)";

    // topic0 = keccak256(eventSignature)
    private static final String TOPIC0_HEX = Hash.sha3String(EVENT_SIGNATURE); // 0x...
    private static final String TOPIC0_NORM32 = normalizeHexN(TOPIC0_HEX).toLowerCase(Locale.ROOT);

    private final ApiWrapper wrapper;

    public BatchSubmittedEventReader(dao.tron.tsol.config.SettlementProperties settlementProps) {
        String privateKey = settlementProps.getPrivateKey();
        if (privateKey == null || privateKey.isBlank() || privateKey.equals("YOUR_PRIVATE_KEY_HERE")) {
            this.wrapper = null;
            log.warn("BatchSubmittedEventReader: missing UPDATER_PRIVATE_KEY, event reading disabled.");
        } else {
            this.wrapper = ApiWrapper.ofNile(privateKey);
        }
    }

    public Optional<BatchSubmittedEvent> readWithTimeout(String txId, Duration timeout, Duration pollInterval) {
        if (wrapper == null) return Optional.empty();
        long deadline = System.currentTimeMillis() + timeout.toMillis();
        long sleepMs = Math.max(200, pollInterval.toMillis());
        // Cap backoff at ~5x the initial interval (or 3s minimum cap).
        long maxSleepMs = Math.max(sleepMs * 5, 3000L);

        while (System.currentTimeMillis() < deadline) {
            Response.TransactionInfo info;
            try {
                info = wrapper.getTransactionInfoById(txId);
            } catch (Exception e) {
                log.debug("txInfo not available yet for {}: {}", txId, e.getMessage());
                info = null;
            }

            if (info != null) {
                Optional<BatchSubmittedEvent> ev = findEventInTxInfo(info);
                if (ev.isPresent()) return ev;
            }

            // Backoff + jitter to reduce load on public nodes (especially when many txs are in-flight).
            long jitter = ThreadLocalRandom.current().nextLong(0, 150);
            if (!sleepQuietly(sleepMs + jitter)) return Optional.empty();
            sleepMs = Math.min(maxSleepMs, (long) Math.ceil(sleepMs * 1.5));
        }

        return Optional.empty();
    }

    public Optional<BatchSubmittedEvent> findEventInTxInfo(Response.TransactionInfo info) {
        if (info == null) return Optional.empty();

        // TRON: receipt/logs may exist even if reverted; caller should validate receipt separately if desired.
        int logCount = info.getLogCount();
        if (logCount == 0) return Optional.empty();

        for (int i = 0; i < logCount; i++) {
            Response.TransactionInfo.Log l = info.getLog(i);
            if (l.getTopicsCount() == 0) continue;

            String topic0 = Numeric.toHexString(l.getTopics(0).toByteArray());
            if (!normalizeHexN(topic0).equalsIgnoreCase(TOPIC0_NORM32)) {
                continue;
            }

            try {
                // New Settlement contract (per sc/src/interfaces/ISettlement.sol):
                // event BatchSubmitted(uint64 indexed batchId, bytes32 indexed merkleRoot, uint32 txCount, uint48 timestamp);
                if (l.getTopicsCount() >= 3) {
                    String topicBatchId = Numeric.toHexString(l.getTopics(1).toByteArray());
                    String topicMerkleRoot = Numeric.toHexString(l.getTopics(2).toByteArray());
                    String dataHex = Numeric.toHexString(l.getData().toByteArray());
                    return Optional.of(decodeIndexedLog(topicBatchId, topicMerkleRoot, dataHex));
                }

                // Backward-compatibility: if contracts ever change to non-indexed params.
                String dataHex = Numeric.toHexString(l.getData().toByteArray());
                return Optional.of(decodeLogData(dataHex));
            } catch (Exception e) {
                log.warn("Failed to decode BatchSubmitted log data for tx {}: {}", info.getId(), e.getMessage());
            }
        }

        return Optional.empty();
    }

    /**
     * Decode ABI log.data for BatchSubmitted(uint64,bytes32,uint32,uint48).
     *
     * Data layout (4 x 32-byte slots):
     * 0: uint64 batchId
     * 1: bytes32 merkleRoot
     * 2: uint32 txCount
     * 3: uint48 timestamp (encoded as uint256 slot)
     */
    public static BatchSubmittedEvent decodeLogData(String dataHex) {
        List<Type<?>> decoded = decodeWeb3Abi(
                dataHex,
                new TypeReference<Uint64>() {},
                new TypeReference<Bytes32>() {},
                new TypeReference<Uint32>() {},
                new TypeReference<Uint256>() {}
        );
        requireDecodedSize(decoded, 4);

        Uint64 batchId = (Uint64) decoded.get(0);
        Bytes32 root = (Bytes32) decoded.get(1);
        Uint32 txCount = (Uint32) decoded.get(2);
        Uint256 ts = (Uint256) decoded.get(3);

        return new BatchSubmittedEvent(
                batchId.getValue().longValue(),
                "0x" + Numeric.toHexStringNoPrefix(root.getValue()),
                txCount.getValue().intValue(),
                ts.getValue().longValue()
        );
    }

    /**
     * Decode indexed BatchSubmitted log:
     * topics[1] = uint64 batchId (left padded to 32 bytes)
     * topics[2] = bytes32 merkleRoot
     * data      = abi.encode(uint32 txCount, uint48 timestamp) => 2x 32-byte slots
     */
    public static BatchSubmittedEvent decodeIndexedLog(String topicBatchIdHex, String topicMerkleRootHex, String dataHex) {
        java.math.BigInteger batchId = Numeric.toBigInt(topicBatchIdHex);
        String merkleRootHex = normalizeHexN(topicMerkleRootHex);

        List<Type<?>> decoded = decodeWeb3Abi(
                dataHex,
                new TypeReference<Uint32>() {},
                new TypeReference<Uint256>() {} // timestamp stored in 32-byte slot
        );
        requireDecodedSize(decoded, 2);

        Uint32 txCount = (Uint32) decoded.get(0);
        Uint256 ts = (Uint256) decoded.get(1);

        return new BatchSubmittedEvent(
                batchId.longValue(),
                merkleRootHex,
                txCount.getValue().intValue(),
                ts.getValue().longValue()
        );
    }

    private static String strip0x(String v) {
        if (v == null) return "";
        return v.startsWith("0x") || v.startsWith("0X") ? v.substring(2) : v;
    }

    private static String ensure0x(String hex) {
        String h = hex == null ? "" : hex;
        return (h.startsWith("0x") || h.startsWith("0X")) ? h : ("0x" + h);
    }

    private static String normalizeHexN(String hex) {
        String c = strip0x(hex);
        int n = 32 * 2;
        // Ensure fixed width: take least-significant bytes, left-pad with 0s
        if (c.length() < n) {
            c = "0".repeat(n - c.length()) + c;
        } else if (c.length() > n) {
            c = c.substring(c.length() - n);
        }
        return "0x" + c;
    }

    private static void requireDecodedSize(List<?> decoded, int expected) {
        if (decoded.size() != expected) {
            throw new IllegalStateException("Unexpected decoded outputs=" + decoded.size() + ", expected=" + expected);
        }
    }

    private static boolean sleepQuietly(long ms) {
        try {
            Thread.sleep(ms);
            return true;
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    private static List<Type<?>> decodeWeb3Abi(String dataHex, TypeReference<?>... outputs) {
        String hex = ensure0x(dataHex);

        @SuppressWarnings({"rawtypes", "unchecked"})
        List<TypeReference<Type>> typed = (List) Arrays.asList(outputs);

        @SuppressWarnings({"rawtypes", "unchecked"})
        List<Type<?>> decoded = (List) FunctionReturnDecoder.decode(hex, typed);
        return decoded;
    }
}


