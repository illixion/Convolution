/**
 * Controller Bridge - Network Protocol Definition
 *
 * The single source of truth for the wire format between the Controller Bridge
 * app on a Meta Quest (the sender) and a host: the bundled SteamVR driver, or a
 * visionOS app using RAVEInput's RAVEQuestBridgeSource. Every other copy of this
 * layout (the Swift codec, the Python tools, hosts that vendor the struct) is
 * pinned against the byte offsets documented here. All values are little-endian,
 * structs are packed.
 *
 * Versioning
 * ----------
 * Version 1 had no version byte in the controller state packet; its last two
 * bytes were a zeroed `reserved` word. Version 2 splits that word into
 * `protocol_version` and `sender`, so:
 *   - a v1 host reads a v2 packet exactly as before (it never looked at those
 *     bytes), and
 *   - a v2 host reads protocol_version == 0 as "v1 sender".
 * The probe and status packets always carried a version byte. The rule for both
 * directions is: accept any version >= QCB_PROTOCOL_VERSION_MIN (the layouts are
 * fixed, versions only add meaning to bits that used to be zero), and answer a
 * peer at min(its version, yours) - a v1 Quest app rejects a status whose
 * version is not exactly 1, so a host must not speak v2 to it.
 *
 * Version 3 adds zero-touch discovery (see "Discovery" below): a probe reply
 * negotiated at v3 or later carries a host-info trailer after the 16-byte
 * status. Nothing else changed, so v3 is safe in both directions: an older
 * host answers a v3 probe at its own version with the plain 16 bytes (the
 * sender then knows only its address), and an older sender never gets a
 * trailer because it never announces v3.
 *
 * Discovery
 * ---------
 * Two mechanisms, used together because neither is reliable alone (Quest NSD
 * and Windows mDNS are both flaky, and visionOS apps cannot receive broadcasts
 * without Apple's managed multicast entitlement):
 *   1. DNS-SD: a host advertises QCB_BONJOUR_SERVICE_TYPE on its listen port;
 *      the sender browses, resolves, and then unicast-probes each result.
 *   2. Probes: the sender sends the ordinary 0xF0 probe to its Wi-Fi subnet's
 *      broadcast address, to 255.255.255.255 and (as a fallback for hosts that
 *      cannot hear broadcasts) unicast to addresses it already knows or that
 *      it sweeps on a small subnet, all on QCB_DEFAULT_PORT. Every host
 *      answers every probe unicast, to the probing socket, with a status
 *      packet - at v3, plus qcb_host_info_t: kind, whether it is accepting a
 *      sender right now, and a human-readable name. The name is the identity
 *      a sender remembers ("last used"), so a host that changes address is
 *      found again by name.
 * A host must answer probes whenever it is listening, whether or not it is
 * streaming, and must not treat a probe as a sender (no retargeting of the
 * haptic/heartbeat destination).
 */

#ifndef QUEST_BRIDGE_PROTOCOL_H
#define QUEST_BRIDGE_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Packet types */
#define QCB_PACKET_CONTROLLER_STATE  0x01
#define QCB_PACKET_HAPTIC            0x02
#define QCB_PACKET_SEALED            0xE0   /* see "Paired hosts" below */
#define QCB_PACKET_DISCOVERY         0xF0
#define QCB_PACKET_STATUS            0xF1
#define QCB_PACKET_SESSION_CHALLENGE 0xF2 /* paired sealed inner packets */
#define QCB_PACKET_SESSION_CONFIRM   0xF3
#define QCB_PACKET_SESSION_ACCEPT    0xF4

