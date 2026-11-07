/* Controller Bridge - pairing and sealed datagrams. See qcb_crypto.h. */

#include "qcb_crypto.h"
#include "quest_bridge_protocol.h"
#include "third_party/monocypher/monocypher.h"

#include <string.h>

void qcb_wipe(void* data, size_t size) {
    crypto_wipe(data, size);
}

/* ------------------------------------------------------------------------ */
/*  SHA-256 (FIPS 180-4)                                                      */
/* ------------------------------------------------------------------------ */

typedef struct {
    uint32_t state[8];
    uint64_t length;      /* bytes */
    uint8_t  block[64];
    size_t   used;
} sha256_ctx;

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_compress(uint32_t s[8], const uint8_t b[64]) {
    uint32_t w[64];
    int i;
    for (i = 0; i < 16; i++) {
        w[i] = (uint32_t)b[4 * i] << 24 | (uint32_t)b[4 * i + 1] << 16 |
               (uint32_t)b[4 * i + 2] << 8 | (uint32_t)b[4 * i + 3];
    }
    for (i = 16; i < 64; i++) {
        uint32_t s0 = ROTR(w[i - 15], 7) ^ ROTR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROTR(w[i - 2], 17) ^ ROTR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = s[0], bb = s[1], c = s[2], d = s[3], e = s[4], f = s[5], g = s[6], h = s[7];
    for (i = 0; i < 64; i++) {
        uint32_t t1 = h + (ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
        uint32_t t2 = (ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22)) + ((a & bb) ^ (a & c) ^ (bb & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
    }
    s[0] += a; s[1] += bb; s[2] += c; s[3] += d; s[4] += e; s[5] += f; s[6] += g; s[7] += h;
    crypto_wipe(w, sizeof(w));
}

static void sha256_init(sha256_ctx* c) {
    static const uint32_t iv[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    memcpy(c->state, iv, sizeof(iv));
    c->length = 0;
    c->used = 0;
}

static void sha256_update(sha256_ctx* c, const uint8_t* data, size_t size) {
    c->length += size;
    while (size > 0) {
        size_t take = 64 - c->used;
        if (take > size) take = size;
        memcpy(c->block + c->used, data, take);
        c->used += take;
        data += take;
        size -= take;
        if (c->used == 64) {
            sha256_compress(c->state, c->block);
            c->used = 0;
        }
    }
}

static void sha256_final(sha256_ctx* c, uint8_t out[32]) {
    uint64_t bits = c->length * 8;
    uint8_t pad = 0x80;
    sha256_update(c, &pad, 1);
    pad = 0;
    while (c->used != 56) sha256_update(c, &pad, 1);
    uint8_t len[8];
    for (int i = 0; i < 8; i++) len[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_update(c, len, 8);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(c->state[i] >> 24);
        out[4 * i + 1] = (uint8_t)(c->state[i] >> 16);
        out[4 * i + 2] = (uint8_t)(c->state[i] >> 8);
        out[4 * i + 3] = (uint8_t)c->state[i];
    }
    crypto_wipe(c, sizeof(*c));
}

void qcb_sha256(const uint8_t* data, size_t size, uint8_t out[32]) {
    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, data, size);
    sha256_final(&c, out);
}

typedef struct {
    sha256_ctx inner;
    uint8_t outer_key[64];
} hmac_ctx;

static void hmac_init(hmac_ctx* h, const uint8_t* key, size_t key_size) {
    uint8_t k[64] = {0};
    if (key_size > 64) {
        qcb_sha256(key, key_size, k);
    } else if (key_size > 0) {
        memcpy(k, key, key_size);
    }
    uint8_t ipad[64];
    for (int i = 0; i < 64; i++) {
        ipad[i] = k[i] ^ 0x36;
        h->outer_key[i] = k[i] ^ 0x5c;
    }
    sha256_init(&h->inner);
    sha256_update(&h->inner, ipad, 64);
    crypto_wipe(k, sizeof(k));
    crypto_wipe(ipad, sizeof(ipad));
}

static void hmac_final(hmac_ctx* h, uint8_t out[32]) {
    uint8_t inner[32];
    sha256_final(&h->inner, inner);
    sha256_ctx outer;
    sha256_init(&outer);
    sha256_update(&outer, h->outer_key, 64);
    sha256_update(&outer, inner, 32);
    sha256_final(&outer, out);
    crypto_wipe(inner, sizeof(inner));
    crypto_wipe(h, sizeof(*h));
}

void qcb_hmac_sha256(const uint8_t* key, size_t key_size,
                     const uint8_t* message, size_t message_size, uint8_t out[32]) {
    hmac_ctx h;
    hmac_init(&h, key, key_size);
    sha256_update(&h.inner, message, message_size);
    hmac_final(&h, out);
}

void qcb_hkdf_sha256(const uint8_t* ikm, size_t ikm_size,
                     const uint8_t* salt, size_t salt_size,
                     const uint8_t* info, size_t info_size,
                     uint8_t* out, size_t out_size) {
    static const uint8_t zero_salt[32] = {0};
    uint8_t prk[32];
    if (salt_size == 0) {
        salt = zero_salt;
        salt_size = sizeof(zero_salt);
    }
    qcb_hmac_sha256(salt, salt_size, ikm, ikm_size, prk);

    uint8_t t[32];
    size_t t_size = 0;
    uint8_t counter = 1;
    while (out_size > 0) {
        hmac_ctx h;
        hmac_init(&h, prk, sizeof(prk));
        sha256_update(&h.inner, t, t_size);
        sha256_update(&h.inner, info, info_size);
        sha256_update(&h.inner, &counter, 1);
        hmac_final(&h, t);
        t_size = 32;
        size_t take = out_size < 32 ? out_size : 32;
        memcpy(out, t, take);
        out += take;
        out_size -= take;
        counter++;
    }
    crypto_wipe(prk, sizeof(prk));
    crypto_wipe(t, sizeof(t));
}

/* ------------------------------------------------------------------------ */
/*  Pairing                                                                   */
/* ------------------------------------------------------------------------ */

void qcb_pair_public_key(const uint8_t secret[32], uint8_t public_key[32]) {
    crypto_x25519_public_key(public_key, secret);
}

void qcb_pair_commitment(const uint8_t public_key[32], const uint8_t nonce[QCB_PAIR_NONCE_SIZE],
                         uint8_t out[32]) {
    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, public_key, 32);
    sha256_update(&c, nonce, QCB_PAIR_NONCE_SIZE);
    sha256_final(&c, out);
}

int qcb_pair_agree_labelled(const uint8_t secret[32],
                            const uint8_t nonce[QCB_PAIR_NONCE_SIZE],
                            const uint8_t host_public_key[32],
                            const uint8_t host_nonce[QCB_PAIR_NONCE_SIZE],
                            const char* label_prefix,
                            char code[7], uint8_t key[32]) {
    uint8_t mine[32], commitment[32], shared[32], transcript[32];
    qcb_pair_public_key(secret, mine);
    qcb_pair_commitment(mine, nonce, commitment);

    crypto_x25519(shared, secret, host_public_key);
    uint8_t any = 0;
    for (int i = 0; i < 32; i++) any |= shared[i];
    if (any == 0) {
        crypto_wipe(shared, sizeof(shared));
        return -1;
    }

    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, commitment, 32);
    sha256_update(&c, host_public_key, 32);
    sha256_update(&c, host_nonce, QCB_PAIR_NONCE_SIZE);
    sha256_update(&c, mine, 32);
    sha256_update(&c, nonce, QCB_PAIR_NONCE_SIZE);
    sha256_final(&c, transcript);

    /* "<prefix>-Pair-v1", as RAVECompanionNamespace names it. */
    char info[96];
    size_t prefix = strlen(label_prefix);
    if (prefix > sizeof(info) - sizeof("-Pair-v1")) {
        crypto_wipe(shared, sizeof(shared));
        return -1;
    }
    memcpy(info, label_prefix, prefix);
    memcpy(info + prefix, "-Pair-v1", sizeof("-Pair-v1") - 1);
    qcb_hkdf_sha256(shared, 32, transcript, 32, (const uint8_t*)info, prefix + sizeof("-Pair-v1") - 1, key, 32);

    uint32_t number = (uint32_t)transcript[0] << 24 | (uint32_t)transcript[1] << 16 |
                      (uint32_t)transcript[2] << 8 | transcript[3];
    number %= 1000000u;
    for (int i = 5; i >= 0; i--) {
        code[i] = (char)('0' + number % 10);
        number /= 10;
    }
    code[6] = '\0';
    crypto_wipe(shared, sizeof(shared));
    return 0;
}

int qcb_pair_agree(const uint8_t secret[32],
                   const uint8_t nonce[QCB_PAIR_NONCE_SIZE],
                   const uint8_t host_public_key[32],
                   const uint8_t host_nonce[QCB_PAIR_NONCE_SIZE],
                   char code[7], uint8_t key[32]) {
    return qcb_pair_agree_labelled(secret, nonce, host_public_key, host_nonce, "Longwave", code, key);
}

void qcb_chachapoly_seal(const uint8_t key[32], const uint8_t nonce[12],
                         const uint8_t* plain, size_t size, uint8_t* out) {
    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, key, nonce);
    memcpy(out, nonce, 12);
    crypto_aead_write(&ctx, out + 12, out + 12 + size, NULL, 0, plain, size);
    crypto_wipe(&ctx, sizeof(ctx));
}

