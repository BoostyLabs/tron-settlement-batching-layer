package dao.tron.tsol.service;

import dao.tron.tsol.config.ChainProperties;
import dao.tron.tsol.config.SettlementProperties;
import dao.tron.tsol.config.WhitelistProperties;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.tron.trident.abi.FunctionEncoder;
import org.tron.trident.abi.FunctionReturnDecoder;
import org.tron.trident.abi.TypeReference;
import org.tron.trident.abi.datatypes.DynamicBytes;
import org.tron.trident.abi.datatypes.Function;
import org.tron.trident.abi.datatypes.generated.Bytes32;
import org.tron.trident.abi.datatypes.generated.Uint64;
import org.tron.trident.core.ApiWrapper;
import org.tron.trident.proto.Chain;
import org.tron.trident.proto.Response;
import org.tron.trident.utils.Numeric;
import org.web3j.crypto.ECKeyPair;
import org.web3j.crypto.Hash;
import org.web3j.crypto.Sign;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

@Slf4j
@Service
public class WhitelistService {

    private final WhitelistProperties whitelistProps;
    private final ApiWrapper wrapper;
    private final String updaterBase58;
    private final ECKeyPair keyPair;
    private final long chainId;
    private final String registryBase58;

    private static final long DEFAULT_FEE_LIMIT = 50_000_000L;

    public WhitelistService(WhitelistProperties whitelistProps,
                            SettlementProperties settlementProps,
                            ChainProperties chainProps) {
        this.whitelistProps = whitelistProps;
        this.registryBase58 = whitelistProps.getRegistryAddress();
        this.chainId = chainProps.getId() != null ? chainProps.getId() : 3448148188L;
        
        String privateKey = settlementProps.getPrivateKey();
        if (privateKey == null || privateKey.isBlank()) {
            log.warn("WhitelistService: No valid private key configured. Whitelist sync/signing disabled.");
            this.wrapper = null;
            this.updaterBase58 = "NOT_CONFIGURED";
            this.keyPair = null;
        } else {
            // NOTE: this project targets Nile; if you need mainnet, plumb node selection like SettlementContractClientTrident.
            this.wrapper = ApiWrapper.ofNile(privateKey);
            this.updaterBase58 = this.wrapper.keyPair.toBase58CheckAddress();
            String pkHex = privateKey.startsWith("0x") ? privateKey : "0x" + privateKey;
            this.keyPair = ECKeyPair.create(new BigInteger(pkHex.substring(2), 16));
        }
            
        log.info("WhitelistService initialized: updater={}, registry={}, chainId={}, addresses={}",
                updaterBase58,
                registryBase58,
                chainId,
                whitelistProps.getAddresses() != null ? whitelistProps.getAddresses().size() : 0);
    }

    public List<String> generateWhitelistProof(String addressBase58) {
        try {
            String target = addressBase58 == null ? "" : addressBase58.trim();
            List<String> configured = whitelistProps.getAddresses();
            if (configured == null || configured.isEmpty()) {
                return List.of();
            }

            // Spring may bind `whitelist.addresses` as:
            // - a real list, OR
            // - a single comma-separated string (e.g. from env), sometimes with spaces/CRLF.
            // Normalize by flattening + trimming + dropping empties.
            List<String> whitelistAddresses = new ArrayList<>();
            for (String entry : configured) {
                if (entry == null) continue;
                String e = entry.trim();
                if (e.isEmpty()) continue;
                if (e.contains(",")) {
                    for (String part : e.split(",")) {
                        String p = part.trim();
                        if (!p.isEmpty()) whitelistAddresses.add(p);
                    }
                } else {
                    whitelistAddresses.add(e);
                }
            }
            if (whitelistAddresses.isEmpty()) {
                return List.of();
            }

            List<byte[]> leaves = new ArrayList<>();
            int targetIndex = -1;
            
            for (int i = 0; i < whitelistAddresses.size(); i++) {
                String addr = whitelistAddresses.get(i);
                byte[] leaf = whitelistAddressToLeaf(addr);
                leaves.add(leaf);
                
                if (addr.equalsIgnoreCase(target)) {
                    targetIndex = i;
                }
            }
            
            if (targetIndex == -1) {
                log.debug("Whitelist proof requested for non-whitelisted address: {} (configuredCount={})", target, whitelistAddresses.size());
                return List.of();
            }
            
            // Whitelist scripts build a standard OZ-sorted-pair tree with "duplicate last" behavior.
            List<byte[]> proof = buildProofDuplicateOddSortedPairs(leaves, targetIndex);
            List<String> out = new ArrayList<>(proof.size());
            for (byte[] p : proof) {
                out.add("0x" + bytesToHex(p));
            }
            return out;
            
        } catch (Exception e) {
            log.error("Failed to generate whitelist proof", e);
            return List.of();
        }
    }
    
