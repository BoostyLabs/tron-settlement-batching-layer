package dao.tron.tsol.model;

import lombok.Data;

@Data
public class TransferData {

    private String from;
    private String to;
    private String amount;
    private long nonce;
    private long timestamp;
    private int recipientCount;
    private long batchId;   // filled after submitBatch
    private int txType;
}

