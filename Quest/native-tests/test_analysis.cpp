/* Desktop tests for the Quest's native analysis code (run.sh builds them):
   the VGAT reader against tracks VergenceCore (Swift) and vergence-worker
   (Rust) wrote, the chunk store's shared-field lookup, and the vendored
   pairing maths and HTTP token against vergence-companion's values.

   test_analysis --sums <track.vgat> prints a real track's first pair and
   disparity sums in the format MakeFixtures --sums prints, for comparing. */

#include "analysis_track.h"
#include "qcb_crypto.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <sstream>
#include <algorithm>
#include <string>
#include <vector>

namespace {

int failures = 0;

void check(bool ok, const std::string& what) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
    if (!ok) failures++;
}

std::vector<uint8_t> read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

std::string hex(const uint8_t* data, size_t size) {
    static const char digits[] = "0123456789abcdef";
    std::string out;
    for (size_t i = 0; i < size; i++) {
        out += digits[data[i] >> 4];
        out += digits[data[i] & 15];
    }
    return out;
}

size_t unbase64(const char* text, uint8_t* out) {
    static const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    uint32_t buffer = 0;
    int bits = 0;
    size_t size = 0;
    for (const char* p = text; *p && *p != '='; p++) {
        buffer = (buffer << 6) | uint32_t(alphabet.find(*p));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[size++] = uint8_t(buffer >> bits);
        }
    }
    return size;
}

/* What both generators write (fixtures/swift and fixtures/rust). */
float flow(int c, int x, int y, int pair) {
    return c < 4 ? float(c + 1) * 0.75f + float(x) * 0.5f - float(y) * 0.25f + float(pair) : float(x + y) / 12.0f;
}
float disparity(int x, int y, int frame) { return -2 + float(x) * 0.5f + float(y) * 0.25f + float(frame) * 0.1f; }

constexpr int kFW = 8, kFH = 5, kDW = 6, kDH = 4;
constexpr double kFrame = 1001.0 / 24000.0;

void test_pairing() {
    uint8_t quest_secret[32], host_secret[32], quest_nonce[32], host_nonce[32];
    std::memset(quest_secret, 0x11, 32);
    std::memset(host_secret, 0x22, 32);
    std::memset(quest_nonce, 0x33, 32);
    std::memset(host_nonce, 0x44, 32);
    uint8_t host_public[32];
    qcb_pair_public_key(host_secret, host_public);
    char code[7];
    uint8_t key[32];
    check(qcb_pair_agree_labelled(quest_secret, quest_nonce, host_public, host_nonce, "Vergence", code, key) == 0 &&
              std::strcmp(code, "741941") == 0,
          "Vergence pairing code");
    uint8_t expected_key[32];
    unbase64("2nT0ycFyWNPCpIulxi3TmpRtkK5Pn5GTzJsduo+Ov0Y=", expected_key);
    check(std::memcmp(key, expected_key, 32) == 0, "Vergence pairing key matches vergence-companion");

    // vergence-companion sealed this grant under that key with nonce 0x55 * 12.
    uint8_t sealed[256], plain[256];
    size_t sealed_size = unbase64(
        "VVVVVVVVVVVVVVVVRAoW5eoZe3mj7p3CRXB0mxgJ1YTGHLtOzcoGdOhDAtutMz/u4WrbjsKVSK34JqXa6kmhxGFYsMmy+lAnK+5D95LiVMo2"
        "zuNze6gxEditENOhWgi2pf3rDDye6f9GLjAEEvo5bZFEbL1kKKk/NwiuoaupQPizlrY=",
        sealed);
    long opened = qcb_chachapoly_open(key, sealed, sealed_size, plain);
    const std::string grant =
        R"({"token":"pairing-token","macID":"HOST-1","macName":"Desk","addresses":["192.0.2.7"],"grants":["play"]})";
    check(opened == long(grant.size()) && std::memcmp(plain, grant.data(), grant.size()) == 0,
          "opens the coordinator's sealed grant");

    // desktop/src/pairing.rs http_token for token "pairing-token", device "HS-1".
    const char* salt = "Vergence-HTTP-Token-v1";
    uint8_t token[32];
    qcb_hkdf_sha256(reinterpret_cast<const uint8_t*>("pairing-token"), 13, reinterpret_cast<const uint8_t*>(salt),
                    std::strlen(salt), reinterpret_cast<const uint8_t*>("HS-1"), 4, token, 32);
    check(hex(token, 32) == "727ebcccd3a89bc400710d63faf0f26c0c41ffe8529a4df082890a7da53da575",
          "HTTP token matches the desktop app's derivation");
}

