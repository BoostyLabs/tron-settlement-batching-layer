package dao.tron.tsol.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties(prefix = "settlement")
@Data
public class SettlementProperties {

    /**
     * gRPC or HTTP endpoint for TRON node
     * Example: grpc.nile.trongrid.io:50051
     */
    private String nodeEndpoint;

    /**
     * Settlement contract address (base58 format)
     * Example: TAhZaywaWM1zAQPADJA39FyoQk8cokRLCd
     */
    private String contractAddress;

    /**
     * Aggregator private key (hex format, 64 characters)
     */
    private String privateKey;

    /**
     * Aggregator address (base58 format, derived from private key)
     * Example: TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M
     */
    private String aggregatorAddress;

    /**
     * Transaction polling settings (to reduce RPC load).
     */
    private Polling polling = new Polling();

    @Data
    public static class Polling {
        /**
         * Timeout for getting TransactionInfo after broadcasting a tx.
         */
        private long txInfoTimeoutSeconds = 60;
        /**
         * Initial poll interval for TransactionInfo.
         */
        private long txInfoPollInitialMs = 250;
        /**
         * Maximum poll interval for TransactionInfo (backoff cap).
         */
        private long txInfoPollMaxMs = 2000;

        /**
         * Timeout for reading BatchSubmitted event.
         */
        private long batchSubmittedTimeoutSeconds = 60;
        /**
         * Initial poll interval for BatchSubmitted event.
         */
        private long batchSubmittedPollInitialMs = 500;
        /**
         * Maximum poll interval for BatchSubmitted event (backoff cap).
         */
        private long batchSubmittedPollMaxMs = 3000;
    }
}
