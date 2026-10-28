import Foundation
import Testing
@testable import MatroskaRemux

@Suite("Network recovery")
struct NetworkRecoveryTests {
    @Test func failedReadsDoNotChangeRecoveredMediaOrSubtitleTimestamps() async throws {
        let data = try Fixtures.data("subtitles.mkv")
        let reference = try await RemuxSession.open(source: DataByteSource(data))
        let bytes = InterruptibleSource(data)
        let interrupted = try await RemuxSession.open(source: bytes)
        for index in (0 ..< interrupted.segmentCount).reversed() {
            await interrupted.dropCache()
            await bytes.setOffline(true)
            // Concurrent video/audio requests share a parse. A failed parse
            // must be discarded, rather than cached or partially published.
            async let videoFailed = fails(interrupted, "video/\(index).m4s")
            async let audioFailed = fails(interrupted, "audio-2/\(index).m4s")
            #expect(await videoFailed)
            #expect(await audioFailed)
            await bytes.setOffline(false)
            for rendition in ["video", "audio-2", "muxed"] {
                let path = "\(rendition)/\(index).m4s"
                #expect(try await interrupted.fetch(path) == reference.fetch(path))
            }
        }
        await bytes.setOffline(true)
        do {
            _ = try await interrupted.subtitleBlocks(track: 3, from: 0, through: 60)
            Issue.record("An uncached subtitle read should fail during the outage")
        } catch is URLError { }
        await bytes.setOffline(false)
        let recovered = try await interrupted.subtitleBlocks(track: 3, from: 0, through: 60).blocks
        let expected = try await reference.subtitleBlocks(track: 3, from: 0, through: 60).blocks
        #expect(recovered.map(\.start) == expected.map(\.start))
        #expect(recovered.map(\.data) == expected.map(\.data))
    }

    private func fails(_ session: RemuxSession, _ path: String) async -> Bool {
        do { _ = try await session.fetch(path); return false }
        catch is URLError { return true }
        catch { return false }
    }
}

private actor InterruptibleSource: ByteSource {
    // Bypass RecentReadsSource so even a small, previously read fixture
    // actually reaches the failing transport on each parse.
    nonisolated let isLocal = true
    let data: Data
    var offline = false
    init(_ data: Data) { self.data = data }
    func setOffline(_ value: Bool) { offline = value }
    func length() -> Int64? { Int64(data.count) }
    func read(_ range: Range<Int64>) throws -> Data {
        if offline { throw URLError(.networkConnectionLost) }
        return data.subdata(in: Int(range.lowerBound) ..< min(data.count, Int(range.upperBound)))
    }
}