void test_track(const std::string& path, const std::string& name, size_t record_count) {
    vgat::Error error;
    auto track = vgat::Track::parse(read_file(path), &error);
    check(track != nullptr, name + ": parses (" + vgat::error_name(error) + ")");
    if (!track) return;
    check(track->records().size() == record_count, name + ": " + std::to_string(record_count) + " records");
    check(track->header_json().find("\"mediaID\":\"fixture\"") != std::string::npos, name + ": header JSON");

    double worst = 0;
    std::vector<float> values;
    for (int pair = 0; pair < 3; pair++) {
        const vgat::Record* record = track->nearest(vgat::Kind::FlowPair, vgat::Eye::Mono, pair * kFrame, 0.001);
        if (!record || track->values(*record, values) != vgat::Error::None || values.size() != 5u * kFW * kFH) {
            check(false, name + ": flow pair " + std::to_string(pair));
            continue;
        }
        check(std::fabs(record->end.seconds() - (pair + 1) * kFrame) < 1e-9, name + ": pair end time");
        for (int c = 0; c < 5; c++)
            for (int y = 0; y < kFH; y++)
                for (int x = 0; x < kFW; x++)
                    worst = std::fmax(worst, std::fabs(values[(c * kFH + y) * kFW + x] - flow(c, x, y, pair)));
    }
    for (int frame = 0; frame < 4; frame++) {
        const vgat::Record* record = track->nearest(vgat::Kind::Disparity, vgat::Eye::Right, frame * kFrame + 0.003, 0.01);
        if (!record || track->values(*record, values) != vgat::Error::None || values.size() != size_t(kDW * kDH)) {
            check(false, name + ": disparity " + std::to_string(frame));
            continue;
        }
        for (int y = 0; y < kDH; y++)
            for (int x = 0; x < kDW; x++) worst = std::fmax(worst, std::fabs(values[y * kDW + x] - disparity(x, y, frame)));
    }
    // int16 at 16 and 8 px full scale: half a step is under 3e-4.
    check(worst < 3e-4, name + ": int16 deflated values within half a step (worst " + std::to_string(worst) + ")");
    check(track->nearest(vgat::Kind::FlowPair, vgat::Eye::Mono, 0.5 * kFrame + 0.02, 0.0001) == nullptr,
          name + ": nothing outside the tolerance");
}

void test_other_encodings(const std::string& path) {
    auto track = vgat::Track::parse(read_file(path), nullptr);
    if (!track) return;
    std::vector<float> values;
    const vgat::Record* depth = track->nearest(vgat::Kind::Depth, vgat::Eye::Mono, 0, 0.001);
    bool ok = depth && !depth->deflated && depth->encoding == vgat::Encoding::Float16 &&
              track->values(*depth, values) == vgat::Error::None && values.size() == 12;
    for (int y = 0; ok && y < 3; y++)
        for (int x = 0; x < 4; x++) ok = ok && values[y * 4 + x] == float(x) * 0.25f + float(y) * 0.5f;
    check(ok, "VergenceCore: plain float16 depth");
    const vgat::Record* gain = track->nearest(vgat::Kind::GainMap, vgat::Eye::Mono, 0, 0.001);
    ok = gain && gain->deflated && gain->encoding == vgat::Encoding::UInt8 &&
         track->values(*gain, values) == vgat::Error::None && values.size() == 12;
    for (int i = 0; ok && i < 12; i++) ok = std::fabs(values[i] - float(i) / 3) <= 4.0f / 255 / 2 + 1e-6f;
    check(ok, "VergenceCore: deflated uint8 gain map");
}

