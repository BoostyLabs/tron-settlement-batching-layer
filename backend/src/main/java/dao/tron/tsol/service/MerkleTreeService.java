package dao.tron.tsol.service;

import dao.tron.tsol.model.TransferData;
import org.bouncycastle.jcajce.provider.digest.Keccak;
import org.springframework.stereotype.Service;
import org.tron.trident.core.ApiWrapper;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

@Service
public class MerkleTreeService {

    /**
     * Compute leaf hash using abi.encodePacked for minimal byte representation.
     * MUST match Solidity Settlement.sol _calculateTxHash().
     * Note: batchId is NOT included in txHash calculation.
     * IMPORTANT: batchSalt IS included (last field).
     */
    public byte[] leafHash(TransferData txData, long batchSalt) {
        byte[] from = tronAddressToAddressBytes(txData.getFrom());
        byte[] to   = tronAddressToAddressBytes(txData.getTo());

        BigInteger amount = new BigInteger(txData.getAmount());
        
        byte[] amountBytes = uint256ToBytes(amount);
        byte[] nonceBytes = uint64ToBytes(txData.getNonce());
        byte[] timestampBytes = uint48ToBytes(txData.getTimestamp());
        byte[] recipientCountBytes = uint32ToBytes(txData.getRecipientCount());
        byte[] txTypeBytes = uint8ToBytes((byte) txData.getTxType());
        byte[] batchSaltBytes = uint64ToBytes(batchSalt);

        byte[] packed = concat(from, to);
        packed = concat(packed, amountBytes);
        packed = concat(packed, nonceBytes);
        packed = concat(packed, timestampBytes);
        packed = concat(packed, recipientCountBytes);
        packed = concat(packed, txTypeBytes);
        packed = concat(packed, batchSaltBytes);

        return keccak256(packed);
    }

    /**
     * Compute Merkle root using sorted-pair hashing (OpenZeppelin MerkleProof style).
     * Odd number of nodes on a level -> last one is promoted (carried up unchanged).
     *
     * IMPORTANT: This must match the scripts in `sc/script/merkle/**` which promote odd nodes.
     */
    public String computeMerkleRoot(List<byte[]> leaves) {
        if (leaves == null || leaves.isEmpty()) {
            throw new IllegalArgumentException("No leaves");
        }

        List<byte[]> level = new ArrayList<>(leaves.size());
        for (byte[] leaf : leaves) {
            if (leaf == null || leaf.length != 32) {
                throw new IllegalArgumentException("Each leaf must be 32 bytes");
            }
            level.add(leaf.clone());
        }

        while (level.size() > 1) {
            List<byte[]> next = new ArrayList<>();

            for (int i = 0; i < level.size(); i += 2) {
                byte[] left  = level.get(i);
                if (i + 1 < level.size()) {
                    byte[] right = level.get(i + 1);
                next.add(hashPair(left, right));
                } else {
                    next.add(left);
                }
            }

            level = next;
        }

        return "0x" + bytesToHex(level.getFirst());
    }