/*
 * Paired hosts (sealed)
 * ---------------------
 * A host the Quest paired with (Longwave's numeric-comparison pairing: the
 * Quest shows six digits, the host's user approves; qcb_crypto.h) gets every
 * packet sealed: qcb_sealed_header_t, then the inner packet encrypted, then a
 * 16-byte tag. Same state, haptic and status packet formats inside. The v2
 * header is 36 bytes and carries a random 16-byte writer session and a
 * nonzero 64-bit counter.
 *   - The Quest sends from one socket per paired host and the host answers -
 *     heartbeats (0xF1, nonce 0) and haptics (0x02), sealed in the other
 *     direction - to the address and port the last authenticated packet came
 *     from. Nothing goes to QCB_HAPTIC_PORT_OFFSET, so it works through NAT.
 *   - A new sender session is only a proposal. The host sends a fresh
 *     SESSION_CHALLENGE (0xF2); the Quest answers with SESSION_CONFIRM (0xF3)
 *     under the sender key; the host replies with SESSION_ACCEPT (0xF4) under
 *     the host key. Neither controller state nor haptics are acted on before
 *     confirmation. This makes captured datagrams from before either process
 *     restarted unusable, even though replay counters are kept only in memory.
 *   - A changed source endpoint is challenged before the host forwards input or
 *     retargets haptics. A host takes sealed packets only for key ids it
 *     enrolled and drops counters not newer than the last accepted counter.
 *     The host's random session changes on process restart, deriving fresh
 *     host-direction keys and requiring a new challenge exchange.
 *   - A heartbeat is sent at least every 2 s while sealed packets arrive; the
 *     Quest falls back to trying every address after 6 s without one.
 *   - No probes, no names: the Quest knows a paired host by the id it paired
 *     with, reaches it at the addresses the grant listed (LAN, Tailscale, a
 *     typed one) and stays on whichever answers.
 * The open v1-v3 packets stay valid for hosts that do not pair; the Quest keeps
 * paired and open hosts side by side and can stream to several at once.
 */
#define QCB_SEAL_VERSION             2
#define QCB_SEAL_SESSION_SIZE        16
#define QCB_SEAL_CHALLENGE_SIZE      32
#define QCB_SEAL_HEADER_SIZE         36
#define QCB_SEAL_TAG_SIZE            16
#define QCB_SEAL_OVERHEAD            (QCB_SEAL_HEADER_SIZE + QCB_SEAL_TAG_SIZE)

/* Inner payloads of the paired-host session handshake. Each is carried inside
 * a QCB_PACKET_SEALED datagram. The challenge echoes the proposed sender
 * session so a Quest never answers a challenge for a captured old session. */
typedef struct {
    uint8_t packet_type; /* QCB_PACKET_SESSION_CHALLENGE */
    uint8_t sender_session[QCB_SEAL_SESSION_SIZE];
    uint8_t challenge[QCB_SEAL_CHALLENGE_SIZE];
} qcb_session_challenge_t;

typedef struct {
    uint8_t packet_type; /* QCB_PACKET_SESSION_CONFIRM or _ACCEPT */
    uint8_t challenge[QCB_SEAL_CHALLENGE_SIZE];
} qcb_session_response_t;
#define QCB_SEAL_FROM_SENDER         0    /* Quest -> host */
#define QCB_SEAL_FROM_HOST           1    /* host -> Quest */
/* Where a Longwave PC takes the sealed stream unless its grant names a port. */
#define QCB_SEALED_DEFAULT_PORT      9522

/* Protocol compatibility (see "Versioning" above) */
#define QCB_PROTOCOL_VERSION         3
#define QCB_PROTOCOL_VERSION_MIN     1

/* Default network settings */
#define QCB_DEFAULT_PORT             9520
#define QCB_HAPTIC_PORT_OFFSET       1    /* Haptic port = QCB_DEFAULT_PORT + 1 */

/* DNS-SD discovery (v2). A host SHOULD advertise this service type with the
 * port it listens on; a sender browses for it alongside broadcast probes and
 * falls back to a typed address. The TXT record carries "v=<protocol
 * version>". Nothing requires it: a host that does not advertise is reached
 * by broadcast probe or by address. */
#define QCB_BONJOUR_SERVICE_TYPE     "_controllerbridge._udp"

/* Status flags */
#define QCB_STATUS_DRIVER_READY      (1u << 0)

/* qcb_host_info_t.host_kind (v3). Informational: the sender shows it. */
#define QCB_HOST_OTHER               0    /* anything else, or not saying */
#define QCB_HOST_VISIONOS_APP        1    /* an app using RAVEQuestBridgeSource */
#define QCB_HOST_STEAMVR_DRIVER      2    /* the bundled SteamVR driver */
#define QCB_HOST_TEST_TOOL           3    /* tools/ scripts */

/* qcb_host_info_t.host_flags (v3) */
/* The host will take controller packets from the prober right now: it is
 * listening and not already streaming from a different sender. A sender only
 * connects to an accepting host without asking the user. */
#define QCB_HOST_ACCEPTING           (1u << 0)

/* Longest host name, in UTF-8 bytes, a host-info trailer carries. Longer
 * names are cut at a character boundary. */
#define QCB_HOST_NAME_MAX            44

/* Button bitmask definitions. The *_TOUCH bits are capacitive readings and are
 * only meaningful when QCB_FLAG_TOUCH is set (v1 senders defined but never
 * populated them). THUMB_TOUCH means the thumb rests on the stick, a face
 * button or the thumbrest. */
