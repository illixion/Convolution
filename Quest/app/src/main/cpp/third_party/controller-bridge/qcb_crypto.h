/**
 * Controller Bridge - pairing and sealed datagrams (protocol v5)
 *
 * Portable C (C99), built into the Quest app and into every host that pairs.
 * The primitives come from Monocypher (third_party/monocypher, X25519 and
 * ChaCha20-Poly1305); SHA-256, HMAC and HKDF are here because Monocypher only
 * ships SHA-512 and the pairing must match Longwave's CryptoKit code exactly.
 *
 * Pairing
 * -------
 * The Quest plays the "headset" role of Longwave's numeric-comparison pairing
 * (Shared/CompanionPairing.swift, CompanionWindows/backend/Devices/Pairing.cs):
 * it commits to SHA256(public key || nonce), the host answers with its own key
 * and nonce, the Quest reveals, and both sides derive
 *     transcript = SHA256(commitment || hostPub || hostNonce || questPub || questNonce)
 *     key        = HKDF-SHA256(X25519 shared, salt: transcript, info: "Longwave-Pair-v1")
 *     code       = big-endian u32 of transcript[0..4] mod 1 000 000, six digits.
 * The Quest shows the code; the host's user compares it and approves. The host
 * then seals a grant (JSON with the device token) to `key`, in CryptoKit's
 * ChaChaPoly combined layout: nonce(12) || ciphertext || tag(16).
 * test_qcb_crypto.c pins all of it to values CryptoKit produced.
 *
 * Sealed datagrams
 * ----------------
 * Every packet to and from a paired host is wrapped in qcb_sealed_header_t
 * (quest_bridge_protocol.h) and sealed with ChaCha20-Poly1305 (RFC 8439):
 *     key id      = HMAC-SHA256(token, "ControllerBridge-KeyID-v1")[0..8]
 *     sender key  = HKDF-SHA256(token, salt: sender session,
 *                               info: "ControllerBridge-Seal-v2 sender")
 *     host key    = HKDF-SHA256(token, salt: sender session || host session,
 *                               info: "ControllerBridge-Seal-v2 host")
 *     nonce       = 00 00 00 00 || counter (u64 little-endian)
 *     AAD         = the 36-byte header
 * Each side picks 16 cryptographically random session bytes when it starts.
 * A sender packet from an unknown session is only a session proposal: the host
 * challenges it with a fresh 32-byte nonce. The Quest confirms that nonce under
 * its sender key, and the host accepts only that challenge response from the
 * endpoint that proposed the session. The host then sends an authenticated
 * accept tied to the same challenge. No controller input or haptic is acted on
 * before this exchange completes. A source-address change within a session is
 * challenged too. This makes captured packets inert across process restarts or
 * endpoint changes, without durable replay state.
 */

#ifndef QCB_CRYPTO_H
#define QCB_CRYPTO_H

#include "quest_bridge_protocol.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Hashes ---- */

void qcb_sha256(const uint8_t* data, size_t size, uint8_t out[32]);
void qcb_hmac_sha256(const uint8_t* key, size_t key_size,
                     const uint8_t* message, size_t message_size, uint8_t out[32]);
/* RFC 5869. `out_size` <= 255 * 32. An empty salt means 32 zero bytes. */
void qcb_hkdf_sha256(const uint8_t* ikm, size_t ikm_size,
                     const uint8_t* salt, size_t salt_size,
                     const uint8_t* info, size_t info_size,
                     uint8_t* out, size_t out_size);

/* ---- Pairing ---- */

#define QCB_PAIR_NONCE_SIZE 32

/* `secret` is 32 random bytes; the public key is its X25519 public key. */
void qcb_pair_public_key(const uint8_t secret[32], uint8_t public_key[32]);
void qcb_pair_commitment(const uint8_t public_key[32], const uint8_t nonce[QCB_PAIR_NONCE_SIZE],
                         uint8_t out[32]);
/* The Quest's side, once the host's key and nonce arrived. Writes the six digits
   (NUL-terminated) and the agreed key. Returns 0, or -1 for an unusable host key
   (an all-zero shared secret, which CryptoKit refuses too). */
int qcb_pair_agree(const uint8_t secret[32],
                   const uint8_t nonce[QCB_PAIR_NONCE_SIZE],
                   const uint8_t host_public_key[32],
                   const uint8_t host_nonce[QCB_PAIR_NONCE_SIZE],
                   char code[7], uint8_t key[32]);
/* The same in another app's namespace: the key's HKDF info is
   "<label_prefix>-Pair-v1" (RAVECompanionNamespace's labelPrefix; Longwave's is
   "Longwave", which qcb_pair_agree uses, Vergence's coordinator "Vergence").
   The transcript and the code don't depend on it. Returns -1 for an unusable
   host key or a prefix over 87 bytes. */
int qcb_pair_agree_labelled(const uint8_t secret[32],
                            const uint8_t nonce[QCB_PAIR_NONCE_SIZE],
                            const uint8_t host_public_key[32],
                            const uint8_t host_nonce[QCB_PAIR_NONCE_SIZE],
                            const char* label_prefix,
                            char code[7], uint8_t key[32]);

/* CryptoKit ChaChaPoly combined form. `out` holds size + 28 bytes. */
void qcb_chachapoly_seal(const uint8_t key[32], const uint8_t nonce[12],
                         const uint8_t* plain, size_t size, uint8_t* out);
/* `out` holds combined_size - 28 bytes. Returns the plaintext size, or -1. */
long qcb_chachapoly_open(const uint8_t key[32], const uint8_t* combined, size_t combined_size,
                         uint8_t* out);

/* ---- Sealed datagrams ---- */

void qcb_seal_key_id(const uint8_t* token, size_t token_size, uint8_t out[8]);
/* QCB_SEAL_FROM_SENDER: `host_session` is ignored (pass NULL).
   QCB_SEAL_FROM_HOST: both sessions name the key. */
void qcb_seal_session_key(const uint8_t* token, size_t token_size,
                          const uint8_t sender_session[QCB_SEAL_SESSION_SIZE],
                          const uint8_t* host_session,
                          uint8_t direction, uint8_t key[32]);

/* Seal `inner` (a plain v3 packet) into `out` (inner_size + QCB_SEAL_OVERHEAD
   bytes). Returns the datagram size. */
size_t qcb_seal_packet(const uint8_t key[32], const uint8_t key_id[8],
                       const uint8_t session[QCB_SEAL_SESSION_SIZE],
                       uint8_t direction, uint64_t counter,
                       const uint8_t* inner, size_t inner_size, uint8_t* out);

/* The header fields of a datagram that looks sealed; -1 when it does not. */
int qcb_sealed_peek(const uint8_t* packet, size_t size, uint8_t key_id[8],
                    uint8_t session[QCB_SEAL_SESSION_SIZE],
                    uint8_t* direction, uint64_t* counter);

/* Open a sealed datagram with its session key. Writes size - QCB_SEAL_OVERHEAD
   bytes to `inner`. Returns the inner size, or -1 when it does not authenticate.
   Replay checking is the caller's: compare the counter from qcb_sealed_peek. */
long qcb_open_packet(const uint8_t key[32], const uint8_t* packet, size_t size, uint8_t* inner);

/* Zero memory the compiler may not optimise away. */
void qcb_wipe(void* data, size_t size);

#ifdef __cplusplus
}
#endif

#endif /* QCB_CRYPTO_H */
