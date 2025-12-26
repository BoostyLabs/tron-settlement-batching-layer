package dao.tron.tsol.service;

import dao.tron.tsol.config.SettlementProperties;
import dao.tron.tsol.event.BatchSubmittedEvent;
import dao.tron.tsol.event.BatchSubmittedEventReader;
import dao.tron.tsol.model.StoredTransfer;
import dao.tron.tsol.model.TransferData;
import lombok.Getter;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.tron.trident.abi.FunctionEncoder;
import org.tron.trident.abi.FunctionReturnDecoder;
import org.tron.trident.abi.TypeReference;
import org.tron.trident.abi.datatypes.*;
import org.tron.trident.abi.datatypes.generated.Bytes32;
import org.tron.trident.abi.datatypes.generated.Uint256;
import org.tron.trident.abi.datatypes.generated.Uint32;
import org.tron.trident.abi.datatypes.generated.Uint48;
import org.tron.trident.abi.datatypes.generated.Uint64;
import org.tron.trident.abi.datatypes.generated.Uint8;
import org.tron.trident.core.ApiWrapper;
import org.tron.trident.core.NodeType;
import org.tron.trident.proto.Chain;
import org.tron.trident.proto.Response;
import org.tron.trident.utils.Numeric;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.time.Duration;
import java.util.concurrent.ThreadLocalRandom;

@Slf4j
@Service
public class SettlementContractClientTrident implements SettlementContractClient {

    private final ApiWrapper wrapper;
    @Getter
    private final String aggregatorAddress;
    private final String contractAddress;
    private final BatchSubmittedEventReader eventReader;
    private final SettlementProperties.Polling polling;
    /**
     * Guard signing/broadcasting so concurrent execution doesn't trip over non-thread-safe internals.
     * Receipt polling is intentionally done outside this lock.
     */
    private final Object broadcastLock = new Object();

    private static final long DEFAULT_FEE_LIMIT = 100_000_000L;

    public SettlementContractClientTrident(SettlementProperties props, BatchSubmittedEventReader eventReader) {
        this.contractAddress = props.getContractAddress();
        this.eventReader = eventReader;
        this.polling = props.getPolling();

        String privateKey = props.getPrivateKey();
        if (privateKey == null || privateKey.isEmpty() || privateKey.equals("YOUR_PRIVATE_KEY_HERE")) {
            log.warn("No valid private key configured. Set UPDATER_PRIVATE_KEY to enable blockchain operations.");
            this.wrapper = null;
            this.aggregatorAddress = "NOT_CONFIGURED";
            return;
        }

        if (privateKey.length() % 2 != 0) {
            log.error("Invalid private key format: odd-length hex string");
            this.wrapper = null;
            this.aggregatorAddress = "INVALID_KEY_FORMAT";
            return;
        }

        ApiWrapper tempWrapper;
        String tempAggregatorAddress;
        
        try {
            tempWrapper = ApiWrapper.ofNile(privateKey);
            tempAggregatorAddress = tempWrapper.keyPair.toBase58CheckAddress();
            log.info("SettlementContractClientTrident initialized: aggregator={}, contract={}", 
                    tempAggregatorAddress, contractAddress);
        } catch (Exception e) {
            log.error("Failed to initialize: {}", e.getMessage());
            tempWrapper = null;
            tempAggregatorAddress = "INIT_FAILED";
        }
        
        this.wrapper = tempWrapper;
        this.aggregatorAddress = tempAggregatorAddress;
    }

    @Override
    public long submitBatch(String merkleRootHex, int txCount, long batchSalt) {
        return submitBatchWithTxId(merkleRootHex, txCount, batchSalt).batchId();
    }

