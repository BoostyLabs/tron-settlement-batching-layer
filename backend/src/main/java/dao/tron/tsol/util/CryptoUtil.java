package dao.tron.tsol.util;

import java.security.SecureRandom;

/**
 * Cryptographic utilities.
 *
 * IMPORTANT:
 * - Use SecureRandom for salts/nonces intended to be unpredictable.
 * - For Settlement batchSalt, the on-chain contract (sc/) currently expects uint64; we therefore expose a uint64-safe
 *   generator that returns a non-zero positive long (1..Long.MAX_VALUE).
 */
public final class CryptoUtil {
    private CryptoUtil() {}

    private static final SecureRandom RNG = new SecureRandom();

    public static byte[] randomBytes32() {
        byte[] salt = new byte[32];
        RNG.nextBytes(salt);
        return salt;
    }

    public static String toHex0x(byte[] bytes) {
        StringBuilder sb = new StringBuilder("0x");
        for (byte b : bytes) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    /**
     * Generate a non-zero uint64 value that is safe to round-trip in Java as a signed long
     * and safe to encode using Uint64(BigInteger.valueOf(...)).
     */
    public static long randomUint64PositiveNonZero() {
        long v;
        do {
            v = RNG.nextLong() & Long.MAX_VALUE;
        } while (v == 0L);
        return v;
    }
}




