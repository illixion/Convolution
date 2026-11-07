/* Convolution on Quest - analysis tracks; see analysis_track.h. */

#include "analysis_track.h"

#include <zlib.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace vgat {

const char* error_name(Error error) {
    switch (error) {
    case Error::None: return "none";
    case Error::NotATrack: return "notATrack";
    case Error::UnsupportedVersion: return "unsupportedVersion";
    case Error::Truncated: return "truncated";
    case Error::UnknownValue: return "unknownValue";
    case Error::PayloadSize: return "payloadSize";
    case Error::TooLarge: return "tooLarge";
    case Error::Inflate: return "inflate";
    }
    return "unknown";
}

namespace {

template <typename T> T load(const uint8_t* p) {
    T value = 0;
    for (size_t i = 0; i < sizeof(T); i++) value |= T(uint64_t(p[i]) << (8 * i));
    return value;
}

float load_float(const uint8_t* p) {
    uint32_t bits = load<uint32_t>(p);
    float value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

int key(Kind kind, Eye eye) { return int(kind) * 16 + int(eye); }

/* Ignores the 64-bit overflow cases VergenceCore's 128-bit compare guards
   against: timescales here are 90 kHz or 24000, values well under 2^40. */
bool before(const Time& a, const Time& b) {
    return a.value * int64_t(b.timescale) < b.value * int64_t(a.timescale);
}

}  // namespace

uint16_t half_bits(float value) {
    uint32_t f;
    std::memcpy(&f, &value, sizeof(f));
    uint16_t sign = uint16_t((f >> 16) & 0x8000);
    int exponent = int((f >> 23) & 0xFF) - 127 + 15;
    uint32_t mantissa = f & 0x7FFFFF;
    if ((f & 0x7FFFFFFF) > 0x7F800000) return sign | 0x7E00;  // NaN
    if (exponent >= 0x1F) return sign | 0x7C00;                // overflow -> infinity
    if (exponent <= 0) {
        if (exponent < -10) return sign;  // underflow -> zero
        mantissa |= 0x800000;
        uint32_t shift = uint32_t(14 - exponent);
        uint16_t half = uint16_t(mantissa >> shift);
        if ((mantissa >> (shift - 1)) & 1) half += 1;  // round half up
        return sign | half;
    }
    uint16_t half = uint16_t(sign | (exponent << 10) | (mantissa >> 13));
    if (mantissa & 0x1000) half = uint16_t(half + 1);  // may carry into the exponent
    return half;
}

float half_value(uint16_t bits) {
    uint32_t sign = uint32_t(bits & 0x8000) << 16;
    int exponent = (bits >> 10) & 0x1F;
    uint32_t mantissa = bits & 0x3FF;
    float out;
    if (exponent == 0) {
        float magnitude = float(mantissa) / 1024.0f * std::ldexp(1.0f, -14);
        return sign ? -magnitude : magnitude;
    }
    uint32_t f = exponent == 0x1F ? (sign | 0x7F800000 | (mantissa << 13))
                                  : (sign | uint32_t(exponent - 15 + 127) << 23 | (mantissa << 13));
    std::memcpy(&out, &f, sizeof(out));
    return out;
}

Error inflate_raw(const uint8_t* data, size_t size, std::vector<uint8_t>& out, size_t expected) {
    out.assign(expected, 0);
    z_stream stream{};
    if (inflateInit2(&stream, -15) != Z_OK) return Error::Inflate;
    stream.next_in = const_cast<Bytef*>(data);
    stream.avail_in = uInt(size);
    stream.next_out = out.data();
    stream.avail_out = uInt(expected);
    int result = inflate(&stream, Z_FINISH);
    size_t written = expected - stream.avail_out;
    inflateEnd(&stream);
    if (result != Z_STREAM_END) return result == Z_BUF_ERROR && written == expected ? Error::PayloadSize : Error::Inflate;
    return written == expected ? Error::None : Error::PayloadSize;
}

std::unique_ptr<Track> Track::parse(std::vector<uint8_t> data, Error* error) {
    auto fail = [error](Error e) -> std::unique_ptr<Track> {
        if (error) *error = e;
        return nullptr;
    };
    if (data.size() < 9) return fail(Error::Truncated);
    if (std::memcmp(data.data(), "VGAT", 4) != 0) return fail(Error::NotATrack);
    if (data[4] != kVersion) return fail(Error::UnsupportedVersion);
    size_t json_length = load<uint32_t>(&data[5]);
    if (json_length >= kMaxHeaderBytes) return fail(Error::TooLarge);
    if (data.size() < 9 + json_length) return fail(Error::Truncated);

    auto track = std::unique_ptr<Track>(new Track());
    track->header_json_.assign(reinterpret_cast<const char*>(&data[9]), json_length);
    size_t position = 9 + json_length;
    while (position < data.size()) {
        if (data.size() - position < 4) return fail(Error::Truncated);
        size_t length = load<uint32_t>(&data[position]);
        if (length > kMaxRecordBytes || data.size() - position - 4 < length) return fail(Error::Truncated);
        if (length < kRecordHeaderBytes) return fail(Error::Truncated);
        const uint8_t* body = &data[position + 4];
        if (body[0] < 1 || body[0] > 4 || body[1] > 2) return fail(Error::UnknownValue);
        uint8_t encoding = body[2] & 0x7F;
        if (encoding < 1 || encoding > 3) return fail(Error::UnknownValue);
        Record record;
        record.kind = Kind(body[0]);
        record.eye = Eye(body[1]);
        record.encoding = Encoding(encoding);
        record.deflated = (body[2] & 0x80) != 0;
        record.channels = body[3];
        record.width = load<uint16_t>(body + 4);
        record.height = load<uint16_t>(body + 6);
        record.time.value = int64_t(load<uint64_t>(body + 8));
        record.end.value = int64_t(load<uint64_t>(body + 16));
        int32_t timescale = int32_t(load<uint32_t>(body + 24));
        if (timescale <= 0) return fail(Error::UnknownValue);
        record.time.timescale = record.end.timescale = timescale;
        record.scale = load_float(body + 28);
        record.offset = load_float(body + 32);
        record.payload_offset = position + 4 + kRecordHeaderBytes;
        record.payload_size = length - kRecordHeaderBytes;
        bool fits = record.deflated ? record.payload_size > 0 : record.payload_size == record.raw_byte_count();
        if (!fits) return fail(Error::PayloadSize);
        track->records_.push_back(record);
        position += 4 + length;
    }
    for (size_t i = 0; i < track->records_.size(); i++) {
        track->by_key_[key(track->records_[i].kind, track->records_[i].eye)].push_back(i);
    }
    for (auto& entry : track->by_key_) {
        auto& records = track->records_;
        std::stable_sort(entry.second.begin(), entry.second.end(),
                         [&records](size_t a, size_t b) { return before(records[a].time, records[b].time); });
    }
    track->data_ = std::move(data);
    if (error) *error = Error::None;
    return track;
}

const Record* Track::nearest(Kind kind, Eye eye, double seconds, double tolerance) const {
    auto found = by_key_.find(key(kind, eye));
    if (found == by_key_.end()) return nullptr;
    const auto& indices = found->second;
    // How many start at or before `seconds`.
    size_t low = 0, high = indices.size();
    while (low < high) {
        size_t mid = (low + high) / 2;
        if (seconds < records_[indices[mid]].time.seconds()) high = mid; else low = mid + 1;
    }
    const Record* best = nullptr;
    double best_distance = std::numeric_limits<double>::infinity();
    for (size_t i : {low, low + 1}) {
        if (i == 0 || i > indices.size()) continue;
        const Record& record = records_[indices[i - 1]];
        double distance = std::fabs(record.time.seconds() - seconds);
        if (distance <= tolerance && distance < best_distance) {
            best = &record;
            best_distance = distance;
        }
    }
    return best;
}

Error Track::values(const Record& record, std::vector<float>& out) const {
    const uint8_t* payload = data_.data() + record.payload_offset;
    std::vector<uint8_t> plain;
    const size_t raw = record.raw_byte_count();
    if (record.deflated) {
        Error error = inflate_raw(payload, record.payload_size, plain, raw);
        if (error != Error::None) return error;
        // Undo the row deltas: running sums per row, wrapping in the raw type.
        const size_t rows = size_t(record.channels) * size_t(record.height), width = size_t(record.width);
        if (record.bytes_per_sample() == 2) {
            for (size_t row = 0; row < rows; row++) {
                uint16_t previous = 0;
                for (size_t x = 0; x < width; x++) {
                    uint8_t* p = &plain[2 * (row * width + x)];
                    previous = uint16_t(previous + load<uint16_t>(p));
                    p[0] = uint8_t(previous);
                    p[1] = uint8_t(previous >> 8);
                }
            }
        } else {
            for (size_t row = 0; row < rows; row++) {
                uint8_t previous = 0;
                for (size_t x = 0; x < width; x++) {
                    previous = uint8_t(previous + plain[row * width + x]);
                    plain[row * width + x] = previous;
                }
            }
        }
        payload = plain.data();
    } else if (record.payload_size != raw) {
        return Error::PayloadSize;
    }
    const size_t count = record.sample_count();
    out.resize(count);
    switch (record.encoding) {
    case Encoding::Float16:
        for (size_t i = 0; i < count; i++) out[i] = half_value(load<uint16_t>(payload + 2 * i)) * record.scale + record.offset;
        break;
    case Encoding::Int16:
        for (size_t i = 0; i < count; i++) {
            out[i] = float(int16_t(load<uint16_t>(payload + 2 * i))) * record.scale + record.offset;
        }
        break;
    case Encoding::UInt8:
        for (size_t i = 0; i < count; i++) out[i] = float(payload[i]) * record.scale + record.offset;
        break;
    }
    return Error::None;
}

int ChunkStore::chunk_at(double seconds) const {
    return std::max(0, int(std::floor(seconds / chunk_seconds_)));
}

Error ChunkStore::put(int index, std::vector<uint8_t> data, bool complete) {
    Error error = Error::None;
    std::shared_ptr<const Track> track = Track::parse(std::move(data), &error);
    if (!track) return error;
    std::lock_guard<std::mutex> guard(lock_);
    chunks_[index] = std::move(track);
    complete_[index] = complete;
    return Error::None;
}

void ChunkStore::retain(int lo, int hi) {
    std::lock_guard<std::mutex> guard(lock_);
    for (auto it = chunks_.begin(); it != chunks_.end();) {
        if (it->first < lo || it->first > hi) {
            complete_.erase(it->first);
            it = chunks_.erase(it);
        } else {
            ++it;
        }
    }
}

bool ChunkStore::holds_whole(int index) const {
    std::lock_guard<std::mutex> guard(lock_);
    auto it = complete_.find(index);
    return it != complete_.end() && it->second;
}

bool ChunkStore::holds(int index) const {
    std::lock_guard<std::mutex> guard(lock_);
    return chunks_.count(index) != 0;
}

ChunkStore::Found ChunkStore::nearest_locked(Kind kind, Eye eye, double seconds, double tolerance) const {
    // A record near a chunk's edge may be in the next or previous one.
    Found best;
    double best_distance = std::numeric_limits<double>::infinity();
    int c = chunk_at(seconds);
    for (int n = c - 1; n <= c + 1; n++) {
        auto it = chunks_.find(n);
        if (it == chunks_.end()) continue;
        const Record* record = it->second->nearest(kind, eye, seconds, tolerance);
        if (!record) continue;
        double distance = std::fabs(record->time.seconds() - seconds);
        if (distance < best_distance) {
            best = {it->second, record};
            best_distance = distance;
        }
    }
    return best;
}

bool ChunkStore::disparity_locked(double seconds, double tolerance, std::vector<uint16_t>& out, int& width,
                                  int& height) {
    Found found = nearest_locked(Kind::Disparity, Eye::Right, seconds, tolerance);
    if (!found.record) return false;
    const Record& record = *found.record;
    if (record.time.value == last_disparity_time_.value && record.time.timescale == last_disparity_time_.timescale &&
        !last_disparity_.empty()) {
        out = last_disparity_;
        width = last_disparity_width_;
        height = last_disparity_height_;
        return true;
    }
    if (record.channels != 1 || found.track->values(record, scratch_) != Error::None) return false;
    out.resize(scratch_.size());
    for (size_t i = 0; i < scratch_.size(); i++) out[i] = half_bits(scratch_[i]);
    width = record.width;
    height = record.height;
    last_disparity_time_ = record.time;
    last_disparity_ = out;
    last_disparity_width_ = width;
    last_disparity_height_ = height;
    return true;
}

bool ChunkStore::shared_fields(double start, double end, SharedFields& out) {
    if (!(end > start)) return false;
    const double tolerance = (end - start) / 4;
    std::lock_guard<std::mutex> guard(lock_);
    Found pair = nearest_locked(Kind::FlowPair, Eye::Mono, start, tolerance);
    if (!pair.record || std::fabs(pair.record->end.seconds() - end) > tolerance || pair.record->channels != 5) return false;
    if (pair.track->values(*pair.record, scratch_) != Error::None) return false;
    const int fw = pair.record->width, fh = pair.record->height;
    const size_t n = size_t(fw) * size_t(fh);
    std::vector<uint16_t> flow(4 * n), mask(n);
    for (size_t i = 0; i < n; i++) {
        for (size_t c = 0; c < 4; c++) flow[4 * i + c] = half_bits(scratch_[c * n + i]);
        mask[i] = half_bits(scratch_[4 * n + i]);
    }
    int w0 = 0, h0 = 0, w1 = 0, h1 = 0;
    std::vector<uint16_t> d0, d1;
    if (!disparity_locked(start, tolerance, d0, w0, h0)) return false;
    if (!disparity_locked(end, tolerance, d1, w1, h1)) return false;
    if (w0 != w1 || h0 != h1) return false;
    out.flow_width = fw;
    out.flow_height = fh;
    out.flow_rgba = std::move(flow);
    out.mask = std::move(mask);
    out.disparity_width = w0;
    out.disparity_height = h0;
    out.disparity0 = std::move(d0);
    out.disparity1 = std::move(d1);
    return true;
}

double ChunkStore::nearest_pair_offset(double seconds) const {
    std::lock_guard<std::mutex> guard(lock_);
    Found found = nearest_locked(Kind::FlowPair, Eye::Mono, seconds, 5);
    return found.record ? found.record->time.seconds() - seconds : std::nan("");
}

}  // namespace vgat
