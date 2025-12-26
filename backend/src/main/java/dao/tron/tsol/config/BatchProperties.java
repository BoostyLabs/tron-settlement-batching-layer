package dao.tron.tsol.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties(prefix = "batch")
@Data
public class BatchProperties {

    /**
     * Maximum number of transactions per batch
     */
    private Integer maxTxPerBatch;

    /**
     * Timelock duration in seconds before batch can be executed
     */
    private Long timelockDuration;

    /**
     * Current batch Merkle root (hex format with 0x prefix)
     * Example: 0x82067662081cf3c1061cae00166d580285a337264c1eb3c91673579a814d32ea
     */
    private String merkleRoot;
}