long qcb_chachapoly_open(const uint8_t key[32], const uint8_t* combined, size_t combined_size,
                         uint8_t* out) {
    if (combined_size < 28) return -1;
    size_t size = combined_size - 28;
    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, key, combined);
    int bad = crypto_aead_read(&ctx, out, combined + 12 + size, NULL, 0, combined + 12, size);
    crypto_wipe(&ctx, sizeof(ctx));
    return bad ? -1 : (long)size;
}

/* ------------------------------------------------------------------------ */
/*  Sealed datagrams                                                          */
/* ------------------------------------------------------------------------ */

void qcb_seal_key_id(const uint8_t* token, size_t token_size, uint8_t out[8]) {
    static const char label[] = "ControllerBridge-KeyID-v1";
    uint8_t mac[32];
    qcb_hmac_sha256(token, token_size, (const uint8_t*)label, sizeof(label) - 1, mac);
    memcpy(out, mac, 8);
}

void qcb_seal_session_key(const uint8_t* token, size_t token_size,
                          const uint8_t sender_session[QCB_SEAL_SESSION_SIZE], const uint8_t* host_session,
                          uint8_t direction, uint8_t key[32]) {
    static const char sender[] = "ControllerBridge-Seal-v2 sender";
    static const char host[] = "ControllerBridge-Seal-v2 host";
    const char* info = direction == QCB_SEAL_FROM_HOST ? host : sender;
    size_t info_size = direction == QCB_SEAL_FROM_HOST ? sizeof(host) - 1 : sizeof(sender) - 1;
    uint8_t salt[2 * QCB_SEAL_SESSION_SIZE];
    size_t salt_size = QCB_SEAL_SESSION_SIZE;
    memcpy(salt, sender_session, QCB_SEAL_SESSION_SIZE);
    if (direction == QCB_SEAL_FROM_HOST) {
        memcpy(salt + QCB_SEAL_SESSION_SIZE, host_session, QCB_SEAL_SESSION_SIZE);
        salt_size = sizeof(salt);
    }
    qcb_hkdf_sha256(token, token_size, salt, salt_size, (const uint8_t*)info, info_size, key, 32);
}