    /**
     * Convert Tron address to whitelist leaf hash: keccak256(bytes32(address))
     */
    private byte[] whitelistAddressToLeaf(String addressBase58) {
        // Reuse trident parsing for base58 -> 21 bytes (0x41 + 20 bytes); keep the last 20 bytes.
        byte[] raw = org.tron.trident.core.ApiWrapper.parseAddress(addressBase58).toByteArray();
        if (raw.length < 21) {
            throw new IllegalArgumentException("Parsed address length < 21 bytes for " + addressBase58);
        }
        byte[] addr20 = java.util.Arrays.copyOfRange(raw, raw.length - 20, raw.length);
        
        byte[] bytes32 = new byte[32];
        System.arraycopy(addr20, 0, bytes32, 12, 20);
        
        return Hash.sha3(bytes32);
    }

    /**
     * Ensure the on-chain whitelist root matches the addresses configured in `whitelist.addresses`.
     * This is the Java equivalent of the scripts `2_signRoot.js` + `3_updateRoot.js`.
     */
    public boolean ensureWhitelistRootMatchesConfig() {
        if (wrapper == null || keyPair == null) {
            log.warn("WhitelistService not configured for on-chain sync (missing private key).");
            return false;
        }
        try {
            String desiredRoot = computeWhitelistRootFromConfig();
            String currentRoot = getCurrentMerkleRoot();

            if (normalizeHex32(desiredRoot).equalsIgnoreCase(normalizeHex32(currentRoot))) {
                log.info("Whitelist root already matches config: {}", desiredRoot);
                return true;
            }

            long nonce = getCurrentNonce();
            byte[] sig = signWhitelistUpdate(desiredRoot, nonce);
            String txId = updateMerkleRoot(desiredRoot, nonce, sig);

            Thread.sleep(5000);
            String after = getCurrentMerkleRoot();
            boolean ok = normalizeHex32(desiredRoot).equalsIgnoreCase(normalizeHex32(after));
            log.info("Whitelist root sync result: ok={}, txId={}, old={}, new={}, desired={}",
                    ok, txId, currentRoot, after, desiredRoot);
            return ok;
        } catch (Exception e) {
            log.error("ensureWhitelistRootMatchesConfig failed", e);
            return false;
        }
    }

    public long getCurrentNonce() {
        Function fn = new Function(
                "getCurrentNonce",
                List.of(),
                List.of(new TypeReference<Uint64>() {})
        );
        Response.TransactionExtention txn = wrapper.triggerConstantContract(
                updaterBase58,
                registryBase58,
                FunctionEncoder.encode(fn),
                org.tron.trident.core.NodeType.SOLIDITY_NODE
        );
        if (!txn.getResult().getResult() || txn.getConstantResultCount() == 0) {
            throw new RuntimeException("getCurrentNonce failed: " + txn.getResult().getMessage().toStringUtf8());
        }
        String resultHex = Numeric.toHexString(txn.getConstantResult(0).toByteArray());
        @SuppressWarnings("rawtypes")
        List<org.tron.trident.abi.datatypes.Type> decoded = FunctionReturnDecoder.decode(resultHex, fn.getOutputParameters());
        Uint64 v = (Uint64) decoded.get(0);
        return v.getValue().longValue();
    }