void test_store(const std::string& path) {
    // 50 ms chunks: the fixture's frames at 0, 41.7, 83.4 and 125.1 ms fall in
    // chunks 0, 0, 1 and 2, but the track is all put as chunk 0; a lookup still
    // searches the chunks either side of the one its time is in.
    vgat::ChunkStore store(0.05);
    check(store.put(0, read_file(path), false) == vgat::Error::None, "store: takes a partial chunk");
    check(store.holds(0) && !store.holds_whole(0), "store: holds it as partial");
    vgat::SharedFields fields;
    check(store.shared_fields(kFrame, 2 * kFrame, fields), "store: fields for the second pair, across a chunk edge");
    bool ok = fields.flow_width == kFW && fields.flow_height == kFH && fields.disparity_width == kDW &&
              fields.disparity_height == kDH && fields.flow_rgba.size() == 4u * kFW * kFH &&
              fields.mask.size() == size_t(kFW * kFH) && fields.disparity0.size() == size_t(kDW * kDH);
    check(ok, "store: field sizes");
    if (ok) {
        double worst = 0;
        for (int y = 0; y < kFH; y++)
            for (int x = 0; x < kFW; x++) {
                int i = y * kFW + x;
                for (int c = 0; c < 4; c++)
                    worst = std::fmax(worst, std::fabs(vgat::half_value(fields.flow_rgba[4 * i + c]) - flow(c, x, y, 1)));
                worst = std::fmax(worst, std::fabs(vgat::half_value(fields.mask[i]) - flow(4, x, y, 1)));
            }
        for (int y = 0; y < kDH; y++)
            for (int x = 0; x < kDW; x++) {
                worst = std::fmax(worst, std::fabs(vgat::half_value(fields.disparity0[y * kDW + x]) - disparity(x, y, 1)));
                worst = std::fmax(worst, std::fabs(vgat::half_value(fields.disparity1[y * kDW + x]) - disparity(x, y, 2)));
            }
        // Half floats: 2^-10 relative on values up to 9.
        check(worst < 0.01, "store: interleaved flow, mask and both disparities (worst " + std::to_string(worst) + ")");
    }
    check(!store.shared_fields(0, 2 * kFrame, fields), "store: no fields for frames that aren't a pair");
    check(std::fabs(store.nearest_pair_offset(kFrame + 0.01) + 0.01) < 1e-9, "store: a miss reports the nearest pair");
    store.retain(5, 10);
    check(!store.holds(0) && !store.shared_fields(kFrame, 2 * kFrame, fields), "store: retain lets old chunks go");
    check(store.put(3, {'V', 'G', 'A', 'X', 1, 0, 0, 0, 0}, true) == vgat::Error::NotATrack, "store: refuses a non-track");
}

void test_errors(const std::string& path) {
    std::vector<uint8_t> data = read_file(path);
    vgat::Error error;
    std::vector<uint8_t> cut(data.begin(), data.end() - 3);
    check(!vgat::Track::parse(cut, &error) && error == vgat::Error::Truncated, "a truncated track is refused");
    std::vector<uint8_t> version = data;
    version[4] = 2;
    check(!vgat::Track::parse(version, &error) && error == vgat::Error::UnsupportedVersion, "a newer version is refused");
    // Corrupt the last flow pair's deflated payload: the record still indexes, its values don't decode.
    auto track = vgat::Track::parse(data, nullptr);
    const vgat::Record* last = track ? track->nearest(vgat::Kind::FlowPair, vgat::Eye::Mono, 2 * kFrame, 0.001) : nullptr;
    if (last) {
        std::vector<uint8_t> bad = data;
        for (size_t i = 0; i < last->payload_size; i++) bad[last->payload_offset + i] ^= 0x5A;
        auto broken = vgat::Track::parse(bad, nullptr);
        std::vector<float> values;
        const vgat::Record* record = broken ? broken->nearest(vgat::Kind::FlowPair, vgat::Eye::Mono, 2 * kFrame, 0.001) : nullptr;
        check(record && broken->values(*record, values) != vgat::Error::None, "a corrupt payload fails to decode");
    }
    float halves[] = {0.0f, -0.0f, 1.0f, -2.5f, 65504.0f, 6.1035156e-05f, 5.9604645e-08f, 0.333251953125f};
    bool ok = true;
    for (float h : halves) ok = ok && vgat::half_value(vgat::half_bits(h)) == h;
    check(ok && vgat::half_bits(1e6f) == 0x7C00, "half floats round trip");
}

/* worker-expected.txt: "key v1 v2 ..." lines VergenceCore printed (fixtures/swift --expect). */
std::map<std::string, std::vector<double>> read_expected(const std::string& path) {
    std::map<std::string, std::vector<double>> out;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        std::istringstream words(line);
        std::string key;
        words >> key;
        double value;
        while (words >> value) out[key].push_back(value);
    }
    return out;
}