#define QCB_BTN_A                    (1u << 0)
#define QCB_BTN_B                    (1u << 1)
#define QCB_BTN_X                    (1u << 2)
#define QCB_BTN_Y                    (1u << 3)
#define QCB_BTN_LSTICK_CLICK         (1u << 4)
#define QCB_BTN_RSTICK_CLICK         (1u << 5)
#define QCB_BTN_LMENU                (1u << 6)
#define QCB_BTN_RMENU                (1u << 7)
#define QCB_BTN_LTRIGGER_TOUCH       (1u << 8)
#define QCB_BTN_RTRIGGER_TOUCH       (1u << 9)
#define QCB_BTN_LTHUMB_TOUCH         (1u << 10)
#define QCB_BTN_RTHUMB_TOUCH         (1u << 11)
#define QCB_BTN_LGRIP_CLICK          (1u << 12)
#define QCB_BTN_RGRIP_CLICK          (1u << 13)

/* Flags */
#define QCB_FLAG_LEFT_TRACKED        (1u << 0)
#define QCB_FLAG_RIGHT_TRACKED       (1u << 1)
/* battery_left/battery_right carry a reading. Clear on every packet from a build
 * that cannot read the batteries at all, so a receiver can tell "no battery
 * support" from "supported, but this controller's level is unknown". */
#define QCB_FLAG_BATTERY             (1u << 2)

/* Battery percentage sentinel: the level for that side is not currently known
 * (controller off, never paired, or the dump did not mention it). */
#define QCB_BATTERY_UNKNOWN          0xFF
/* The *_TOUCH button bits carry real readings (v2). Without it a clear touch
 * bit means "unknown", not "not touching". */
#define QCB_FLAG_TOUCH               (1u << 3)
/* The sender is running but the headset has given input to something else (a
 * system menu, a boundary or "put the headset on" prompt, an open 2D panel):
 * poses and buttons are absent for that reason, not because the controllers
 * are off or out of view. Set by the Quest app from 2.2; older senders never
 * set it, so a clear bit means "focused or unknown". */
#define QCB_FLAG_UNFOCUSED           (1u << 4)

/* qcb_controller_state_t.sender - who produced the packet (v2). Informational:
 * hosts log it and may use it to tell a test tool from a headset. */
#define QCB_SENDER_UNKNOWN           0    /* v1 sender: the byte was reserved */
#define QCB_SENDER_QUEST_APP         1    /* the Controller Bridge Quest app */
#define QCB_SENDER_TEST_TOOL         2    /* tools/test_sender.py and friends */

#pragma pack(push, 1)

/**
 * Controller state packet (Quest -> host)
 * 100 bytes, sent at frame rate (~72 Hz). Poses are the OpenXR grip poses in
 * the Quest's STAGE space (LOCAL if STAGE is unavailable), Y up, metres.
 *
 * Offsets: 0 type, 1 sequence, 2 flags, 4 left_pos, 16 left_rot, 32 right_pos,
 * 44 right_rot, 60 left trigger/grip/stick x/y, 76 right trigger/grip/stick x/y,
 * 92 buttons, 96 battery_left, 97 battery_right, 98 protocol_version, 99 sender.
 */
typedef struct {
    uint8_t  packet_type;       /* QCB_PACKET_CONTROLLER_STATE (0x01) */
    uint8_t  sequence;          /* Wrapping sequence number */
    uint16_t flags;             /* QCB_FLAG_* */

    /* Left controller pose */
    float left_pos[3];          /* x, y, z in meters */
    float left_rot[4];          /* quaternion x, y, z, w */

    /* Right controller pose */
    float right_pos[3];
    float right_rot[4];

    /* Left controller analog inputs */
    float left_trigger;
    float left_grip;
    float left_thumbstick_x;
    float left_thumbstick_y;

    /* Right controller analog inputs */
    float right_trigger;
    float right_grip;
    float right_thumbstick_x;
    float right_thumbstick_y;

    /* Button bitmask */
    uint32_t buttons;

    /* Controller battery, 0-100 percent, or QCB_BATTERY_UNKNOWN. Only meaningful
     * when QCB_FLAG_BATTERY is set; a sender that cannot read them leaves both at
     * QCB_BATTERY_UNKNOWN with the flag clear. Read out of band (dumpsys, ~30 s
     * cadence) rather than per frame — the value is stale by design and only ever
     * drives a HUD. */
    uint8_t  battery_left;
    uint8_t  battery_right;

    /* v2: QCB_PROTOCOL_VERSION of the sender; 0 from a v1 sender, whose
     * packets zeroed these two bytes as `reserved`. Offset 98. */
    uint8_t  protocol_version;
    /* v2: QCB_SENDER_*. Offset 99. */
    uint8_t  sender;

} qcb_controller_state_t;

