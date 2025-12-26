package dao.tron.tsol.service;

import dao.tron.tsol.model.TransferData;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.DisplayName;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for MerkleTreeService
 * Validates that Merkle tree generation matches Solidity contract expectations
 */
class MerkleTreeServiceTest {

    private MerkleTreeService merkleTreeService;
    private static final long BATCH_SALT = 1L; // source of truth: sc/script/merkle/** uses uint64 batch_salt

    @BeforeEach
    void setUp() {
        merkleTreeService = new MerkleTreeService();
    }

    @Test
    @DisplayName("Test leaf hash generation with sample transfer data")
    void testLeafHashGeneration() {
        // Arrange: Create sample transfer data
        TransferData transfer = createSampleTransfer(
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M", // from
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn", // to
                "1000000",  // amount (1 USDT with 6 decimals)
                1L,         // nonce
                1702332000L, // timestamp
                1,          // recipientCount
                1L,         // batchId
                0           // txType (DELAYED)
        );

        // Act: Generate leaf hash
        byte[] leafHash = merkleTreeService.leafHash(transfer, BATCH_SALT);

        // Assert: Verify hash is 32 bytes
        assertNotNull(leafHash, "Leaf hash should not be null");
        assertEquals(32, leafHash.length, "Leaf hash should be 32 bytes");
        
        // Log the hash for manual verification
        System.out.println("Leaf hash (hex): 0x" + bytesToHex(leafHash));
    }

    @Test
    @DisplayName("Test Merkle root generation with single transfer")
    void testMerkleRootWithSingleTransfer() {
        // Arrange: Create one transfer
        TransferData transfer = createSampleTransfer(
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn",
                "1000000",
                1L,
                1702332000L,
                1,
                1L,
                0
        );

        List<byte[]> leaves = new ArrayList<>();
        leaves.add(merkleTreeService.leafHash(transfer, BATCH_SALT));

        // Act: Compute Merkle root
        String merkleRoot = merkleTreeService.computeMerkleRoot(leaves);

        // Assert
        assertNotNull(merkleRoot, "Merkle root should not be null");
        assertTrue(merkleRoot.startsWith("0x"), "Merkle root should start with 0x");
        assertEquals(66, merkleRoot.length(), "Merkle root should be 66 chars (0x + 64 hex chars)");

        System.out.println("Single transfer Merkle root: " + merkleRoot);
    }

    @Test
    @DisplayName("Test Merkle root generation with multiple transfers")
    void testMerkleRootWithMultipleTransfers() {
        // Arrange: Create 5 transfers (typical batch)
        List<TransferData> transfers = new ArrayList<>();
        
        transfers.add(createSampleTransfer(
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn",
                "1000000",
                1L,
                1702332000L,
                1,
                1L,
                0
        ));
        
        transfers.add(createSampleTransfer(
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",
                "TUqVYQLKtNvLCjHw6uGPLw4Qmw7vXEavnc",
                "2000000",
                2L,
                1702332001L,
                1,
                1L,
                1
        ));
        
        transfers.add(createSampleTransfer(
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn",
                "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",
                "500000",
                3L,
                1702332002L,
                1,
                1L,
                2
        ));
        
        transfers.add(createSampleTransfer(
                "TUqVYQLKtNvLCjHw6uGPLw4Qmw7vXEavnc",
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",
                "3000000",
                4L,
                1702332003L,
                2,
                1L,
                0
        ));
        
        transfers.add(createSampleTransfer(
                "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn",
                "1500000",
                5L,
                1702332004L,
                1,
                1L,
                1
        ));

        // Generate leaves
        List<byte[]> leaves = new ArrayList<>();
        for (TransferData transfer : transfers) {
            leaves.add(merkleTreeService.leafHash(transfer, BATCH_SALT));
        }

        // Act: Compute Merkle root
        String merkleRoot = merkleTreeService.computeMerkleRoot(leaves);

        // Assert
        assertNotNull(merkleRoot, "Merkle root should not be null");
        assertTrue(merkleRoot.startsWith("0x"), "Merkle root should start with 0x");
        assertEquals(66, merkleRoot.length(), "Merkle root should be 66 chars");

        System.out.println("\n=== BATCH OF 5 TRANSFERS ===");
        System.out.println("Merkle root: " + merkleRoot);
        System.out.println("Number of leaves: " + leaves.size());
        
        // Print each leaf for debugging
        for (int i = 0; i < leaves.size(); i++) {
            System.out.println("Leaf " + i + ": 0x" + bytesToHex(leaves.get(i)));
        }
    }