    public String getCurrentMerkleRoot() {
        Function fn = new Function(
                "getCurrentMerkleRoot",
                List.of(),
                List.of(new TypeReference<Bytes32>() {})
        );
        Response.TransactionExtention txn = wrapper.triggerConstantContract(
                updaterBase58,
                registryBase58,
                FunctionEncoder.encode(fn),
                org.tron.trident.core.NodeType.SOLIDITY_NODE
        );
        if (!txn.getResult().getResult() || txn.getConstantResultCount() == 0) {
            throw new RuntimeException("getCurrentMerkleRoot failed: " + txn.getResult().getMessage().toStringUtf8());
        }
        String resultHex = Numeric.toHexString(txn.getConstantResult(0).toByteArray());
        @SuppressWarnings("rawtypes")
        List<org.tron.trident.abi.datatypes.Type> decoded = FunctionReturnDecoder.decode(resultHex, fn.getOutputParameters());
        Bytes32 root = (Bytes32) decoded.get(0);
        return "0x" + bytesToHex(root.getValue());
    }

    public String updateMerkleRoot(String newRootHex, long nonce, byte[] signature) {
        try {
            String cleanRoot = cleanHex(newRootHex);
            byte[] rootBytes = Numeric.hexStringToByteArray(cleanRoot);
            if (rootBytes.length != 32) throw new IllegalArgumentException("Root must be 32 bytes");

            Function fn = new Function(
                    "updateMerkleRoot",
                    Arrays.asList(
                            new Bytes32(rootBytes),
                            new Uint64(BigInteger.valueOf(nonce)),
                            new DynamicBytes(signature)
                    ),
                    List.of()
            );

            Response.TransactionExtention txnExt = wrapper.triggerContract(
                    updaterBase58,
                    registryBase58,
                    FunctionEncoder.encode(fn),
                    0L,
                    0L,
                    null,
                    DEFAULT_FEE_LIMIT
            );
            if (!txnExt.getResult().getResult()) {
                throw new RuntimeException("updateMerkleRoot trigger failed: " + txnExt.getResult().getMessage().toStringUtf8());
            }
            Chain.Transaction signed = wrapper.signTransaction(txnExt);
            return wrapper.broadcastTransaction(signed);
        } catch (Exception e) {
            throw new RuntimeException("updateMerkleRoot failed: " + e.getMessage(), e);
        }
    }

    /**
     * Signature compatible with Solidity:
     * hash = keccak256(abi.encodePacked(newRoot, nonce, chainid, address(registry)));
     * signedHash = toEthSignedMessageHash(hash);
     * signature = sign(signedHash)
     */
    private byte[] signWhitelistUpdate(String newRootHex, long nonce) {
        if (keyPair == null) throw new IllegalStateException("No keyPair configured");
        String cleanRoot = cleanHex(newRootHex);
        byte[] rootBytes = Numeric.hexStringToByteArray(cleanRoot);
        if (rootBytes.length != 32) throw new IllegalArgumentException("Root must be 32 bytes");

        // registry as 20-byte EVM address (strip 0x41 prefix from TRON address bytes)
        byte[] regRaw = ApiWrapper.parseAddress(registryBase58).toByteArray();
        if (regRaw.length < 21) throw new IllegalArgumentException("Registry address parse failed");
        byte[] reg20 = Arrays.copyOfRange(regRaw, regRaw.length - 20, regRaw.length);

        byte[] nonce8 = new byte[8];
        long n = nonce;
        for (int i = 7; i >= 0; i--) {
            nonce8[i] = (byte) (n & 0xFF);
            n >>= 8;
        }

        byte[] chainId32 = new byte[32];
        byte[] cid = BigInteger.valueOf(chainId).toByteArray();
        System.arraycopy(cid, 0, chainId32, 32 - cid.length, cid.length);

        byte[] packed = new byte[32 + 8 + 32 + 20];
        System.arraycopy(rootBytes, 0, packed, 0, 32);
        System.arraycopy(nonce8, 0, packed, 32, 8);
        System.arraycopy(chainId32, 0, packed, 40, 32);
        System.arraycopy(reg20, 0, packed, 72, 20);

        byte[] digest = Hash.sha3(packed);
        Sign.SignatureData sig = Sign.signPrefixedMessage(digest, keyPair);

        byte[] out = new byte[65];
        System.arraycopy(sig.getR(), 0, out, 0, 32);
        System.arraycopy(sig.getS(), 0, out, 32, 32);
        out[64] = sig.getV()[0];
        return out;
    }

