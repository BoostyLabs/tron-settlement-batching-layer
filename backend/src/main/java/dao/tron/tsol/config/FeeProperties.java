package dao.tron.tsol.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties(prefix = "fee")
@Data
public class FeeProperties {

    /**
     * Fee module contract address (base58 format)
     * Example: TUqVYQLKtNvLCjHw6uGPLw4Qmw7vXEavnc
     */
    private String moduleAddress;
}