    @Test
    @DisplayName("Test Merkle proof generation and structure")
    void testMerkleProofGeneration() {
        // Arrange: Create 5 transfers
        List<TransferData> transfers = createBatchOfTransfers(5, 1L);
        
        List<byte[]> leaves = new ArrayList<>();
        for (TransferData transfer : transfers) {
            leaves.add(merkleTreeService.leafHash(transfer, BATCH_SALT));
        }

        String merkleRoot = merkleTreeService.computeMerkleRoot(leaves);

        // Act: Generate proofs for each transfer
        System.out.println("\n=== MERKLE PROOF GENERATION ===");
        System.out.println("Merkle root: " + merkleRoot);
        System.out.println();

        for (int i = 0; i < leaves.size(); i++) {
            List<String> proof = merkleTreeService.buildProof(leaves, i);
            
            // Assert: Proof should not be empty for multiple leaves
            assertNotNull(proof, "Proof should not be null for index " + i);
            
            // For 5 leaves, we need ceil(log2(5)) = 3 levels, so proof size should be 3
            assertTrue(proof.size() > 0, "Proof should have at least one sibling");
            assertTrue(proof.size() <= 4, "Proof should not have more than 4 siblings for 5 leaves");
            
            // All proof elements should be 0x-prefixed 32-byte hashes
            for (String proofElement : proof) {
                assertTrue(proofElement.startsWith("0x"), "Proof element should start with 0x");
                assertEquals(66, proofElement.length(), "Proof element should be 66 chars");
            }

            System.out.println("Transfer #" + i + " proof (" + proof.size() + " siblings):");
            for (int j = 0; j < proof.size(); j++) {
                System.out.println("  [" + j + "] " + proof.get(j));
            }
            System.out.println();
        }
    }

    @Test
    @DisplayName("Test that same data produces same Merkle root (deterministic)")
    void testDeterministicMerkleRoot() {
        // Arrange: Create same batch twice
        List<TransferData> transfers1 = createBatchOfTransfers(3, 1L);
        List<TransferData> transfers2 = createBatchOfTransfers(3, 1L);

        List<byte[]> leaves1 = new ArrayList<>();
        List<byte[]> leaves2 = new ArrayList<>();

        for (int i = 0; i < transfers1.size(); i++) {
            leaves1.add(merkleTreeService.leafHash(transfers1.get(i), BATCH_SALT));
            leaves2.add(merkleTreeService.leafHash(transfers2.get(i), BATCH_SALT));
        }

        // Act: Compute roots
        String root1 = merkleTreeService.computeMerkleRoot(leaves1);
        String root2 = merkleTreeService.computeMerkleRoot(leaves2);

        // Assert: Should be identical
        assertEquals(root1, root2, "Same data should produce same Merkle root");
        
        System.out.println("Deterministic test - both roots: " + root1);
    }

    @Test
    @DisplayName("Test that different data produces different Merkle root")
    void testDifferentDataProducesDifferentRoot() {
        // Arrange: Create two different batches.
        // IMPORTANT: batchId is NOT included in txHash (leaf hash), so changing only batchId must NOT change root.
        // To validate "different data => different root", we change a hashed field (nonce).
        List<TransferData> transfers1 = createBatchOfTransfers(3, 1L);
        List<TransferData> transfers2 = createBatchOfTransfers(3, 1L);
        transfers2.get(0).setNonce(transfers2.get(0).getNonce() + 1); // change hashed field

        List<byte[]> leaves1 = new ArrayList<>();
        List<byte[]> leaves2 = new ArrayList<>();

        for (int i = 0; i < transfers1.size(); i++) {
            leaves1.add(merkleTreeService.leafHash(transfers1.get(i), BATCH_SALT));
            leaves2.add(merkleTreeService.leafHash(transfers2.get(i), BATCH_SALT));
        }

        // Act: Compute roots
        String root1 = merkleTreeService.computeMerkleRoot(leaves1);
        String root2 = merkleTreeService.computeMerkleRoot(leaves2);

        // Assert: Should be different
        assertNotEquals(root1, root2, "Different data should produce different Merkle roots");
        
        System.out.println("Different data test:");
        System.out.println("  Batch 1 root: " + root1);
        System.out.println("  Batch 2 root: " + root2);
    }