static void seal_nonce(uint64_t counter, uint8_t nonce[12]) {
    memset(nonce, 0, 4);
    for (int i = 0; i < 8; i++) nonce[4 + i] = (uint8_t)(counter >> (8 * i));
}

size_t qcb_seal_packet(const uint8_t key[32], const uint8_t key_id[8],
                       const uint8_t session[QCB_SEAL_SESSION_SIZE],
                       uint8_t direction, uint64_t counter,
                       const uint8_t* inner, size_t inner_size, uint8_t* out) {
    out[0] = QCB_PACKET_SEALED;
    out[1] = QCB_SEAL_VERSION;
    out[2] = direction;
    out[3] = 0;
    memcpy(out + 4, key_id, 8);
    memcpy(out + 12, session, QCB_SEAL_SESSION_SIZE);
    for (int i = 0; i < 8; i++) out[28 + i] = (uint8_t)(counter >> (8 * i));

    uint8_t nonce[12];
    seal_nonce(counter, nonce);
    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, key, nonce);
    crypto_aead_write(&ctx, out + QCB_SEAL_HEADER_SIZE, out + QCB_SEAL_HEADER_SIZE + inner_size,
                      out, QCB_SEAL_HEADER_SIZE, inner, inner_size);
    crypto_wipe(&ctx, sizeof(ctx));
    return inner_size + QCB_SEAL_OVERHEAD;
}

int qcb_sealed_peek(const uint8_t* packet, size_t size, uint8_t key_id[8],
                    uint8_t session[QCB_SEAL_SESSION_SIZE],
                    uint8_t* direction, uint64_t* counter) {
    if (size < QCB_SEAL_OVERHEAD || packet[0] != QCB_PACKET_SEALED ||
        packet[1] != QCB_SEAL_VERSION || packet[2] > QCB_SEAL_FROM_HOST) {
        return -1;
    }
    if (key_id) memcpy(key_id, packet + 4, 8);
    if (session) memcpy(session, packet + 12, QCB_SEAL_SESSION_SIZE);
    if (direction) *direction = packet[2];
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value |= (uint64_t)packet[28 + i] << (8 * i);
    if (value == 0) return -1;
    if (counter) *counter = value;
    return 0;
}

long qcb_open_packet(const uint8_t key[32], const uint8_t* packet, size_t size, uint8_t* inner) {
    uint64_t counter;
    if (qcb_sealed_peek(packet, size, NULL, NULL, NULL, &counter) != 0) return -1;
    size_t inner_size = size - QCB_SEAL_OVERHEAD;
    uint8_t nonce[12];
    seal_nonce(counter, nonce);
    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, key, nonce);
    int bad = crypto_aead_read(&ctx, inner, packet + QCB_SEAL_HEADER_SIZE + inner_size,
                               packet, QCB_SEAL_HEADER_SIZE,
                               packet + QCB_SEAL_HEADER_SIZE, inner_size);
    crypto_wipe(&ctx, sizeof(ctx));
    return bad ? -1 : (long)inner_size;
}
