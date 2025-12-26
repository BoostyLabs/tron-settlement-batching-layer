package dao.tron.tsol.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties(prefix = "whitelist")
@Data
public class WhitelistProperties {

    /**
     * Whitelist registry contract address (base58 format)
     * Example: TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn
     */
    private String registryAddress;

    /**
     * Current Merkle root for whitelist (hex format with 0x prefix)
     * Example: 0x02012517de2680f90c5eb1b6c64e04e21424609e331954b45e202ace05e2938b
     */
    private String merkleRoot;

    /**
     * Nonce for whitelist updates
     */
    private Long nonce;
    
    /**
     * List of whitelisted addresses (base58 format)
     * Example: ["TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M", "TVKAAcqpQxz3J4waayePr8dQjSQ2XHkdbF"]
     */
    private java.util.List<String> addresses;
}




