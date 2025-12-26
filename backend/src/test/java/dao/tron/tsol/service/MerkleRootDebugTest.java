package dao.tron.tsol.service;

import dao.tron.tsol.model.TransferData;
import org.junit.jupiter.api.Test;
import org.tron.trident.utils.Numeric;

import java.util.Arrays;
import java.util.List;

public class MerkleRootDebugTest {
    
    @Test
    public void testBatch20MerkleRoot() {
        MerkleTreeService merkleService = new MerkleTreeService();
        long batchSalt = 1L; // TODO: set to the on-chain batchSalt for Batch #20 when known
        
        // Transfer 1 - EXACT values from Batch #20
        TransferData tx1 = new TransferData();
        tx1.setFrom("TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M");
        tx1.setTo("TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn");
        tx1.setAmount("2000");
        tx1.setNonce(1765547218L);
        tx1.setTimestamp(1765547218L);
        tx1.setRecipientCount(1);
        tx1.setBatchId(20);
        tx1.setTxType(1); // DELAYED
        
        // Transfer 2 - EXACT values from Batch #20
        TransferData tx2 = new TransferData();
        tx2.setFrom("TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M");
        tx2.setTo("TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn");
        tx2.setAmount("2100");
        tx2.setNonce(1765560218L);
        tx2.setTimestamp(1765547218L);
        tx2.setRecipientCount(1);
        tx2.setBatchId(20);
        tx2.setTxType(1); // DELAYED
        
        // Calculate leaf hashes
        byte[] leaf1 = merkleService.leafHash(tx1, batchSalt);
        byte[] leaf2 = merkleService.leafHash(tx2, batchSalt);
        
        System.out.println("========================================");
        System.out.println("JAVA MERKLE CALCULATION");
        System.out.println("========================================");
        System.out.println("\nTransfer 1:");
        System.out.println("  amount: " + tx1.getAmount());
        System.out.println("  nonce: " + tx1.getNonce() + " (uint64)");
        System.out.println("  timestamp: " + tx1.getTimestamp() + " (uint48)");
        System.out.println("  recipientCount: " + tx1.getRecipientCount() + " (uint32)");
        System.out.println("  batchId: " + tx1.getBatchId() + " (uint64)");
        System.out.println("  txType: " + tx1.getTxType() + " (uint8)");
        System.out.println("  TxHash: 0x" + Numeric.toHexStringNoPrefix(leaf1));
        
        System.out.println("\nTransfer 2:");
        System.out.println("  amount: " + tx2.getAmount());
        System.out.println("  nonce: " + tx2.getNonce() + " (uint64)");
        System.out.println("  timestamp: " + tx2.getTimestamp() + " (uint48)");
        System.out.println("  recipientCount: " + tx2.getRecipientCount() + " (uint32)");
        System.out.println("  batchId: " + tx2.getBatchId() + " (uint64)");
        System.out.println("  txType: " + tx2.getTxType() + " (uint8)");
        System.out.println("  TxHash: 0x" + Numeric.toHexStringNoPrefix(leaf2));
        
        // Calculate Merkle root
        List<byte[]> leaves = Arrays.asList(leaf1, leaf2);
        String merkleRoot = merkleService.computeMerkleRoot(leaves);
        
        System.out.println("\nMerkle Root: " + merkleRoot);
        
        System.out.println("\n========================================");
        System.out.println("COMPARISON WITH PYTHON:");
        System.out.println("========================================");
        System.out.println("Expected leaf1: 0x256dc8edc121a6dcabc8caa43ca6b51c402d6a829521e41dabbeeb1595aade23");
        System.out.println("Expected leaf2: 0xb782790b082dfa67521f90ebaf61602895a93bc0e47b5295916bf249618e0d9e");
        System.out.println("Expected root:  0xe12481e04ad5ad0d8891587442f69e975981a33865472c77557cb7226227ec2c");
        System.out.println("\nOn-chain root:  0xa842d9c15cf0db21ca4349de1c9f27333fa4eba1cb29c600ee7603ab539276ca");
        System.out.println("========================================");
    }
}