    @Override
    public BatchSubmission submitBatchWithTxId(String merkleRootHex, int txCount, long batchSalt) {
        try {
            String cleanRoot = cleanHex(merkleRootHex);
            byte[] rootBytes = Numeric.hexStringToByteArray(cleanRoot);
            if (rootBytes.length != 32) {
                throw new IllegalArgumentException("Merkle root must be 32 bytes, got " + rootBytes.length);
            }

            Function submitBatchFn = new Function(
                    "submitBatch",
                    Arrays.asList(
                            new Bytes32(rootBytes),
                            new Uint32(BigInteger.valueOf(txCount)),
                            new Uint64(BigInteger.valueOf(batchSalt))
                    ),
                    Arrays.asList(
                            new TypeReference<Bool>() {},
                            new TypeReference<Uint64>() {}
                    )
            );

            String encodedHex = FunctionEncoder.encode(submitBatchFn);

            Response.TransactionExtention txnExt = wrapper.triggerContract(
                    aggregatorAddress,
                    contractAddress,
                    encodedHex,
                    0L,
                    0L,
                    null,
                    DEFAULT_FEE_LIMIT
            );

            if (!txnExt.getResult().getResult()) {
                String msg = txnExt.getResult().getMessage().toStringUtf8();
                throw new RuntimeException("submitBatch trigger failed: " + msg);
            }

            String txId;
            synchronized (broadcastLock) {
                Chain.Transaction signed = wrapper.signTransaction(txnExt);
                txId = wrapper.broadcastTransaction(signed);
            }

            // Make failures explicit (revert/OUT_OF_ENERGY/etc.) rather than timing out on event polling.
            Response.TransactionInfo txInfo = waitForTxInfo(
                    txId,
                    Duration.ofSeconds(polling.getTxInfoTimeoutSeconds()),
                    Duration.ofMillis(polling.getTxInfoPollInitialMs()),
                    Duration.ofMillis(polling.getTxInfoPollMaxMs())
            );
            if (txInfo == null) {
                throw new RuntimeException("submitBatch failed: no TransactionInfo after timeout. txId=" + txId);
            }
            if (txInfo.getResult() != Response.TransactionInfo.code.SUCESS) {
                String errorMsg = txInfo.getResMessage() != null ? txInfo.getResMessage().toStringUtf8() : "Unknown error";
                throw new RuntimeException("submitBatch failed on-chain: " + errorMsg + ". txId=" + txId);
            }

            // Prefer event parsing (source of truth for batchId)
            var evOpt = eventReader.readWithTimeout(
                    txId,
                    Duration.ofSeconds(polling.getBatchSubmittedTimeoutSeconds()),
                    Duration.ofMillis(polling.getBatchSubmittedPollInitialMs())
            );
            if (evOpt.isPresent()) {
                BatchSubmittedEvent ev = evOpt.get();
                if (!cleanHex(ev.merkleRootHex()).equalsIgnoreCase(cleanHex(merkleRootHex))) {
                    log.warn("BatchSubmitted merkleRoot mismatch: expected={}, got={}", merkleRootHex, ev.merkleRootHex());
                }
                if (ev.txCount() != txCount) {
                    log.warn("BatchSubmitted txCount mismatch: expected={}, got={}", txCount, ev.txCount());
                }
                long unlockTime = getUnlockTime(ev.batchId());
                return new BatchSubmission(txId, ev.batchId(), merkleRootHex, txCount, ev.timestamp(), unlockTime);
            }

            // Fallback: poll getBatchIdByRoot(root) until non-zero
            long batchId = pollBatchIdByRoot(merkleRootHex, Duration.ofSeconds(polling.getBatchSubmittedTimeoutSeconds()));
            if (batchId == 0L) {
                throw new RuntimeException("submitBatch failed: could not resolve batchId from event or getBatchIdByRoot within timeout. txId=" + txId);
            }
            OnChainBatch b = getBatchById(batchId);
            return new BatchSubmission(txId, batchId, merkleRootHex, txCount, b.timestamp(), b.unlockTime());
        } catch (Exception e) {
            log.error("submitBatch failed", e);
            throw new RuntimeException("submitBatch failed: " + e.getMessage(), e);
        }
    }

    private Response.TransactionInfo waitForTxInfo(String txId, Duration timeout, Duration pollInitial, Duration pollMax) {
        long deadline = System.currentTimeMillis() + timeout.toMillis();
        long sleepMs = Math.max(100, pollInitial.toMillis());
        long maxSleepMs = Math.max(sleepMs, pollMax.toMillis());
        while (System.currentTimeMillis() < deadline) {
            try {
                Response.TransactionInfo info = wrapper.getTransactionInfoById(txId);
                if (info != null) return info;
            } catch (Exception ignored) {}
            try {
                long jitter = ThreadLocalRandom.current().nextLong(0, 150);
                Thread.sleep(sleepMs + jitter);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                return null;
            }
            sleepMs = Math.min(maxSleepMs, (long) Math.ceil(sleepMs * 1.5));
        }
        return null;
    }

