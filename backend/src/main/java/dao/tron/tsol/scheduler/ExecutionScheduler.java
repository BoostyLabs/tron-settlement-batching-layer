package dao.tron.tsol.scheduler;

import dao.tron.tsol.config.SchedulerProperties;
import dao.tron.tsol.model.BatchStatus;
import dao.tron.tsol.model.LocalBatch;
import dao.tron.tsol.service.BatchService;
import dao.tron.tsol.service.ExecutionService;
import dao.tron.tsol.service.SettlementContractClient;
import dao.tron.tsol.service.WhitelistService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.List;

@Slf4j
@Component
public class ExecutionScheduler {

    private final BatchService batchService;
    private final SettlementContractClient settlementClient;
    private final ExecutionService executionService;
    private final SchedulerProperties schedulerProps;
    private final WhitelistService whitelistService;

    public ExecutionScheduler(BatchService batchService,
                              SettlementContractClient settlementClient,
                              ExecutionService executionService,
                              SchedulerProperties schedulerProps,
                              WhitelistService whitelistService) {
        this.batchService = batchService;
        this.settlementClient = settlementClient;
        this.executionService = executionService;
        this.schedulerProps = schedulerProps;
        this.whitelistService = whitelistService;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void syncWhitelistRootOnStartup() {
        // Script-equivalent: ensure whitelist root is correct before any BATCHED txType=2 execution.
        try {
            if (!whitelistService.ensureWhitelistRootMatchesConfig()) {
                log.warn("Whitelist root sync did not succeed (txType=2 may revert as NotWhitelisted).");
            }
        } catch (Exception e) {
            log.warn("Whitelist root sync failed (txType=2 may revert as NotWhitelisted): {}", e.getMessage());
        }
    }

    @Scheduled(fixedDelayString = "${scheduler.execution.check-interval-ms:5000}")
    public void executeUnlockedBatches() {
        if (!schedulerProps.getExecution().isEnabled()) {
            return;
        }
        
        long now = System.currentTimeMillis() / 1000L;
        List<LocalBatch> batches = batchService.getBatches();

        if (batches.isEmpty()) {
            return;
        }

        for (LocalBatch batch : batches) {
            if (batch.getStatus() != BatchStatus.SUBMITTED_ONCHAIN &&
                    batch.getStatus() != BatchStatus.UNLOCKED) {
                continue;
            }

            if (batch.getUnlockTime() == 0L) {
                try {
                    long unlockTime = settlementClient.getUnlockTime(batch.getOnChainBatchId());
                    batch.setUnlockTime(unlockTime);
                    log.info("Batch {} unlock time: {} (now: {})", batch.getOnChainBatchId(), unlockTime, now);
                } catch (Exception e) {
                    log.warn("Batch {} not found on-chain. Marking as failed.", batch.getOnChainBatchId());
                    batch.setStatus(BatchStatus.FAILED);
                    continue;
                }
            }

            if (now < batch.getUnlockTime()) {
                continue;
            }

            log.info("Executing batch {} (onChainId={})", batch.getLocalId(), batch.getOnChainBatchId());
            
            executionService.executeAll(batch);
            log.info("Batch {} execution complete", batch.getOnChainBatchId());
        }
    }
}
