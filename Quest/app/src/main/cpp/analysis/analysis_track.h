/*
 Convolution on Quest - analysis tracks (VGAT) from a Vergence coordinator

 The Quest reads the same tracks the Vision Pro does: Vergence's
 `AnalysisTrack.swift` (VergenceCore) defines the format, and the
 coordinator (`coordinator/src/track.rs`) and the workers write it.

   track   = "VGAT" u8(version) u32(header JSON length) header-JSON  record*
   record  = u32(length of what follows)  u8(kind) u8(eye) u8(encoding) u8(channels)
             u16(width) u16(height)  i64(time value) i64(end value) i32(timescale)
             f32(scale) f32(offset)  payload

 Little-endian throughout; a sample is raw * scale + offset, raw a half float,
 an int16 or a uint8, planar (channel by channel, rows top to bottom). The
 encoding byte's 0x80 bit marks a payload that is row-delta coded and then
 raw-DEFLATE compressed (zlib here, Apple's Compression or flate2 there).

 This is C++ rather than the Swift core because the fields go straight from
 here into GL textures every frame; the Swift core's JSON boundary is for
 low-rate commands, never per-frame data. `Quest/native-tests` checks it
 against tracks VergenceCore (Swift) and vergence-worker (Rust) wrote.

 A coordinator serves a title's track as 10 s chunks, each a small track of
 its own, partial while workers are still making it. `ChunkStore` holds the
 ones around the playhead and finds the shared Smooth Motion fields for a
 pair of real frames there, as VergenceCore's `AnalysisTrackFieldProvider`
 does: the left eye's flow pair (mono, five channels) and each frame's
 right-to-left disparity, matched by time within a quarter of the spacing.
 */

#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace vgat {

enum class Kind : uint8_t { FlowPair = 1, Disparity = 2, Depth = 3, GainMap = 4 };
enum class Eye : uint8_t { Mono = 0, Left = 1, Right = 2 };
enum class Encoding : uint8_t { Float16 = 1, Int16 = 2, UInt8 = 3 };

enum class Error {
    None = 0,
    NotATrack,
    UnsupportedVersion,
    Truncated,
    UnknownValue,
    PayloadSize,
    TooLarge,
    Inflate,
};

const char* error_name(Error error);

constexpr uint8_t kVersion = 1;
constexpr size_t kRecordHeaderBytes = 36;
/* A length past this is a corrupt stream (VergenceCore's maxRecordBytes). */
constexpr size_t kMaxRecordBytes = size_t(64) << 20;
constexpr size_t kMaxHeaderBytes = size_t(1) << 20;

struct Time {
    int64_t value = 0;
    int32_t timescale = 1;
    double seconds() const { return double(value) / double(timescale); }
};

struct Record {
    Kind kind = Kind::FlowPair;
    Eye eye = Eye::Mono;
    Encoding encoding = Encoding::Float16;
    bool deflated = false;
    int channels = 0;
    int width = 0;
    int height = 0;
    Time time;
    /* The second real frame for pair kinds; equal to `time` otherwise. */
    Time end;
    float scale = 1;
    float offset = 0;
    /* Where the payload sits in the track's bytes. */
    size_t payload_offset = 0;
    size_t payload_size = 0;

    size_t sample_count() const { return size_t(channels) * size_t(width) * size_t(height); }
    size_t bytes_per_sample() const { return encoding == Encoding::UInt8 ? 1 : 2; }
    size_t raw_byte_count() const { return sample_count() * bytes_per_sample(); }
};

/* IEEE 754 binary16, as VergenceCore's HalfFloat rounds it. */
uint16_t half_bits(float value);
float half_value(uint16_t bits);

/* A whole track (or one chunk of one) in memory, indexed without decoding a
   payload. */
class Track {
public:
    static std::unique_ptr<Track> parse(std::vector<uint8_t> data, Error* error);

    const std::string& header_json() const { return header_json_; }
    const std::vector<Record>& records() const { return records_; }

    /* The record of `kind` and `eye` whose time is nearest `seconds`, if it is
       within `tolerance` seconds of it. */
    const Record* nearest(Kind kind, Eye eye, double seconds, double tolerance) const;

    /* The record's samples as floats, planar: inflated, deltas undone and
       scaled. */
    Error values(const Record& record, std::vector<float>& out) const;

private:
    std::vector<uint8_t> data_;
    std::string header_json_;
    std::vector<Record> records_;
    /* Per (kind, eye), indices into records_ sorted by time. */
    std::map<int, std::vector<size_t>> by_key_;
};

/* Raw DEFLATE (RFC 1951, no zlib header) into exactly `size` bytes. */
Error inflate_raw(const uint8_t* data, size_t size, std::vector<uint8_t>& out, size_t expected);

/* What the shared-field pass reads, as half floats ready for GL textures:
   the flow pair interleaved RGBA (F0->1 x, y, F1->0 x, y), the blend mask
   (frame 0's weight at t = 1/2), and the two real frames' disparity. Sizes
   are the records' own; the pass scales them to the eye. */
struct SharedFields {
    int flow_width = 0;
    int flow_height = 0;
    std::vector<uint16_t> flow_rgba;
    std::vector<uint16_t> mask;
    int disparity_width = 0;
    int disparity_height = 0;
    std::vector<uint16_t> disparity0;
    std::vector<uint16_t> disparity1;
};

/* One title's chunks, held around the playhead. Thread safe: the fetcher puts
   chunks on its own thread while the renderer looks fields up on the GL one. */
class ChunkStore {
public:
    explicit ChunkStore(double chunk_seconds) : chunk_seconds_(chunk_seconds) {}

    double chunk_seconds() const { return chunk_seconds_; }
    int chunk_at(double seconds) const;

    /* Replaces chunk `index` (a partial one is fetched again as it fills). */
    Error put(int index, std::vector<uint8_t> data, bool complete);
    /* Keeps chunks lo...hi and lets the rest go. */
    void retain(int lo, int hi);
    /* Chunk `index` is here, whole. */
    bool holds_whole(int index) const;
    bool holds(int index) const;

    /* The fields for the real frames at `start` and `end` (seconds on the
       track's timeline), or false when the records aren't here. */
    bool shared_fields(double start, double end, SharedFields& out);

    /* For a miss's log line: how far the nearest flow pair is from `seconds`,
       in seconds, or NaN when none is within 5 s. */
    double nearest_pair_offset(double seconds) const;

private:
    struct Found {
        std::shared_ptr<const Track> track;
        const Record* record = nullptr;
    };
    Found nearest_locked(Kind kind, Eye eye, double seconds, double tolerance) const;
    bool disparity_locked(double seconds, double tolerance, std::vector<uint16_t>& out, int& width, int& height);

    const double chunk_seconds_;
    mutable std::mutex lock_;
    std::map<int, std::shared_ptr<const Track>> chunks_;
    std::map<int, bool> complete_;
    /* The last disparity decoded: one pair's second frame is the next pair's first. */
    Time last_disparity_time_{-1, 1};
    std::vector<uint16_t> last_disparity_;
    int last_disparity_width_ = 0;
    int last_disparity_height_ = 0;
    std::vector<float> scratch_;
};

}  // namespace vgat