    @Override
    public long getUnlockTime(long batchId) {
        try {
            Function getBatchFn = new Function(
                    "getBatchById",
                    Collections.singletonList(new Uint64(batchId)),
                    Arrays.asList(
                            new TypeReference<Bytes32>() {},
                            new TypeReference<Uint256>() {},
                            new TypeReference<Uint256>() {},
                            new TypeReference<Uint256>() {},
                            new TypeReference<Uint64>() {}
                    )
            );

            String encodedHex = FunctionEncoder.encode(getBatchFn);

            Response.TransactionExtention txn = wrapper.triggerConstantContract(
                    aggregatorAddress,
                    contractAddress,
                    encodedHex,
                    NodeType.SOLIDITY_NODE
            );

            if (!txn.getResult().getResult()) {
                throw new RuntimeException("getBatchById failed: " + txn.getResult().getMessage().toStringUtf8());
            }

            if (txn.getConstantResultCount() == 0) {
                throw new IllegalStateException("No constantResult for getBatchById");
            }

            String resultHex = Numeric.toHexString(txn.getConstantResult(0).toByteArray());
            @SuppressWarnings("rawtypes")
            List<Type> decoded =
                    FunctionReturnDecoder.decode(resultHex, getBatchFn.getOutputParameters());

            if (decoded.size() != 5) {
                throw new IllegalStateException("Unexpected getBatchById outputs=" + decoded.size());
            }

            Uint256 unlockTime = (Uint256) decoded.get(3);
            return unlockTime.getValue().longValue();
        } catch (Exception e) {
            log.error("getUnlockTime failed", e);
            throw new RuntimeException("getUnlockTime failed: " + e.getMessage(), e);
        }
    }

    @Override
    public void executeTransfer(StoredTransfer transfer) {
        try {
            TransferData d = transfer.getTxData();

            List<Bytes32> txProofElems = new ArrayList<>();
            for (String hex : transfer.getTxProof()) {
                byte[] b = Numeric.hexStringToByteArray(cleanHex(hex));
                if (b.length != 32) {
                    throw new IllegalArgumentException("txProof element not 32 bytes: " + hex);
                }
                txProofElems.add(new Bytes32(b));
            }
            DynamicArray<Bytes32> txProofArray = new DynamicArray<>(Bytes32.class, txProofElems);

            List<Bytes32> wlProofElems = new ArrayList<>();
            for (String hex : transfer.getWhitelistProof()) {
                byte[] b = Numeric.hexStringToByteArray(cleanHex(hex));
                if (b.length != 32) {
                    throw new IllegalArgumentException("whitelistProof element not 32 bytes: " + hex);
                }
                wlProofElems.add(new Bytes32(b));
            }
            DynamicArray<Bytes32> wlProofArray = new DynamicArray<>(Bytes32.class, wlProofElems);

            StaticStruct txDataTuple = new StaticStruct(
                    new Address(d.getFrom()),
                    new Address(d.getTo()),
                    new Uint256(new BigInteger(d.getAmount())),
                    new Uint64(BigInteger.valueOf(d.getNonce())),
                    new Uint48(BigInteger.valueOf(d.getTimestamp())),
                    new Uint32(BigInteger.valueOf(d.getRecipientCount())),
                    new Uint64(BigInteger.valueOf(d.getBatchId())),
                    new Uint8(d.getTxType())
            );

            Function execFn = new Function(
                    "executeTransfer",
                    Arrays.asList(txProofArray, wlProofArray, txDataTuple),
                    Collections.singletonList(new TypeReference<Bool>() {})
            );

            String encodedHex = FunctionEncoder.encode(execFn);

            Response.TransactionExtention txnExt = wrapper.triggerContract(
                    aggregatorAddress,
                    contractAddress,
                    encodedHex,
                    0L,
                    0L,
                    null,
                    DEFAULT_FEE_LIMIT
            );

            if (!txnExt.getResult().getResult()) {
                throw new RuntimeException("executeTransfer trigger failed: " + txnExt.getResult().getMessage().toStringUtf8());
            }

            String txId;
            synchronized (broadcastLock) {
                Chain.Transaction signed = wrapper.signTransaction(txnExt);
                txId = wrapper.broadcastTransaction(signed);
            }
            transfer.setExecutionTxId(txId);
            // Don't hard-sleep: poll receipt until available (faster on good days, clearer failure on reverts).
            Response.TransactionInfo txInfo = waitForTxInfo(
                    txId,
                    Duration.ofSeconds(polling.getTxInfoTimeoutSeconds()),
                    Duration.ofMillis(polling.getTxInfoPollInitialMs()),
                    Duration.ofMillis(polling.getTxInfoPollMaxMs())
            );
            if (txInfo == null) {
                throw new RuntimeException("Transaction failed: no TransactionInfo after timeout. txId=" + txId);
            }
            if (txInfo.getResult() != Response.TransactionInfo.code.SUCESS) {
                String errorMsg = txInfo.getResMessage() != null ? txInfo.getResMessage().toStringUtf8() : "Unknown error";
                throw new RuntimeException("Transaction failed: " + errorMsg + ". txId=" + txId);
            }
            
            log.info("executeTransfer SUCCESS: txId={}", txId);
                    
        } catch (Exception e) {
            log.error("executeTransfer failed", e);
            throw new RuntimeException("executeTransfer failed: " + e.getMessage(), e);
        }
    }

