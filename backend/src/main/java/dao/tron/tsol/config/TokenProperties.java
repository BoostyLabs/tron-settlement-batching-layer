package dao.tron.tsol.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@ConfigurationProperties(prefix = "token")
@Data
public class TokenProperties {

    /**
     * ERC20 token contract address (base58 format)
     * Example: TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf
     */
    private String address;
}