/**
 * Haptic feedback packet (host -> Quest, to the sender's address on
 * port + QCB_HAPTIC_PORT_OFFSET). 14 bytes.
 */
typedef struct {
    uint8_t  packet_type;       /* QCB_PACKET_HAPTIC (0x02) */
    uint8_t  controller;        /* 0 = left, 1 = right */
    float    duration;          /* Seconds */
    float    frequency;         /* Hz */
    float    amplitude;         /* 0.0 - 1.0 */
} qcb_haptic_packet_t;

/**
 * Connectivity and discovery probe (Quest -> host port, unicast or broadcast).
 * Answered with a status packet sent back to the probing socket, nonce echoed,
 * at the negotiated version - at v3 or later with the host-info trailer
 * (qcb_status_ex_packet_t). 8 bytes.
 */
typedef struct {
    uint8_t  packet_type;       /* QCB_PACKET_DISCOVERY (0xF0) */
    uint8_t  protocol_version;
    uint16_t reserved;
    uint32_t nonce;
} qcb_discovery_packet_t;

/**
 * Host status (host -> Quest). Two uses, one layout (16 bytes):
 *   - probe reply, back to the probing socket, nonce echoed;
 *   - unsolicited heartbeat while 0x01 packets arrive, to the sender's address
 *     on port + QCB_HAPTIC_PORT_OFFSET, nonce 0. The Quest app plays its
 *     "connected" pulse on the first one, so a host that never sends it leaves
 *     the user without confirmation. Send the first on the first packet and
 *     then every couple of seconds.
 */
typedef struct {
    uint8_t  packet_type;       /* QCB_PACKET_STATUS (0xF1) */
    uint8_t  protocol_version;
    uint16_t flags;             /* QCB_STATUS_* */
    uint32_t nonce;             /* Echoed from discovery packet */
    uint32_t packets_received;
    uint32_t reserved;
} qcb_status_packet_t;

/**
 * Host info (v3), appended to a probe reply - never to a heartbeat - when the
 * negotiated version is 3 or later. 48 bytes; the name is UTF-8, `name_length`
 * bytes long, zero-padded, not NUL-terminated when it fills the field.
 * A receiver reads it only when the status version is >= 3 and the datagram
 * is at least sizeof(qcb_status_ex_packet_t); otherwise the host is an older
 * one and has no name (show its address).
 */
typedef struct {
    uint8_t  host_kind;         /* QCB_HOST_* kind, offset 16 in the packet */
    uint8_t  host_flags;        /* QCB_HOST_ACCEPTING, offset 17 */
    uint8_t  name_length;       /* 0 - QCB_HOST_NAME_MAX, offset 18 */
    uint8_t  reserved;          /* offset 19 */
    char     name[QCB_HOST_NAME_MAX];   /* offset 20 */
} qcb_host_info_t;

/** A v3+ probe reply: the status, then the host info. 64 bytes. */
typedef struct {
    qcb_status_packet_t status;
    qcb_host_info_t     host;
} qcb_status_ex_packet_t;

/**
 * Sealed packet header (paired hosts, both directions). 36 bytes, followed by
 * the encrypted inner packet and a 16-byte Poly1305 tag. The whole header is
 * the AEAD's additional data. A 16-byte sender session and 64-bit counter
 * identify a packet key/nonce; the key schedule is in qcb_crypto.h.
 */
typedef struct {
    uint8_t  packet_type;       /* QCB_PACKET_SEALED (0xE0) */
    uint8_t  seal_version;      /* QCB_SEAL_VERSION */
    uint8_t  direction;         /* QCB_SEAL_FROM_SENDER / QCB_SEAL_FROM_HOST */
    uint8_t  reserved;
    uint8_t  key_id[8];         /* which enrolled device: offset 4 */
    uint8_t  session[QCB_SEAL_SESSION_SIZE]; /* writer session: offset 12 */
    uint64_t counter;           /* per session and direction, from 1: offset 28 */
} qcb_sealed_header_t;

#pragma pack(pop)

/* Compile-time layout checks. The offsets are what the Swift codec's golden-byte
 * tests pin, so a drift here fails the build instead of a headset session. */