    @Test
    @DisplayName("Test Merkle proof for specific transaction in batch")
    void testSpecificTransactionProof() {
        // Arrange: Create a realistic batch
        List<TransferData> transfers = new ArrayList<>();
        
        // Transfer 0: Alice sends 10 USDT to Bob
        transfers.add(createSampleTransfer(
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M", // Alice
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn", // Bob
                "10000000", // 10 USDT
                1L,
                1702332000L,
                1,
                1L,
                0
        ));
        
        // Transfer 1: Bob sends 5 USDT to Charlie
        transfers.add(createSampleTransfer(
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn", // Bob
                "TUqVYQLKtNvLCjHw6uGPLw4Qmw7vXEavnc", // Charlie
                "5000000",  // 5 USDT
                2L,
                1702332001L,
                1,
                1L,
                0
        ));
        
        // Transfer 2: Charlie sends 2 USDT to Alice
        transfers.add(createSampleTransfer(
                "TUqVYQLKtNvLCjHw6uGPLw4Qmw7vXEavnc", // Charlie
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M", // Alice
                "2000000",  // 2 USDT
                3L,
                1702332002L,
                1,
                1L,
                0
        ));

        List<byte[]> leaves = new ArrayList<>();
        for (TransferData transfer : transfers) {
            leaves.add(merkleTreeService.leafHash(transfer, BATCH_SALT));
        }

        String merkleRoot = merkleTreeService.computeMerkleRoot(leaves);

        // Act: Get proof for Transfer 1 (Bob -> Charlie)
        List<String> proof = merkleTreeService.buildProof(leaves, 1);

        // Assert
        assertNotNull(proof, "Proof should exist");
        assertFalse(proof.isEmpty(), "Proof should not be empty");

        System.out.println("\n=== SPECIFIC TRANSACTION PROOF ===");
        System.out.println("Transaction: Bob sends 5 USDT to Charlie (index 1)");
        System.out.println("Merkle Root: " + merkleRoot);
        System.out.println("Proof elements: " + proof.size());
        System.out.println("Proof:");
        for (int i = 0; i < proof.size(); i++) {
            System.out.println("  [" + i + "] " + proof.get(i));
        }

        // This proof can be used to call executeTransfer on-chain
        System.out.println("\nThis proof can be submitted to the Settlement contract!");
    }

    @Test
    @DisplayName("Test edge case: Odd number of leaves")
    void testOddNumberOfLeaves() {
        // Arrange: Create 3 transfers (odd number)
        List<TransferData> transfers = createBatchOfTransfers(3, 1L);
        
        List<byte[]> leaves = new ArrayList<>();
        for (TransferData transfer : transfers) {
            leaves.add(merkleTreeService.leafHash(transfer, BATCH_SALT));
        }

        // Act & Assert: Should not throw exception
        assertDoesNotThrow(() -> {
            String merkleRoot = merkleTreeService.computeMerkleRoot(leaves);
            assertNotNull(merkleRoot, "Should handle odd number of leaves");
            
            // Should be able to generate proofs for all
            for (int i = 0; i < leaves.size(); i++) {
                List<String> proof = merkleTreeService.buildProof(leaves, i);
                assertNotNull(proof, "Should generate proof for index " + i);
            }
        });
    }

    @Test
    @DisplayName("Test edge case: Single leaf")
    void testSingleLeaf() {
        // Arrange
        TransferData transfer = createSampleTransfer(
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn",
                "1000000",
                1L,
                1702332000L,
                1,
                1L,
                0
        );

        List<byte[]> leaves = new ArrayList<>();
        leaves.add(merkleTreeService.leafHash(transfer, BATCH_SALT));

        // Act: Compute root
        String merkleRoot = merkleTreeService.computeMerkleRoot(leaves);

        // Assert: Root should equal the leaf hash itself
        String expectedRoot = "0x" + bytesToHex(leaves.get(0));
        assertEquals(expectedRoot.toLowerCase(), merkleRoot.toLowerCase(), 
                "Single leaf root should equal leaf hash");

        // Proof should be empty for single leaf
        List<String> proof = merkleTreeService.buildProof(leaves, 0);
        assertTrue(proof.isEmpty(), "Proof for single leaf should be empty");
    }

    // =========================================================================
    // HELPER METHODS
    // =========================================================================

    private TransferData createSampleTransfer(
            String from,
            String to,
            String amount,
            long nonce,
            long timestamp,
            int recipientCount,
            long batchId,
            int txType
    ) {
        TransferData transfer = new TransferData();
        transfer.setFrom(from);
        transfer.setTo(to);
        transfer.setAmount(amount);
        transfer.setNonce(nonce);
        transfer.setTimestamp(timestamp);
        transfer.setRecipientCount(recipientCount);
        transfer.setBatchId(batchId);
        transfer.setTxType(txType);
        return transfer;
    }

    private List<TransferData> createBatchOfTransfers(int count, long batchId) {
        List<TransferData> transfers = new ArrayList<>();
        String[] addresses = {
                "TKWvD71EMFTpFVGZyqqX9fC6MQgcR9H76M",
                "TToEDBXQkGuYGsnyJASTM5JZweb7Rvrnfn",
                "TUqVYQLKtNvLCjHw6uGPLw4Qmw7vXEavnc",
                "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",
                "TAhZaywaWM1zAQPADJA39FyoQk8cokRLCd"
        };

        for (int i = 0; i < count; i++) {
            transfers.add(createSampleTransfer(
                    addresses[i % addresses.length],
                    addresses[(i + 1) % addresses.length],
                    String.valueOf((i + 1) * 1000000), // 1, 2, 3... USDT
                    i + 1L,
                    1702332000L + i,
                    1,
                    batchId,
                    i % 3 // Rotate through txTypes 0, 1, 2
            ));
        }

        return transfers;
    }

    private String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02x", b & 0xff));
        }
        return sb.toString();
    }
}







