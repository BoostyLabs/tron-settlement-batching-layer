package dao.tron.tsol.model;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Data;

@Data
public class TransferIntentRequest {

    @NotBlank
    private String from;

    @NotBlank
    private String to;

    @NotBlank
    private String amount;          // string decimal

    @NotNull
    private Long nonce;

    @NotNull
    private Long timestamp;         // unix seconds

    @NotNull
    private Integer recipientCount; // for fee calc

    @NotNull
    private Integer txType;         // map to Solidity uint8
}