bool near(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

/* The GL pass samples the grid as a 16x9x8 3D texture, linear, clamp to edge,
   normalised coordinates; this is that sampling on the CPU (VergenceCore's
   GainGrid.lookup), to check the layout the texture is uploaded in. */
float gain_lookup(const std::vector<uint16_t>& grid, float u, float v, float luma) {
    auto axis = [](float t, int n, int& i0, int& i1, float& f) {
        float x = std::fmin(std::fmax(t * float(n) - 0.5f, 0.0f), float(n - 1));
        i0 = int(x);
        i1 = std::min(i0 + 1, n - 1);
        f = x - float(i0);
    };
    int x0, x1, y0, y1, l0, l1;
    float fx, fy, fl;
    axis(u, vgat::kGainGridWidth, x0, x1, fx);
    axis(v, vgat::kGainGridHeight, y0, y1, fy);
    axis(luma, vgat::kGainGridBins, l0, l1, fl);
    auto g = [&](int x, int y, int l) {
        return vgat::half_value(grid[size_t((l * vgat::kGainGridHeight + y) * vgat::kGainGridWidth + x)]);
    };
    auto plane = [&](int l) {
        float top = g(x0, y0, l) + (g(x1, y0, l) - g(x0, y0, l)) * fx;
        float bottom = g(x0, y1, l) + (g(x1, y1, l) - g(x0, y1, l)) * fx;
        return top + (bottom - top) * fy;
    };
    float a = plane(l0), b = plane(l1);
    return a + (b - a) * fl;
}

/* GainGrid.cappedScale, as the gain pass computes it in GLSL. */
float capped_scale(float mean, float cap) { return cap <= 1 ? 0 : (mean <= cap ? 1 : std::log2(cap) / std::log2(mean)); }

void test_worker_tracks(const std::string& fixtures) {
    auto expected = read_expected(fixtures + "/worker-expected.txt");
    check(expected.size() >= 7, "worker-expected.txt read");
    std::vector<float> values;

    // smooth-motion-2d: flow pairs only, over the whole picture.
    {
        vgat::Error error;
        auto bytes = read_file(fixtures + "/worker-2d-flow.vgat");
        auto track = vgat::Track::parse(bytes, &error);
        check(track != nullptr, std::string("2D flow track parses (") + vgat::error_name(error) + ")");
        if (track) {
            size_t pairs = 0, disparities = 0;
            for (const auto& r : track->records()) {
                pairs += r.kind == vgat::Kind::FlowPair;
                disparities += r.kind == vgat::Kind::Disparity;
            }
            check(pairs == size_t(expected["flow2d.pairs"][0]) && disparities == 0, "2D flow: pairs and no disparity");
            auto& e = expected["flow2d.pair1"];
            const vgat::Record* r = track->nearest(vgat::Kind::FlowPair, vgat::Eye::Mono, e[0], 0.001);
            double sum = 0;
            if (r && track->values(*r, values) == vgat::Error::None) for (float v : values) sum += v;
            check(r && near(r->end.seconds(), e[1], 1e-6) && r->width == int(e[2]) && r->height == int(e[3]) &&
                      r->channels == int(e[4]) && near(sum, e[5], 0.01) && near(values.front(), e[6], 1e-6) &&
                      near(values.back(), e[7], 1e-6),
                  "2D flow: pair 1 decodes as VergenceCore reads it (sum " + std::to_string(sum) + ")");

            vgat::ChunkStore store(10);
            store.put(0, bytes, true);
            vgat::SharedFields fields;
            check(!store.shared_fields(e[0], e[1], fields), "2D flow: a stereo lookup needs disparity");
            check(store.shared_fields(e[0], e[1], fields, false) && fields.flow_width == int(e[2]) &&
                      fields.flow_rgba.size() == size_t(4 * e[2] * e[3]) && fields.disparity_width == 0 &&
                      fields.disparity0.empty(),
                  "2D flow: the mono lookup gives flow and mask alone");
        }
    }

    // ai-3d-depth: one uint8 map per frame, bytes as they are.
    {
        auto bytes = read_file(fixtures + "/worker-depth.vgat");
        vgat::ChunkStore store(10);
        check(store.put(0, bytes, true) == vgat::Error::None, "depth track parses");
        auto track = vgat::Track::parse(bytes, nullptr);
        size_t maps = 0;
        if (track) for (const auto& r : track->records()) maps += r.kind == vgat::Kind::Depth && r.eye == vgat::Eye::Mono;
        check(maps == size_t(expected["depth.maps"][0]), "depth: a map per frame");
        auto& e = expected["depth.map2"];
        vgat::DepthMap map;
        bool ok = store.depth(e[0] + 0.004, 0.5 / 23.976, map);
        long total = 0;
        double value_sum = 0;
        for (uint8_t b : map.bytes) { total += b; value_sum += double(b) * map.scale + map.offset; }
        check(ok && map.width == int(e[1]) && map.height == int(e[2]) && near(map.scale, e[3], 1e-9) &&
                  near(map.offset, e[4], 1e-9) && total == long(e[5]) && near(value_sum, e[6], 0.05),
              "depth: map 2's bytes, scale and offset as VergenceCore reads them");
        check(!store.depth(e[0] + 0.5 * kFrame + 0.001, 0.5 * kFrame - 0.002, map), "depth: nothing between frames past the tolerance");
        check(!store.depth(5.0, 0.5 / 23.976, map), "depth: no map past the track");
    }

    // ai-hdr: the pinned 16x9x8 grid, looked up as the GL pass samples it.
    {
        auto bytes = read_file(fixtures + "/worker-gain.vgat");
        vgat::ChunkStore store(10);
        check(store.put(0, bytes, true) == vgat::Error::None, "gain track parses");
        auto& e = expected["gain.grid3"];
        std::vector<uint16_t> grid;
        bool ok = store.gain_grid(e[0], 0.5 / 23.976, grid) && grid.size() == size_t(vgat::kGainGridCount);
        double sum = 0;
        for (uint16_t h : grid) sum += vgat::half_value(h);
        check(ok && near(sum, e[1], 0.01), "gain: grid 3's cells (sum " + std::to_string(sum) + ")");
        const float points[4][3] = {{0.3f, 0.6f, 0.5f}, {0.95f, 0.05f, 0.97f}, {0.02f, 0.98f, 0.01f}, {0.5f, 0.5f, 0.25f}};
        double worst = 0;
        for (int i = 0; ok && i < 4; i++) worst = std::fmax(worst, std::fabs(gain_lookup(grid, points[i][0], points[i][1], points[i][2]) - e[2 + i]));
        check(ok && worst < 1e-5, "gain: trilinear lookups match GainGrid.lookup (worst " + std::to_string(worst) + ")");
        auto& c = expected["gain.capped"];
        check(near(capped_scale(4, 2.5f), c[0], 1e-6) && near(capped_scale(2, 2.5f), c[1], 1e-6) &&
                  near(capped_scale(3, 1), c[2], 1e-6),
              "gain: the cap's scale is GainGrid.cappedScale");
        vgat::DepthMap map;
        check(!store.depth(e[0], 0.02, map), "gain: no depth in a gain track");
    }
}

int sums(const std::string& path) {
    auto track = vgat::Track::parse(read_file(path), nullptr);
    if (!track) return 1;
    const vgat::Record* pair = nullptr;
    for (const auto& record : track->records())
        if (record.kind == vgat::Kind::FlowPair) { pair = &record; break; }
    if (!pair) return 1;
    std::vector<float> values;
    auto sum = [&](const vgat::Record* record) {
        double total = 0;
        if (record && track->values(*record, values) == vgat::Error::None)
            for (float v : values) total += v;
        return total;
    };
    double flow_sum = sum(pair);
    double d0 = sum(track->nearest(vgat::Kind::Disparity, vgat::Eye::Right, pair->time.seconds(), 0.01));
    double d1 = sum(track->nearest(vgat::Kind::Disparity, vgat::Eye::Right, pair->end.seconds(), 0.01));
    std::printf("records %zu pair %.6f-%.6f %dx%d flow %.4f disparity %.4f %.4f\n", track->records().size(),
                pair->time.seconds(), pair->end.seconds(), pair->width, pair->height, flow_sum, d0, d1);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc == 3 && std::string(argv[1]) == "--sums") return sums(argv[2]);
    if (argc != 2) {
        std::fprintf(stderr, "usage: test_analysis <fixtures dir> | --sums <track.vgat>\n");
        return 2;
    }
    const std::string fixtures = argv[1];
    test_pairing();
    test_track(fixtures + "/vergencecore-fields.vgat", "VergenceCore", 9);
    test_track(fixtures + "/worker-fields.vgat", "vergence-worker", 7);
    test_other_encodings(fixtures + "/vergencecore-fields.vgat");
    test_store(fixtures + "/worker-fields.vgat");
    test_store(fixtures + "/vergencecore-fields.vgat");
    test_errors(fixtures + "/worker-fields.vgat");
    test_worker_tracks(fixtures);
    std::printf(failures ? "\n%d failed\n" : "\nall passed\n", failures);
    return failures ? 1 : 0;
}
