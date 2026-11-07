package com.illixion.convolution;

import java.nio.ByteBuffer;

/**
 * libconvolution_analysis: a coordinator's chunks of a title's analysis track
 * (cpp/analysis/analysis_track.h) and the pairing maths, vendored from
 * Controller Bridge's qcb_crypto in Vergence's namespace. Its own library, so
 * Settings pairs without loading the player.
 */
final class AnalysisNative {
    static { System.loadLibrary("convolution_analysis"); }
    private AnalysisNative() {}

    /** A chunk store for a track cut in chunks of `chunkSeconds`; 0 if invalid. */
    static native long storeCreate(double chunkSeconds);
    static native void storeDestroy(long store);
    /** 0 when the chunk parsed, else the reader's error code. */
    static native int storePut(long store, int index, byte[] track, boolean complete);
    /** Keeps chunks lo...hi. */
    static native void storeRetain(long store, int lo, int hi);
    static native boolean storeHoldsWhole(long store, int index);
    /**
     * The shared Smooth Motion fields for the real frames at `start` and `end`
     * (seconds), as half floats: flow RGBA, mask, the two disparities. Returns
     * 1 with `dims` = flow width, height, disparity width, height; 0 when the
     * records aren't here; -1 when a direct buffer is too small (`dims` says
     * the sizes).
     */
    static native int storeFields(long store, double start, double end, ByteBuffer flow, ByteBuffer mask,
                                  ByteBuffer disparity0, ByteBuffer disparity1, int[] dims);
    /** Seconds from `seconds` to the nearest flow pair, NaN when none is within 5 s. */
    static native double storeNearestPairOffset(long store, double seconds);

    /** X25519 public key of a 32-byte secret. */
    static native byte[] pairPublicKey(byte[] secret);
    /** SHA256(publicKey || nonce). */
    static native byte[] pairCommitment(byte[] publicKey, byte[] nonce);
    /** Six ASCII digits then the 32-byte key ("Vergence-Pair-v1"), or null for an unusable host key. */
    static native byte[] pairAgree(byte[] secret, byte[] nonce, byte[] hostPublicKey, byte[] hostNonce);
    /** Opens a CryptoKit ChaChaPoly combined box; null when it does not authenticate. */
    static native byte[] boxOpen(byte[] key, byte[] combined);
    /** The coordinator's bearer token for a paired device, hex (desktop/src/pairing.rs). */
    static native String httpToken(byte[] pairingToken, byte[] deviceId);
}
