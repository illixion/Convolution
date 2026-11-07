/* JNI for AnalysisNative.java: the coordinator's chunk store and the pairing
   maths (Controller Bridge's qcb_crypto, in Vergence's namespace). Its own
   small library, so Settings can pair without loading the player. */

#include <jni.h>

#include <cmath>
#include <cstring>
#include <memory>
#include <vector>

#include "analysis_track.h"
#include "qcb_crypto.h"

namespace {

/* RAVECompanionNamespace's label prefix for Vergence's coordinator
   (vergence desktop/src/pairing.rs: Namespace::new("vergence", "Vergence", ...)). */
constexpr const char* kVergenceLabel = "Vergence";
constexpr const char* kHttpTokenSalt = "Vergence-HTTP-Token-v1";

bool copy_exact(JNIEnv* env, jbyteArray array, uint8_t* out, jsize size) {
    if (array == nullptr || env->GetArrayLength(array) != size) return false;
    env->GetByteArrayRegion(array, 0, size, reinterpret_cast<jbyte*>(out));
    return true;
}

std::vector<uint8_t> bytes(JNIEnv* env, jbyteArray array) {
    std::vector<uint8_t> out;
    if (array == nullptr) return out;
    out.resize(size_t(env->GetArrayLength(array)));
    env->GetByteArrayRegion(array, 0, jsize(out.size()), reinterpret_cast<jbyte*>(out.data()));
    return out;
}

jbyteArray to_java(JNIEnv* env, const uint8_t* data, size_t size) {
    jbyteArray array = env->NewByteArray(static_cast<jsize>(size));
    if (array != nullptr) env->SetByteArrayRegion(array, 0, jsize(size), reinterpret_cast<const jbyte*>(data));
    return array;
}

vgat::ChunkStore* store(jlong handle) { return reinterpret_cast<vgat::ChunkStore*>(handle); }

bool fill(JNIEnv* env, jobject buffer, const std::vector<uint16_t>& values) {
    if (buffer == nullptr) return false;
    void* address = env->GetDirectBufferAddress(buffer);
    jlong capacity = env->GetDirectBufferCapacity(buffer);
    size_t needed = values.size() * sizeof(uint16_t);
    if (address == nullptr || capacity < jlong(needed)) return false;
    std::memcpy(address, values.data(), needed);
    return true;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_illixion_convolution_AnalysisNative_storeCreate(JNIEnv*, jclass, jdouble chunkSeconds) {
    if (!(chunkSeconds > 0)) return 0;
    return reinterpret_cast<jlong>(new vgat::ChunkStore(chunkSeconds));
}

JNIEXPORT void JNICALL
Java_com_illixion_convolution_AnalysisNative_storeDestroy(JNIEnv*, jclass, jlong handle) {
    delete store(handle);
}

/* 0 when the chunk parsed, else a vgat::Error code. */
JNIEXPORT jint JNICALL
Java_com_illixion_convolution_AnalysisNative_storePut(JNIEnv* env, jclass, jlong handle, jint index, jbyteArray data,
                                                     jboolean complete) {
    if (handle == 0 || data == nullptr) return jint(vgat::Error::Truncated);
    return jint(store(handle)->put(index, bytes(env, data), complete == JNI_TRUE));
}

JNIEXPORT void JNICALL
Java_com_illixion_convolution_AnalysisNative_storeRetain(JNIEnv*, jclass, jlong handle, jint lo, jint hi) {
    if (handle != 0) store(handle)->retain(lo, hi);
}

JNIEXPORT jboolean JNICALL
Java_com_illixion_convolution_AnalysisNative_storeHoldsWhole(JNIEnv*, jclass, jlong handle, jint index) {
    return handle != 0 && store(handle)->holds_whole(index) ? JNI_TRUE : JNI_FALSE;
}

/* 1: the fields are in the buffers and `dims` (flow w, h, disparity w, h).
   0: no fields for that pair. -1: a buffer is too small; `dims` says the
   sizes, so the caller grows its buffers and asks again. */
JNIEXPORT jint JNICALL
Java_com_illixion_convolution_AnalysisNative_storeFields(JNIEnv* env, jclass, jlong handle, jdouble start, jdouble end,
                                                        jobject flow, jobject mask, jobject disparity0,
                                                        jobject disparity1, jintArray dims, jboolean needsDisparity) {
    if (handle == 0 || dims == nullptr || env->GetArrayLength(dims) < 4) return 0;
    vgat::SharedFields fields;
    if (!store(handle)->shared_fields(start, end, fields, needsDisparity == JNI_TRUE)) return 0;
    jint sizes[4] = {fields.flow_width, fields.flow_height, fields.disparity_width, fields.disparity_height};
    env->SetIntArrayRegion(dims, 0, 4, sizes);
    if (!fill(env, flow, fields.flow_rgba) || !fill(env, mask, fields.mask) ||
        (needsDisparity == JNI_TRUE && (!fill(env, disparity0, fields.disparity0) || !fill(env, disparity1, fields.disparity1)))) {
        return -1;
    }
    return 1;
}

/* A frame's depth map (ai-3d-depth): 1 with the bytes in `out` and `info` =
   width, height, and `mapping` = scale, offset (sample = byte * scale + offset);
   0 when none; -1 when `out` is too small (`info` says the size). */
JNIEXPORT jint JNICALL
Java_com_illixion_convolution_AnalysisNative_storeDepth(JNIEnv* env, jclass, jlong handle, jdouble seconds,
                                                       jdouble tolerance, jobject out, jintArray info,
                                                       jfloatArray mapping) {
    if (handle == 0 || info == nullptr || mapping == nullptr || env->GetArrayLength(info) < 2 ||
        env->GetArrayLength(mapping) < 2) {
        return 0;
    }
    vgat::DepthMap map;
    if (!store(handle)->depth(seconds, tolerance, map)) return 0;
    jint sizes[2] = {map.width, map.height};
    jfloat affine[2] = {map.scale, map.offset};
    env->SetIntArrayRegion(info, 0, 2, sizes);
    env->SetFloatArrayRegion(mapping, 0, 2, affine);
    void* address = out == nullptr ? nullptr : env->GetDirectBufferAddress(out);
    if (address == nullptr || env->GetDirectBufferCapacity(out) < jlong(map.bytes.size())) return -1;
    std::memcpy(address, map.bytes.data(), map.bytes.size());
    return 1;
}

/* A frame's gain grid (ai-hdr) as 16x9x8 half floats into `out` (2304 bytes): 1, or 0 when none. */
JNIEXPORT jint JNICALL
Java_com_illixion_convolution_AnalysisNative_storeGainGrid(JNIEnv* env, jclass, jlong handle, jdouble seconds,
                                                          jdouble tolerance, jobject out) {
    if (handle == 0) return 0;
    std::vector<uint16_t> grid;
    if (!store(handle)->gain_grid(seconds, tolerance, grid)) return 0;
    return fill(env, out, grid) ? 1 : 0;
}

JNIEXPORT jdouble JNICALL
Java_com_illixion_convolution_AnalysisNative_storeNearestPairOffset(JNIEnv*, jclass, jlong handle, jdouble seconds) {
    return handle == 0 ? std::nan("") : store(handle)->nearest_pair_offset(seconds);
}

/* ---- Pairing ---- */

JNIEXPORT jbyteArray JNICALL
Java_com_illixion_convolution_AnalysisNative_pairPublicKey(JNIEnv* env, jclass, jbyteArray secret) {
    uint8_t s[32], pub[32];
    if (!copy_exact(env, secret, s, 32)) return nullptr;
    qcb_pair_public_key(s, pub);
    qcb_wipe(s, sizeof(s));
    return to_java(env, pub, 32);
}

JNIEXPORT jbyteArray JNICALL
Java_com_illixion_convolution_AnalysisNative_pairCommitment(JNIEnv* env, jclass, jbyteArray publicKey, jbyteArray nonce) {
    uint8_t pub[32], n[QCB_PAIR_NONCE_SIZE], out[32];
    if (!copy_exact(env, publicKey, pub, 32) || !copy_exact(env, nonce, n, QCB_PAIR_NONCE_SIZE)) return nullptr;
    qcb_pair_commitment(pub, n, out);
    return to_java(env, out, 32);
}

/* Six ASCII digits, then the 32-byte key; null for an unusable host key. */
JNIEXPORT jbyteArray JNICALL
Java_com_illixion_convolution_AnalysisNative_pairAgree(JNIEnv* env, jclass, jbyteArray secret, jbyteArray nonce,
                                                      jbyteArray hostPublicKey, jbyteArray hostNonce) {
    uint8_t s[32], n[QCB_PAIR_NONCE_SIZE], hp[32], hn[QCB_PAIR_NONCE_SIZE];
    if (!copy_exact(env, secret, s, 32) || !copy_exact(env, nonce, n, QCB_PAIR_NONCE_SIZE) ||
        !copy_exact(env, hostPublicKey, hp, 32) || !copy_exact(env, hostNonce, hn, QCB_PAIR_NONCE_SIZE)) {
        qcb_wipe(s, sizeof(s));
        return nullptr;
    }
    char code[7];
    uint8_t out[6 + 32];
    int result = qcb_pair_agree_labelled(s, n, hp, hn, kVergenceLabel, code, out + 6);
    qcb_wipe(s, sizeof(s));
    if (result != 0) return nullptr;
    std::memcpy(out, code, 6);
    jbyteArray array = to_java(env, out, sizeof(out));
    qcb_wipe(out, sizeof(out));
    return array;
}

/* CryptoKit ChaChaPoly combined form; null when it does not authenticate. */
JNIEXPORT jbyteArray JNICALL
Java_com_illixion_convolution_AnalysisNative_boxOpen(JNIEnv* env, jclass, jbyteArray key, jbyteArray combined) {
    uint8_t k[32];
    if (!copy_exact(env, key, k, 32) || combined == nullptr) return nullptr;
    std::vector<uint8_t> box = bytes(env, combined);
    if (box.size() < 28 || box.size() > 64 * 1024) {
        qcb_wipe(k, sizeof(k));
        return nullptr;
    }
    std::vector<uint8_t> plain(box.size());
    long opened = qcb_chachapoly_open(k, box.data(), box.size(), plain.data());
    qcb_wipe(k, sizeof(k));
    jbyteArray result = opened >= 0 ? to_java(env, plain.data(), size_t(opened)) : nullptr;
    qcb_wipe(plain.data(), plain.size());
    return result;
}

/* The coordinator's bearer token for a paired device:
   hex(HKDF-SHA256(ikm: pairing token, salt: "Vergence-HTTP-Token-v1", info: device id)),
   vergence desktop/src/pairing.rs `http_token`. Both inputs UTF-8. */
JNIEXPORT jstring JNICALL
Java_com_illixion_convolution_AnalysisNative_httpToken(JNIEnv* env, jclass, jbyteArray pairingToken, jbyteArray deviceId) {
    std::vector<uint8_t> token = bytes(env, pairingToken), device = bytes(env, deviceId);
    if (token.empty() || device.empty()) return nullptr;
    uint8_t out[32];
    qcb_hkdf_sha256(token.data(), token.size(), reinterpret_cast<const uint8_t*>(kHttpTokenSalt),
                    std::strlen(kHttpTokenSalt), device.data(), device.size(), out, sizeof(out));
    qcb_wipe(token.data(), token.size());
    char hex[65];
    static const char digits[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        hex[2 * i] = digits[out[i] >> 4];
        hex[2 * i + 1] = digits[out[i] & 15];
    }
    hex[64] = '\0';
    qcb_wipe(out, sizeof(out));
    return env->NewStringUTF(hex);
}

}  // extern "C"
