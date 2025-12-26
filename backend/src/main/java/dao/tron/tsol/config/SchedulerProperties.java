package dao.tron.tsol.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Data
@Component
@ConfigurationProperties(prefix = "scheduler")
public class SchedulerProperties {
    
    private BatchingConfig batching = new BatchingConfig();
    private ExecutionConfig execution = new ExecutionConfig();
    
    @Data
    public static class BatchingConfig {
        /**
         * Enable/disable automatic batching
         * Default: true
         */
        private boolean enabled = true;

        /**
         * Maximum number of intents before triggering batch creation
         * Default: 5 intents
         */
        private int maxIntents = 5;
        
        /**
         * Maximum delay in seconds before triggering batch creation
         * Default: 30 seconds
         */
        private long maxDelaySeconds = 30;
        
        /**
         * How often to check for batching conditions (in milliseconds)
         * Default: 3000ms (3 seconds)
         */
        private long checkIntervalMs = 3000;
    }
    
    @Data
    public static class ExecutionConfig {
        /**
         * How often to check for unlocked batches to execute (in milliseconds)
         * Default: 5000ms (5 seconds)
         */
        private long checkIntervalMs = 5000;
        
        /**
         * Enable/disable automatic execution
         * Default: true
         */
        private boolean enabled = true;

        /**
         * Max number of transfers to execute concurrently per batch.
         * Default: 3 (bounded parallelism; improves throughput while staying gentle on public nodes).
         */
        private int maxParallel = 3;
    }
}










