/*
 Dolby Vision profile 7 played as profile 8.1 (`DolbyVisionConversion.swift`).

 The profile 7 file is made in memory: hevc-hdr10.mkv's frames (three
 times over, 21 s and several segments), each with a
 dummy enhancement-layer unit (NAL type 63) and an RPU (type 62) appended,
 and a profile 7 dvcC mapping. The RPUs come from dovi-p7-rpus.bin
 (`make-dovi-rpus.c`, FFmpeg's own RPU writer): 48 FEL RPUs, then 48 MEL
 ones, used in turn. Without a converter the base layer plays as it does
 today; a deterministic fake converter checks the remux's side of it, and
 FFmpeg's (the FFmpegDecoders framework, when built) the RPUs themselves.
 */

import FFmpegDecoders
import Foundation
import Testing
@testable import MatroskaRemux

#if canImport(AVFoundation) && os(macOS)
import AVFoundation
#endif

@Suite("Dolby Vision profile 7 as 8.1", .serialized)
struct DolbyVisionTests {
    // MARK: - The fixture

    /// The RPU NAL units of dovi-p7-rpus.bin: FEL, then MEL.
    static func rpus() throws -> (full: [[UInt8]], minimal: [[UInt8]]) {
        let bytes = [UInt8](try Fixtures.data("dovi-p7-rpus.bin"))
        var units: [[UInt8]] = []
        var p = 0
        while p + 4 <= bytes.count {
            let length = Int(bytes[p]) << 24 | Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
            units.append(Array(bytes[p + 4 ..< p + 4 + length]))
            p += 4 + length
        }
        let half = units.count / 2
        return (Array(units[..<half]), Array(units[half...]))
    }

    /// A unit of the dummy enhancement layer: type 63 around a fake EL slice.
    static func enhancementUnit(_ frame: Int) -> [UInt8] {
        [0x7E, 0x01, 0x02, 0x01, 0xD0] + (0 ..< 40).map { UInt8(truncatingIfNeeded: frame * 7 + $0 * 13) | 1 }
    }

    static func lengthPrefixed(_ unit: [UInt8]) -> [UInt8] {
        [UInt8(unit.count >> 24 & 0xFF), UInt8(unit.count >> 16 & 0xFF), UInt8(unit.count >> 8 & 0xFF),
         UInt8(unit.count & 0xFF)] + unit
    }

    /// dvcC: version 1.0, profile 7, level 6, RPU + EL + BL, compatibility 6.
    static let profile7Record: [UInt8] = [1, 0, 0x0E, 0x37, 0x60] + [UInt8](repeating: 0, count: 19)

    struct Crafted {
        var data: Data
        /// Each video frame's base-layer units and its RPU, in file order.
        var baseLayers: [[UInt8]]
        var rpus: [[UInt8]]
    }

