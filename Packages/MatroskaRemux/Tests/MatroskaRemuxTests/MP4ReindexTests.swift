/*
 MP4Reindex: an MP4 with oversized chunks, played with its chunks split.

 The fixtures (`make-mp4-fixtures.py`) are one 3-second H.264 + AAC file in
 ffmpeg's layout and laid out with each track as a single chunk, three ways.
 Each re-indexed file is checked by AVFoundation reading it back: every
 track's samples, in order, with the same timing and the same bytes as the
 original's. The fixtures are short, so these use a policy scaled to them
 (a chunk over 1.5 s is split into ~0.5 s ones); the standard policy leaves
 them alone, as it does any chunk under 4 s and 8 MB.
 */

import AVFoundation
import Foundation
import Testing
@testable import MatroskaRemux

@Suite struct MP4ReindexTests {
    static let small = MP4Reindex.Policy(maxChunkBytes: 8 << 20, maxChunkSeconds: 1.5,
                                         targetChunkBytes: 2 << 20, targetChunkSeconds: 0.5)

    static func reindex(_ name: String, policy: MP4Reindex.Policy = small) async throws -> (MP4Reindex.Plan, Data) {
        let source = try Fixtures.source(name)
        let plan = try await MP4Reindex.plan(source, policy: policy)
        let bytes = try await ReindexedByteSource(plan: plan, original: source).read(0 ..< plan.length)
        #expect(Int64(bytes.count) == plan.length)
        return (plan, bytes)
    }

    struct Sample: Equatable {
        var pts: CMTime
        var dts: CMTime
        var bytes: Data
    }

