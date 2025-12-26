package dao.tron.tsol.service;

import dao.tron.tsol.config.SchedulerProperties;
import dao.tron.tsol.model.BatchStatus;
import dao.tron.tsol.model.LocalBatch;
import dao.tron.tsol.model.StoredTransfer;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;

@Slf4j
@Service
public class ExecutionService {

    private final SettlementContractClient settlementClient;
    private final SchedulerProperties schedulerProps;
    private final ExecutorService executor;

    public ExecutionService(SettlementContractClient settlementClient, SchedulerProperties schedulerProps) {
        this.settlementClient = settlementClient;
        this.schedulerProps = schedulerProps;
        // Upper bound to avoid accidental massive fan-out; can be increased if needed.
        int threadSize = Math.max(1, Math.min(8, schedulerProps.getExecution().getMaxParallel()));
        this.executor = Executors.newFixedThreadPool(threadSize);
    }

    public void executeAll(LocalBatch batch) {
        batch.setStatus(BatchStatus.EXECUTING);

        int maxParallel = Math.max(1, schedulerProps.getExecution().getMaxParallel());
        if (maxParallel == 1) {
            executeSequential(batch);
            return;
        }

        // Pre-fix missing batchId once to avoid repeated warnings in parallel tasks.
        for (StoredTransfer st : batch.getTransfers()) {
            if (st.isExecuted()) continue;
            long batchId = st.getTxData().getBatchId();
            if (batchId == 0) {
                st.getTxData().setBatchId(batch.getOnChainBatchId());
            }
        }

        List<CompletableFuture<Boolean>> futures = new ArrayList<>();
        for (StoredTransfer st : batch.getTransfers()) {
            if (st.isExecuted()) continue;
            futures.add(CompletableFuture.supplyAsync(() -> executeOne(st), executor));
        }

        boolean allOk = true;
        for (CompletableFuture<Boolean> f : futures) {
            try {
                allOk &= f.get();
            } catch (Exception e) {
                allOk = false;
                log.error("Transfer execution task failed: {}", e.getMessage());
            }
        }

        batch.setStatus(allOk ? BatchStatus.COMPLETED : BatchStatus.FAILED);
        log.info("Batch {} execution finished: status={} (maxParallel={})", batch.getOnChainBatchId(), batch.getStatus(), maxParallel);
    }

    private void executeSequential(LocalBatch batch) {
        boolean allOk = true;
        for (StoredTransfer st : batch.getTransfers()) {
            if (st.isExecuted()) continue;

            long batchId = st.getTxData().getBatchId();
            if (batchId == 0) {
                log.warn("Transfer missing batchId, setting to: {}", batch.getOnChainBatchId());
                st.getTxData().setBatchId(batch.getOnChainBatchId());
            }

            allOk &= executeOne(st);
        }

        batch.setStatus(allOk ? BatchStatus.COMPLETED : BatchStatus.FAILED);
        log.info("Batch {} execution finished: status={} (sequential)", batch.getOnChainBatchId(), batch.getStatus());
    }

    private boolean executeOne(StoredTransfer st) {
        try {
            settlementClient.executeTransfer(st);
            st.setExecuted(true);
            log.info("Transfer executed: from={}, to={}, amount={}",
                    st.getTxData().getFrom(), st.getTxData().getTo(), st.getTxData().getAmount());
            return true;
        } catch (Exception e) {
            log.error("Transfer execution failed: from={}, to={}, error={}",
                    st.getTxData().getFrom(), st.getTxData().getTo(), e.getMessage());
            return false;
        }
    }

    @jakarta.annotation.PreDestroy
    public void shutdown() {
        executor.shutdown();
    }
}
