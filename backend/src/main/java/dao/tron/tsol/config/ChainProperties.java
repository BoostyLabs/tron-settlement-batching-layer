package dao.tron.tsol.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties(prefix = "chain")
@Data
public class ChainProperties {

    /**
     * TRON chain ID
     * Nile testnet: 3448148188
     * Mainnet: 728126428
     */
    private Long id;
}