    /// Every track's samples as AVFoundation reads them, unchanged.
    static func samples(_ url: URL) async throws -> [[Sample]] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        var out: [[Sample]] = []
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = true
            reader.add(output)
            #expect(reader.startReading())
            var samples: [Sample] = []
            // Passthrough hands over a chunk's samples in one buffer, so the
            // buffers follow the chunking: split each into its samples.
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var data = Data(count: CMBlockBufferGetDataLength(block))
                data.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
                }
                let count = CMSampleBufferGetNumSamples(buffer)
                var sizes = [Int](repeating: 0, count: count)
                var sizeCount = 0
                CMSampleBufferGetSampleSizeArray(buffer, entryCount: count, arrayToFill: &sizes, entriesNeededOut: &sizeCount)
                if sizeCount == 1, count > 1 { sizes = Array(repeating: sizes[0], count: count) }
                var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
                var timingCount = 0
                CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &timingCount)
                var at = 0
                for index in 0 ..< count {
                    let timing = timings[timingCount == 1 ? 0 : index]
                    let size = sizes[index]
                    // A single timing entry for several samples: each one a duration on.
                    let step = timingCount == 1 ? CMTimeMultiply(timing.duration, multiplier: Int32(index)) : .zero
                    samples.append(Sample(pts: CMTimeAdd(timing.presentationTimeStamp, step),
                                          dts: timing.decodeTimeStamp.isValid ? CMTimeAdd(timing.decodeTimeStamp, step) : timing.decodeTimeStamp,
                                          bytes: data.subdata(in: at ..< at + size)))
                    at += size
                }
                #expect(at == data.count)
            }
            #expect(reader.status == .completed)
            out.append(samples)
        }
        return out
    }

    static func temporary(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "reindex-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    /// The re-indexed file reads back as exactly the original's samples.
    static func checkSamples(_ name: String, _ bytes: Data) async throws {
        let original = try await samples(Fixtures.url(name))
        let url = try temporary(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let reindexed = try await samples(url)
        #expect(original.count == 2)
        #expect(reindexed.count == original.count)
        for (a, b) in zip(original, reindexed) {
            #expect(a.count > 0)
            #expect(a.count == b.count)
            if let i = a.indices.first(where: { $0 < b.count && a[$0] != b[$0] }) {
                Issue.record("sample \(i) of \(a.count): pts \(a[i].pts.seconds)/\(b[i].pts.seconds) dts \(a[i].dts.seconds)/\(b[i].dts.seconds) bytes \(a[i].bytes.count)/\(b[i].bytes.count) same bytes \(a[i].bytes == b[i].bytes)")
            }
        }
    }

    @Test func splitsAOneChunkFileAndTheFreeBoxTakesTheGrowth() async throws {
        let (plan, bytes) = try await Self.reindex("mp4-onechunk-free.mp4")
        #expect(plan.summary.chunksBefore == 2)
        #expect(plan.summary.chunksAfter >= 10)
        #expect(plan.summary.offsetShift == 0)
        #expect(plan.length == Int64(try Fixtures.data("mp4-onechunk-free.mp4").count))
        // The media is served from the original as it is.
        #expect(plan.pieces.contains { if case .original = $0 { true } else { false } })
        try await Self.checkSamples("mp4-onechunk-free.mp4", bytes)
    }

    @Test func shiftsEveryChunkWhenNothingTakesTheGrowth() async throws {
        let (plan, bytes) = try await Self.reindex("mp4-onechunk.mp4")
        #expect(plan.summary.offsetShift > 0)
        #expect(!plan.summary.movieAtEnd)
        #expect(plan.length == Int64(try Fixtures.data("mp4-onechunk.mp4").count) + plan.summary.offsetShift)
        try await Self.checkSamples("mp4-onechunk.mp4", bytes)
    }

    @Test func aMovieAfterTheMediaMovesNothing() async throws {
        let (plan, bytes) = try await Self.reindex("mp4-onechunk-moov-end.mp4")
        #expect(plan.summary.movieAtEnd)
        #expect(plan.summary.offsetShift == 0)
        try await Self.checkSamples("mp4-onechunk-moov-end.mp4", bytes)
    }

    @Test func splitChunksKeepToTheTarget() async throws {
        let source = try Fixtures.source("mp4-onechunk.mp4")
        let plan = try await MP4Reindex.plan(source, policy: Self.small)
        // 3 s per track into ~0.5 s chunks: 6 or 7 each.
        #expect((10 ... 16).contains(plan.summary.chunksAfter))
        // Planning again from the re-indexed file finds nothing to do.
        let again = ReindexedByteSource(plan: plan, original: source)
        await #expect(throws: MP4Reindex.Decline.chunksFine) {
            _ = try await MP4Reindex.plan(again, policy: Self.small)
        }
    }

    @Test func aWellChunkedFileIsLeftAlone() async throws {
        await #expect(throws: MP4Reindex.Decline.chunksFine) {
            _ = try await MP4Reindex.plan(try Fixtures.source("mp4-interleaved.mp4"), policy: Self.small)
        }
    }

    @Test func theStandardPolicyLeavesShortChunksAlone() async throws {
        await #expect(throws: MP4Reindex.Decline.chunksFine) {
            _ = try await MP4Reindex.plan(try Fixtures.source("mp4-onechunk.mp4"))
        }
    }

    @Test func aFragmentedFileIsDeclined() async throws {
        await #expect(throws: MP4Reindex.Decline.fragmented) {
            _ = try await MP4Reindex.plan(try Fixtures.source("mp4-fragmented.mp4"), policy: Self.small)
        }
    }

    @Test func somethingThatIsNotAnMP4IsDeclined() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await MP4Reindex.plan(try Fixtures.source("h264-bframes-aac.mkv"), policy: Self.small)
        }
    }

    @Test func rangesComeFromThePiecesInOrder() async throws {
        let source = try Fixtures.source("mp4-onechunk.mp4")
        let plan = try await MP4Reindex.plan(source, policy: Self.small)
        let whole = try await ReindexedByteSource(plan: plan, original: source).read(0 ..< plan.length)
        // Any range is the same slice of the whole, across piece boundaries.
        for range: Range<Int64> in [0 ..< 1, 10 ..< 5000, 2000 ..< 9000, plan.length - 100 ..< plan.length, 0 ..< plan.length] {
            let part = try await ReindexedByteSource(plan: plan, original: source).read(range)
            #expect(part == whole.subdata(in: Int(range.lowerBound) ..< Int(range.upperBound)))
        }
    }
}

/// Opt-in: `MP4REINDEX_FILE=<an mp4> swift test --filter MP4ReindexFileTests`
/// re-indexes a real file with the standard policy, checks every sample
/// against the original and writes the result beside it as `.reindexed.mp4`.
@Suite struct MP4ReindexFileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MP4REINDEX_FILE"] != nil))
    func reindexesARealFile() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MP4REINDEX_FILE"])
        let url = URL(fileURLWithPath: path)
        let source = try FileByteSource(url: url)
        let plan = try await MP4Reindex.plan(source)
        print("reindex: \(plan.summary)")
        let bytes = try await ReindexedByteSource(plan: plan, original: source).read(0 ..< plan.length)
        let out = url.deletingPathExtension().appendingPathExtension("reindexed.mp4")
        try bytes.write(to: out)
        let original = try await MP4ReindexTests.samples(url)
        let reindexed = try await MP4ReindexTests.samples(out)
        #expect(original.count == reindexed.count)
        for (a, b) in zip(original, reindexed) {
            #expect(a.count == b.count)
            #expect(a == b)
        }
    }
}