    private String cleanHex(String value) {
        if (value == null) return "";
        return (value.startsWith("0x") || value.startsWith("0X"))
                ? value.substring(2)
                : value;
    }

    private long pollBatchIdByRoot(String merkleRootHex, Duration timeout) {
        long deadline = System.currentTimeMillis() + timeout.toMillis();
        while (System.currentTimeMillis() < deadline) {
            try {
                long id = getBatchIdByRoot(merkleRootHex);
                if (id != 0L) return id;
            } catch (Exception ignored) {}
            try { Thread.sleep(1000); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); return 0L; }
        }
        return 0L;
    }

    private record OnChainBatch(String merkleRootHex, long timestamp, int txCount, long unlockTime, long batchSalt) {}

    private OnChainBatch getBatchById(long batchId) {
        Function getBatchFn = new Function(
                "getBatchById",
                Collections.singletonList(new Uint64(batchId)),
                Arrays.asList(
                        new TypeReference<Bytes32>() {},
                        new TypeReference<Uint256>() {},
                        new TypeReference<Uint256>() {},
                        new TypeReference<Uint256>() {},
                        new TypeReference<Uint64>() {}
                )
        );

        String encodedHex = FunctionEncoder.encode(getBatchFn);
        Response.TransactionExtention txn = wrapper.triggerConstantContract(
                aggregatorAddress,
                contractAddress,
                encodedHex,
                NodeType.SOLIDITY_NODE
        );
        if (!txn.getResult().getResult() || txn.getConstantResultCount() == 0) {
            throw new RuntimeException("getBatchById query failed");
        }
        String resultHex = Numeric.toHexString(txn.getConstantResult(0).toByteArray());
        @SuppressWarnings("rawtypes")
        List<Type> decoded =
                FunctionReturnDecoder.decode(resultHex, getBatchFn.getOutputParameters());
        if (decoded.size() != 5) {
            throw new IllegalStateException("Unexpected getBatchById outputs=" + decoded.size());
        }
        Bytes32 root = (Bytes32) decoded.get(0);
        Uint256 timestamp = (Uint256) decoded.get(1);
        Uint256 txCount = (Uint256) decoded.get(2);
        Uint256 unlock = (Uint256) decoded.get(3);
        Uint64 batchSalt = (Uint64) decoded.get(4);
        return new OnChainBatch(
                "0x" + Numeric.toHexStringNoPrefix(root.getValue()),
                timestamp.getValue().longValue(),
                txCount.getValue().intValue(),
                unlock.getValue().longValue(),
                batchSalt.getValue().longValue()
        );
    }

    private long getBatchIdByRoot(String merkleRootHex) {
        String cleanRoot = cleanHex(merkleRootHex);
        byte[] rootBytes = Numeric.hexStringToByteArray(cleanRoot);
        if (rootBytes.length != 32) throw new IllegalArgumentException("Merkle root must be 32 bytes");

        Function fn = new Function(
                "getBatchIdByRoot",
                Collections.singletonList(new Bytes32(rootBytes)),
                Collections.singletonList(new TypeReference<Uint64>() {})
        );

        String encodedHex = FunctionEncoder.encode(fn);
        Response.TransactionExtention txn = wrapper.triggerConstantContract(
                aggregatorAddress,
                contractAddress,
                encodedHex,
                NodeType.SOLIDITY_NODE
        );
        if (!txn.getResult().getResult() || txn.getConstantResultCount() == 0) {
            return 0L;
        }
        String resultHex = Numeric.toHexString(txn.getConstantResult(0).toByteArray());
        @SuppressWarnings("rawtypes")
        List<Type> decoded =
                FunctionReturnDecoder.decode(resultHex, fn.getOutputParameters());
        if (decoded.isEmpty()) return 0L;
        Uint64 v = (Uint64) decoded.getFirst();
        return v.getValue().longValue();
    }
}