    /**
     * Compute whitelist merkle root from the configured base58 addresses.
     * Leaf = keccak256(bytes32(address)) (left padded 12 bytes).
     * Internal nodes: keccak256(min(a,b) || max(a,b)) (sorted pair).
     * Odd nodes: duplicate the last element (script behavior for whitelist trees).
     */
    private String computeWhitelistRootFromConfig() {
        List<String> addrs = whitelistProps.getAddresses();
        if (addrs == null || addrs.isEmpty()) {
            throw new IllegalStateException("whitelist.addresses is empty");
        }
        List<byte[]> leaves = new ArrayList<>(addrs.size());
        for (String a : addrs) leaves.add(whitelistAddressToLeaf(a));
        byte[] root = computeRootDuplicateOddSortedPairs(leaves);
        return "0x" + bytesToHex(root);
    }

    private static byte[] computeRootDuplicateOddSortedPairs(List<byte[]> leaves) {
        List<byte[]> level = new ArrayList<>(leaves.size());
        for (byte[] l : leaves) level.add(l.clone());
        while (level.size() > 1) {
            List<byte[]> next = new ArrayList<>();
            for (int i = 0; i < level.size(); i += 2) {
                byte[] left = level.get(i);
                byte[] right = (i + 1 < level.size()) ? level.get(i + 1) : left; // duplicate odd
                next.add(hashPairSorted(left, right));
            }
            level = next;
        }
        return level.get(0);
    }

    private static List<byte[]> buildProofDuplicateOddSortedPairs(List<byte[]> leaves, int index) {
        List<List<byte[]>> layers = new ArrayList<>();
        List<byte[]> cur = new ArrayList<>(leaves.size());
        for (byte[] l : leaves) cur.add(l.clone());
        layers.add(cur);

        while (cur.size() > 1) {
            List<byte[]> next = new ArrayList<>();
            for (int i = 0; i < cur.size(); i += 2) {
                byte[] left = cur.get(i);
                byte[] right = (i + 1 < cur.size()) ? cur.get(i + 1) : left; // duplicate odd
                next.add(hashPairSorted(left, right));
            }
            layers.add(next);
            cur = next;
        }

        List<byte[]> proof = new ArrayList<>();
        int idx = index;
        for (int layerIdx = 0; layerIdx < layers.size() - 1; layerIdx++) {
            List<byte[]> layer = layers.get(layerIdx);
            int sib = idx ^ 1;
            if (sib < layer.size()) {
                proof.add(layer.get(sib));
            }
            idx /= 2;
        }
        return proof;
    }

    private static byte[] hashPairSorted(byte[] a, byte[] b) {
        if (compareBytes(a, b) <= 0) {
            return Hash.sha3(concat(a, b));
        }
        return Hash.sha3(concat(b, a));
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

    private static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    private static String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) sb.append(String.format("%02x", b & 0xff));
        return sb.toString();
    }

    private static String normalizeHex32(String h) {
        if (h == null) return null;
        String s = h.toLowerCase();
        return s.startsWith("0x") ? s : "0x" + s;
    }

    private static String cleanHex(String value) {
        if (value == null) return "";
        return (value.startsWith("0x") || value.startsWith("0X"))
                ? value.substring(2)
                : value;
    }
}
