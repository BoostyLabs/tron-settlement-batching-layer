package dao.tron.tsol.scheduler;

import dao.tron.tsol.config.SchedulerProperties;
import dao.tron.tsol.service.BatchService;
import dao.tron.tsol.service.TransferIntentService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class BatchingScheduler {

    private final TransferIntentService intentService;
    private final BatchService batchService;
    private final SchedulerProperties schedulerProps;

    public BatchingScheduler(TransferIntentService intentService,
                             BatchService batchService,
                             SchedulerProperties schedulerProps) {
        this.intentService = intentService;
        this.batchService = batchService;
        this.schedulerProps = schedulerProps;
    }

    @Scheduled(fixedDelayString = "${scheduler.batching.check-interval-ms:3000}")
    public void maybeCreateBatch() {
        if (!schedulerProps.getBatching().isEnabled()) {
            return;
        }
        if (intentService.isEmpty()) return;

        int count = intentService.getPendingCount();
        long oldestAge = intentService.getOldestAgeSeconds();

        int maxIntents = schedulerProps.getBatching().getMaxIntents();
        long maxDelaySeconds = schedulerProps.getBatching().getMaxDelaySeconds();

        // IMPORTANT: Require minimum 2 transactions for valid Merkle proofs
        // Single-transaction batches have empty/invalid proofs that fail verification
        if (count < 2) {
            log.debug("Waiting for at least 2 transactions (current: {})", count);
            return;
        }

        if (count >= maxIntents || oldestAge >= maxDelaySeconds) {
            log.info("Creating batch: pendingCount={}, oldestAge={}", count, oldestAge);
            batchService.createAndSubmitBatch(maxIntents);
        }
    }
}