    /**
     * Build Merkle proof for leaf at index.
     * Returns list of hex-encoded bytes32 (0x-prefixed) in bottom-up order.
     */
    public List<String> buildProof(List<byte[]> leaves, int index) {
        if (leaves == null || leaves.isEmpty()) {
            throw new IllegalArgumentException("No leaves");
        }
        if (index < 0 || index >= leaves.size()) {
            throw new IndexOutOfBoundsException("Invalid leaf index: " + index);
        }

        List<List<byte[]>> layers = new ArrayList<>();
        List<byte[]> current = new ArrayList<>(leaves.size());
        for (byte[] leaf : leaves) {
            if (leaf == null || leaf.length != 32) {
                throw new IllegalArgumentException("Each leaf must be 32 bytes");
            }
            current.add(leaf.clone());
        }
        layers.add(current);

        while (current.size() > 1) {
            List<byte[]> next = new ArrayList<>();
            for (int i = 0; i < current.size(); i += 2) {
                byte[] left  = current.get(i);
                if (i + 1 < current.size()) {
                    byte[] right = current.get(i + 1);
                next.add(hashPair(left, right));
                } else {
                    // Promote odd leaf
                    next.add(left);
                }
            }
            layers.add(next);
            current = next;
        }

        List<String> proof = new ArrayList<>();
        int idx = index;

        for (int layerIdx = 0; layerIdx < layers.size() - 1; layerIdx++) {
            List<byte[]> layer = layers.get(layerIdx);
            int layerSize = layer.size();
            if (layerSize == 1) break;

            int siblingIndex;
            if (idx % 2 == 0) {
                if (idx + 1 < layerSize) {
                    siblingIndex = idx + 1;
                } else {
                    // No sibling at this level (odd leaf promoted)
                    idx = idx / 2;
                    continue;
                }
            } else {
                siblingIndex = idx - 1;
            }

            byte[] sibling = layer.get(siblingIndex);
            proof.add("0x" + bytesToHex(sibling));

            idx = idx / 2;
        }

        return proof;
    }

    /**
     * Hash a pair of 32-byte nodes with sorted-pair keccak.
     */
    private byte[] hashPair(byte[] left, byte[] right) {
        if (left == null || right == null || left.length != 32 || right.length != 32) {
            throw new IllegalArgumentException("hashPair requires two 32-byte inputs");
        }

        if (compareBytes(left, right) <= 0) {
            return keccak256(concat(left, right));
        } else {
            return keccak256(concat(right, left));
        }
    }

    private static byte[] keccak256(byte[] data) {
        Keccak.Digest256 digest = new Keccak.Digest256();
        digest.update(data, 0, data.length);
        return digest.digest();
    }

    private static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    private static int compareBytes(byte[] a, byte[] b) {
        int len = Math.min(a.length, b.length);
        for (int i = 0; i < len; i++) {
            int ai = a[i] & 0xff;
            int bi = b[i] & 0xff;
            if (ai != bi) return ai - bi;
        }
        return a.length - b.length;
    }

    /**
     * Convert TRON base58 address to 20-byte EVM address.
     */
    private static byte[] tronAddressToAddressBytes(String base58) {
        byte[] raw = ApiWrapper.parseAddress(base58).toByteArray();
        if (raw.length < 21) {
            throw new IllegalArgumentException("Parsed address length < 21 bytes for " + base58);
        }
        return Arrays.copyOfRange(raw, raw.length - 20, raw.length);
    }

    private static byte[] uint256ToBytes(BigInteger value) {
        if (value == null) {
            throw new IllegalArgumentException("uint256 value is null");
        }
        if (value.signum() < 0) {
            throw new IllegalArgumentException("uint256 cannot be negative");
        }
        byte[] raw = value.toByteArray();
        if (raw.length > 32) {
            throw new IllegalArgumentException("uint256 value too large");
        }
        byte[] out = new byte[32];
        System.arraycopy(raw, 0, out, 32 - raw.length, raw.length);
        return out;
    }

    private static byte[] uint8ToBytes(byte v) {
        return new byte[]{ v };
    }
    
    private static byte[] uint32ToBytes(int v) {
        return new byte[]{
            (byte)(v >>> 24),
            (byte)(v >>> 16),
            (byte)(v >>> 8),
            (byte)v
        };
    }
    
    private static byte[] uint48ToBytes(long v) {
        return new byte[]{
            (byte)(v >>> 40),
            (byte)(v >>> 32),
            (byte)(v >>> 24),
            (byte)(v >>> 16),
            (byte)(v >>> 8),
            (byte)v
        };
    }
    
    private static byte[] uint64ToBytes(long v) {
        return new byte[]{
            (byte)(v >>> 56),
            (byte)(v >>> 48),
            (byte)(v >>> 40),
            (byte)(v >>> 32),
            (byte)(v >>> 24),
            (byte)(v >>> 16),
            (byte)(v >>> 8),
            (byte)v
        };
    }

    private String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02x", b & 0xff));
        }
        return sb.toString();
    }
}