#ifdef __cplusplus
#define QCB_STATIC_ASSERT(cond, msg) static_assert(cond, msg)
#else
#define QCB_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)
#endif

QCB_STATIC_ASSERT(sizeof(qcb_controller_state_t) == 100,
    "Controller state packet must be exactly 100 bytes");
QCB_STATIC_ASSERT(sizeof(qcb_haptic_packet_t) == 14,
    "Haptic packet must be exactly 14 bytes");
QCB_STATIC_ASSERT(sizeof(qcb_discovery_packet_t) == 8,
    "Discovery packet must be exactly 8 bytes");
QCB_STATIC_ASSERT(sizeof(qcb_status_packet_t) == 16,
    "Status packet must be exactly 16 bytes");
QCB_STATIC_ASSERT(offsetof(qcb_controller_state_t, left_rot) == 16, "left_rot offset");
QCB_STATIC_ASSERT(offsetof(qcb_controller_state_t, right_pos) == 32, "right_pos offset");
QCB_STATIC_ASSERT(offsetof(qcb_controller_state_t, left_trigger) == 60, "analog offset");
QCB_STATIC_ASSERT(offsetof(qcb_controller_state_t, buttons) == 92, "buttons offset");
QCB_STATIC_ASSERT(offsetof(qcb_controller_state_t, battery_left) == 96, "battery offset");
QCB_STATIC_ASSERT(offsetof(qcb_controller_state_t, protocol_version) == 98, "version offset");
QCB_STATIC_ASSERT(offsetof(qcb_controller_state_t, sender) == 99, "sender offset");
QCB_STATIC_ASSERT(offsetof(qcb_haptic_packet_t, duration) == 2, "haptic duration offset");
QCB_STATIC_ASSERT(offsetof(qcb_status_packet_t, packets_received) == 8, "status count offset");
QCB_STATIC_ASSERT(sizeof(qcb_host_info_t) == 48, "Host info must be exactly 48 bytes");
QCB_STATIC_ASSERT(sizeof(qcb_status_ex_packet_t) == 64,
    "Probe reply with host info must be exactly 64 bytes");
QCB_STATIC_ASSERT(sizeof(qcb_session_challenge_t) == 49, "Session challenge size");
QCB_STATIC_ASSERT(sizeof(qcb_session_response_t) == 33, "Session response size");
QCB_STATIC_ASSERT(offsetof(qcb_status_ex_packet_t, host) == 16, "host info offset");
QCB_STATIC_ASSERT(offsetof(qcb_status_ex_packet_t, host.name) == 20, "host name offset");
QCB_STATIC_ASSERT(sizeof(qcb_sealed_header_t) == QCB_SEAL_HEADER_SIZE, "Sealed header size");
QCB_STATIC_ASSERT(offsetof(qcb_sealed_header_t, session) == 12, "sealed session offset");
QCB_STATIC_ASSERT(offsetof(qcb_sealed_header_t, counter) == 28, "sealed counter offset");

/* The negotiated version to speak to a peer that announced `peer` (0 = a v1
 * controller packet). */
static inline uint8_t qcb_negotiated_version(uint8_t peer) {
    if (peer < QCB_PROTOCOL_VERSION_MIN) return QCB_PROTOCOL_VERSION_MIN;
    return peer < QCB_PROTOCOL_VERSION ? peer : QCB_PROTOCOL_VERSION;
}

/* Fill a host-info trailer: copies at most QCB_HOST_NAME_MAX bytes of the
 * UTF-8 `name`, backing off to a character boundary, zero-padding the rest. */
static inline void qcb_fill_host_info(qcb_host_info_t* info, uint8_t kind,
                                      uint8_t flags, const char* name) {
    size_t n = 0;
    size_t i;
    info->host_kind = kind;
    info->host_flags = flags;
    info->reserved = 0;
    if (name != NULL) {
        while (name[n] != '\0' && n < QCB_HOST_NAME_MAX) n++;
        /* Cut inside a multi-byte sequence: drop its lead and continuations. */
        if (name[n] != '\0') {
            while (n > 0 && (((unsigned char)name[n]) & 0xC0) == 0x80) n--;
        }
    }
    for (i = 0; i < QCB_HOST_NAME_MAX; i++) info->name[i] = i < n ? name[i] : 0;
    info->name_length = (uint8_t)n;
}

#ifdef __cplusplus
}
#endif

#endif /* QUEST_BRIDGE_PROTOCOL_H */
