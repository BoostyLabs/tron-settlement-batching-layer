package dao.tron.tsol.model;


import lombok.Data;

import java.util.List;

@Data
public class StoredTransfer {

    private TransferData txData;
    private List<String> txProof;         // hex-encoded bytes32[]
    private List<String> whitelistProof;  // hex-encoded bytes32[]
    private boolean executed;
    /** TRON transaction id of the successful on-chain executeTransfer (if executed). */
    private String executionTxId;
}