    static func profile7File(_ rpus: [[UInt8]]) async throws -> Crafted {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("hevc-hdr10.mkv"))
        writer.tracks[0].blockAdditionMappings = [.init(idValue: nil, idType: 0x6476_6343, extraData: profile7Record)]
        // Three times over (21 s), so there are segment boundaries to cross.
        let span = Int64((writer.duration ?? 7000).rounded(.up))
        let once = writer.frames
        for k in 1 ..< 3 {
            writer.frames += once.map { frame in
                var frame = frame
                frame.timestamp += Int64(k) * span
                return frame
            }
        }
        writer.duration = Double(3 * span)
        var bases: [[UInt8]] = [], used: [[UInt8]] = []
        var n = 0
        for i in writer.frames.indices where writer.frames[i].track == writer.tracks[0].number {
            let base = writer.frames[i].data
            let rpu = rpus[n % rpus.count]
            // The UHD Blu-ray order: base layer, its EL units, the RPU last.
            writer.frames[i].data = base + lengthPrefixed(enhancementUnit(n)) + lengthPrefixed(enhancementUnit(n + 1000))
                + lengthPrefixed(rpu)
            bases.append(base)
            used.append(rpu)
            n += 1
        }
        return Crafted(data: writer.write(), baseLayers: bases, rpus: used)
    }

    /// A deterministic stand-in for FFmpeg: the RPU with a marker byte after
    /// its prefix, so each output RPU names its input.
    static let fakeConversion = RemuxDolbyVisionConversion { rpu in
        guard rpu.count > 3, rpu[0] == 0x7C else { return nil }
        return .init(rpu: Array(rpu.prefix(3)) + [0xA8] + Array(rpu.dropFirst(3)), sourceEnhancementLayer: .minimal)
    }

    static func options(_ conversion: RemuxDolbyVisionConversion?) -> RemuxOptions {
        var options = RemuxOptions()
        options.dolbyVisionConversion = conversion
        return options
    }

    /// Every video sample the session writes, split into NAL units.
    static func videoSamples(_ session: RemuxSession) async throws -> [[[UInt8]]] {
        var samples: [[[UInt8]]] = []
        for segment in try await session.allSegments("video") {
            for run in try MP4Read.segment(segment).runs {
                for sample in run.samples {
                    samples.append(NALUnits.lengthPrefixed(sample.data, lengthSize: 4).map(Array.init))
                }
            }
        }
        return samples
    }

    static func type(_ unit: [UInt8]) -> UInt8 { (unit[0] >> 1) & 0x3F }

    // MARK: - Without a converter

    @Test func withoutAConverterTheBaseLayerPlays() async throws {
        let crafted = try await Self.profile7File(try Self.rpus().full)
        let session = try await RemuxSession.open(source: DataByteSource(crafted.data))
        let entry = try #require(try MP4Read.initSegment(await session.fetch("video/init.mp4")).first)
        #expect(entry.entryType == "hvc1")
        #expect(entry.entryChildren["dvcC"] == nil && entry.entryChildren["dvvC"] == nil)
        #expect(!session.masterPlaylist.contains("SUPPLEMENTAL-CODECS"))
        #expect(session.summary.video.codec == "HEVC")
        #expect(session.summary.videoRange == "PQ", "HDR10 from the base layer's Colour")
        #expect(session.summary.dolbyVisionProfile == 7)
        #expect(session.summary.dolbyVisionCompatibility == 6)
        #expect(session.summary.dolbyVisionPlayedProfile == nil)
        #expect(session.summary.dolbyVisionEnhancementLayer == nil)
        // Samples as stored, as before: an HEVC decoder skips types 62 and 63.
        let samples = try await Self.videoSamples(session)
        #expect(samples.count == crafted.baseLayers.count)
        #expect(samples.allSatisfy { units in units.contains { Self.type($0) == 63 } })
    }

    @Test func aConverterThatFailsOnTheFirstRPUKeepsTheBaseLayer() async throws {
        let crafted = try await Self.profile7File(try Self.rpus().full)
        let refusing = RemuxDolbyVisionConversion { _ in nil }
        let session = try await RemuxSession.open(source: DataByteSource(crafted.data), options: Self.options(refusing))
        #expect(session.summary.dolbyVisionPlayedProfile == nil)
        #expect(!session.masterPlaylist.contains("SUPPLEMENTAL-CODECS"))
    }

    // MARK: - With a converter (the fake)

    @Test func theConversionRewritesSamplesAndSampleEntry() async throws {
        let crafted = try await Self.profile7File(try Self.rpus().full)
        let session = try await RemuxSession.open(source: DataByteSource(crafted.data),
                                                  options: Self.options(Self.fakeConversion))
        let entry = try #require(try MP4Read.initSegment(await session.fetch("video/init.mp4")).first)
        #expect(entry.entryType == "hvc1")
        // dvvC: version 1.0, profile 8, level 6 (kept), RPU + BL, compatibility 1.
        #expect(entry.entryChildren["dvvC"] == [1, 0, 0x10, 0x35, 0x10] + [UInt8](repeating: 0, count: 19))
        #expect(entry.entryChildren["dvcC"] == nil)
        let original = try #require(try await MatroskaHeaderReader.read(DataByteSource(crafted.data)).tracks.first)
        #expect(entry.entryChildren["hvcC"] == original.codecPrivate)
        #expect(session.masterPlaylist.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
        #expect(session.masterPlaylist.contains("VIDEO-RANGE=PQ"))
        #expect(session.summary.video.codecs.hasPrefix("hvc1."))
        #expect(session.summary.video.codec == "HEVC (DV profile 7 MEL as 8.1)")
        #expect(session.summary.dolbyVisionProfile == 7, "the source's profile")
        #expect(session.summary.dolbyVisionCompatibility == 6)
        #expect(session.summary.dolbyVisionPlayedProfile == 8)
        #expect(session.summary.dolbyVisionEnhancementLayer == .minimal)

        // Every sample: the base layer as it was, then its converted RPU; no EL.
        let samples = try await Self.videoSamples(session)
        #expect(samples.count == crafted.baseLayers.count)
        for (i, units) in samples.enumerated() {
            #expect(!units.contains { Self.type($0) == 63 }, "frame \(i) kept an EL unit")
            let rpus = units.filter { Self.type($0) == 62 }
            let expected = try #require(Self.fakeConversion.convertToProfile81(crafted.rpus[i])).rpu
            #expect(rpus == [expected], "frame \(i)'s RPU")
            let base = units.filter { Self.type($0) != 62 }.flatMap(Self.lengthPrefixed)
            #expect(base == crafted.baseLayers[i], "frame \(i)'s base layer")
        }
        // The muxed rendition carries the same video.
        let muxed = try MP4Read.segment(try await session.fetch("muxed/0.m4s")).runs(track: 1)
        let video = try MP4Read.segment(try await session.fetch("video/0.m4s")).runs(track: 1)
        #expect(muxed.flatMap(\.samples).map(\.data) == video.flatMap(\.samples).map(\.data))
    }

    @Test func segmentsAreTheSameBytesEveryTime() async throws {
        let crafted = try await Self.profile7File(try Self.rpus().full)
        let first = try await RemuxSession.open(source: DataByteSource(crafted.data),
                                                options: Self.options(Self.fakeConversion))
        let second = try await RemuxSession.open(source: DataByteSource(crafted.data),
                                                 options: Self.options(Self.fakeConversion))
        #expect(first.segmentCount > 1)
        for k in (0 ..< first.segmentCount).reversed() {
            let a = try await first.fetch("video/\(k).m4s"), b = try await second.fetch("video/\(k).m4s")
            #expect(a == b, "segment \(k)")
            #expect(try await first.fetch("video/\(k).m4s") == a, "segment \(k) asked for again")
        }
    }

    @Test func profile7RecordArraysOfTheLayersAreDropped() async throws {
        let track = try #require(try await MatroskaHeaderReader.read(Fixtures.source("hevc-hdr10.mkv")).tracks.first)
        let hevc = try #require(HEVCConfiguration(record: track.codecPrivate))
        var record = Array(hevc.record.prefix(22))
        record.append(hevc.record[22] + 1)
        record += hevc.record.dropFirst(23)
        record += [0x3F, 0, 1, 0, 3, 0x7E, 0x01, 0x42] // an array of one type 63 unit
        let withLayer = try #require(HEVCConfiguration(record: record))
        #expect(withLayer.arrays[63]?.count == 1)
        let cleaned = withLayer.removingArrays(ofTypes: [62, 63])
        #expect(cleaned.record == hevc.record)
    }

    // MARK: - FFmpeg's converter

    @Test(.enabled(if: FFmpegDolbyVisionConversion.loaded))
    func ffmpegConvertsTheRPUs() async throws {
        let all = try Self.rpus()
        for (set, layer) in [(all.full, DolbyVisionEnhancementLayer.full), (all.minimal, .minimal)] {
            let crafted = try await Self.profile7File(set)
            let session = try await RemuxSession.open(source: DataByteSource(crafted.data),
                                                      options: Self.options(FFmpegDolbyVisionConversion.conversion))
            #expect(session.summary.dolbyVisionPlayedProfile == 8)
            #expect(session.summary.dolbyVisionEnhancementLayer == layer)
            #expect(session.summary.video.codec == "HEVC (DV profile 7 \(layer == .full ? "FEL" : "MEL") as 8.1)")
            let samples = try await Self.videoSamples(session)
            #expect(samples.count == crafted.baseLayers.count)
            for (i, units) in samples.enumerated() {
                #expect(!units.contains { Self.type($0) == 63 })
                let rpus = units.filter { Self.type($0) == 62 }
                try #require(rpus.count == 1, "frame \(i)")
                let source = try #require(FFmpegDolbyVision.parse(crafted.rpus[i]))
                let out = try #require(FFmpegDolbyVision.parse(rpus[0]), "frame \(i)'s RPU reads back")
                #expect(source.profile == 7 && Int(source.el_type) == (layer == .full ? 2 : 1))
                #expect(out.profile == 8)
                #expect(out.disable_residual_flag == 1 && out.el_spatial_resampling_filter_flag == 0)
                #expect(out.el_type == 0 && out.nlq_method_idc == -1)
                #expect(out.num_x_partitions == 1 && out.num_y_partitions == 1)
                #expect(out.bl_bit_depth == 10 && out.vdr_bit_depth == 12 && out.coef_log2_denom == 23)
                // The display metadata goes through as it was.
                #expect(out.has_l1 == 1 && out.l1_max_pq == source.l1_max_pq && out.l1_avg_pq == source.l1_avg_pq)
                #expect(out.num_l2 == 2 && out.l2.1.target_max_pq == 2851 && out.l2.1.trim_saturation_gain == 2200)
                #expect(out.has_l5 == 1 && out.l5_top_offset == 276)
                #expect(out.has_l6 == 1 && out.l6_max_cll == 1000 && out.l6_max_fall == 400)
                #expect(out.has_l11 == 1 && out.has_l254 == 1)
                #expect(out.source_min_pq == 62 && out.source_max_pq == 3079)
                // The 8.1 coefficients.
                #expect(out.ycc_to_rgb_matrix.2 == 13802.0 / 8192 && out.ycc_to_rgb_offset.0 == 0.0625)
                #expect(out.rgb_to_lms_matrix.0 == 7222.0 / 16384 && out.signal_color_space == 0)
                // A FEL's curves become identity, a MEL's stay.
                let one = Int64(1) << 23
                if layer == .full {
                    #expect(out.curves.0.num_pivots == 2 && out.curves.0.pivots.1 == 1023)
                    #expect(out.curves.0.poly_coef.0 == (0, one, 0) && out.curves.1.mapping_idc.0 == 0)
                } else {
                    #expect(withUnsafeBytes(of: out.curves) { Array($0) } == withUnsafeBytes(of: source.curves) { Array($0) })
                }
                #expect(FFmpegDolbyVision.convertToProfile81(crafted.rpus[i])?.rpu == rpus[0], "deterministic")
            }
        }
    }

    @Test(.enabled(if: FFmpegDolbyVisionConversion.loaded))
    func ffmpegKeepsAFullLayersMappingWhenAsked() throws {
        let rpu = try Self.rpus().full[3]
        let kept = try #require(FFmpegDolbyVision.convertToProfile81(rpu, keepFullLayerMapping: true))
        #expect(kept.sourceLayer == .full)
        let source = try #require(FFmpegDolbyVision.parse(rpu)), out = try #require(FFmpegDolbyVision.parse(kept.rpu))
        #expect(withUnsafeBytes(of: out.curves) { Array($0) } == withUnsafeBytes(of: source.curves) { Array($0) })
        #expect(out.profile == 8 && out.nlq_method_idc == -1)
    }

    /// A NAL unit, a bare escaped payload and a bare unescaped one read the
    /// same (CoreVideo's RPU attachment may be either bare form).
    @Test(.enabled(if: FFmpegDolbyVisionConversion.loaded))
    func ffmpegParsesEveryForm() throws {
        for rpu in try Self.rpus().full.prefix(8) {
            let nal = try #require(FFmpegDolbyVision.parse(rpu))
            let escaped = Array(rpu.dropFirst(2))
            let raw = NALUnits.rbsp(escaped)
            let fromEscaped = try #require(FFmpegDolbyVision.parse(escaped))
            let fromRaw = try #require(FFmpegDolbyVision.parse(raw))
            let bytes = withUnsafeBytes(of: nal) { Array($0) }
            #expect(withUnsafeBytes(of: fromEscaped) { Array($0) } == bytes)
            #expect(withUnsafeBytes(of: fromRaw) { Array($0) } == bytes)
            #expect(nal.profile == 7 && nal.el_type == 2 && nal.has_color_metadata == 1)
            #expect(nal.curves.1.mapping_idc.0 == 1 && nal.curves.1.mmr_order.0 == 2)
            #expect(nal.nlq.0.nlq_offset == 512 && nal.nlq_pivots.1 == 1023)
            // Conversion keeps the form it was given.
            let converted = try #require(FFmpegDolbyVision.convertToProfile81(raw)?.rpu)
            #expect(converted.first == 0x19)
            #expect(FFmpegDolbyVision.parse(converted)?.profile == 8)
        }
        #expect(FFmpegDolbyVision.parse([0x7C, 0x01, 0x19, 0x08, 0x00, 0x00, 0x01]) == nil)
    }

    #if canImport(AVFoundation) && os(macOS)
    @Test(.enabled(if: FFmpegDolbyVisionConversion.loaded))
    func avFoundationDecodesEveryFrame() async throws {
        for set in [try Self.rpus().full, try Self.rpus().minimal] {
            let crafted = try await Self.profile7File(set)
            let session = try await RemuxSession.open(source: DataByteSource(crafted.data),
                                                      options: Self.options(FFmpegDolbyVisionConversion.conversion))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("remux-\(UUID().uuidString)-dv81.mp4")
            try await session.concatenated("video").write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let description = try #require(try await track.load(.formatDescriptions).first)
            let extensions = try #require(CMFormatDescriptionGetExtensions(description) as? [String: Any])
            let atoms = try #require(extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any])
            #expect(atoms["dvvC"] != nil)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            ])
            reader.add(output)
            #expect(reader.startReading())
            var frames = 0
            while let buffer = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(buffer) != nil { frames += 1 }
            }
            #expect(reader.status == .completed, "\(reader.error.map { "\($0)" } ?? "")")
            #expect(frames == crafted.baseLayers.count)
        }
    }
    #endif
}
