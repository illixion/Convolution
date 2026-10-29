import Foundation
import Testing
@testable import GeneratedCaptions

private let base = URL(string: "https://example.test/hls/master.m3u8")!

struct HLSPlaylistTests {
    /// Shaped like YouTube's master: audio renditions with quoted commas in
    /// their attributes, then variants naming the group.
    private let master = """
    #EXTM3U
    #EXT-X-MEDIA:URI="https://a.test/ar.m3u8",TYPE=AUDIO,GROUP-ID="233",LANGUAGE="ar",NAME="Arabic, dubbed",DEFAULT=NO,AUTOSELECT=YES
    #EXT-X-MEDIA:URI="https://a.test/en-dub.m3u8",TYPE=AUDIO,GROUP-ID="233",LANGUAGE="en-US",NAME="American English - dubbed",DEFAULT=NO,AUTOSELECT=YES
    #EXT-X-MEDIA:URI="https://a.test/en.m3u8",TYPE=AUDIO,GROUP-ID="233",LANGUAGE="en-US",NAME="American English - original",DEFAULT=YES,AUTOSELECT=YES
    #EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="233"
    v-low.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO="233"
    v-high.m3u8
    """

    @Test func readsRenditionsAndVariants() {
        let playlist = HLSPlaylist(master, base: base)
        #expect(playlist.isMaster)
        #expect(playlist.renditions.count == 3)
        #expect(playlist.renditions[0].name == "Arabic, dubbed")
        #expect(playlist.variants.map(\.bandwidth) == [900_000, 5_000_000])
        #expect(playlist.variants[0].url == URL(string: "https://example.test/hls/v-low.m3u8"))
    }

    @Test func choosesTheSelectedAudioByNameThenLanguageThenDefault() {
        let playlist = HLSPlaylist(master, base: base)
        // Two renditions share a language: the name tells them apart.
        #expect(playlist.rendition(name: "American English - dubbed", language: "en_US")?.url?.lastPathComponent == "en-dub.m3u8")
        // No name: the first of the language (AVFoundation says en_US).
        #expect(playlist.rendition(name: nil, language: "en_US")?.url?.lastPathComponent == "en-dub.m3u8")
        // A language of another region still finds its language.
        #expect(playlist.rendition(name: nil, language: "ar-EG")?.url?.lastPathComponent == "ar.m3u8")
        // Nothing selected: the default one.
        #expect(playlist.rendition(name: nil, language: nil)?.url?.lastPathComponent == "en.m3u8")
    }

    @Test func segmentsAreTimedOnThePlaylistsTimeline() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        #EXT-X-BYTERANGE:1000@0
        s.mp4
        #EXTINF:4.5,
        #EXT-X-BYTERANGE:2000
        s.mp4
        #EXTINF:6.0,
        s2.mp4
        #EXT-X-ENDLIST
        """
        let playlist = HLSPlaylist(text, base: base)
        #expect(playlist.hasEnd)
        #expect(playlist.map?.url.lastPathComponent == "init.mp4")
        #expect(playlist.segments.map(\.start) == [0, 6, 10.5])
        #expect(playlist.segments[1].byteRange == 1000 ..< 3000)
        #expect(playlist.segments[2].byteRange == nil)
        #expect(playlist.firstSegment(after: 0) == 0)
        #expect(playlist.firstSegment(after: 5.99) == 0)
        #expect(playlist.firstSegment(after: 6) == 1)
        #expect(playlist.firstSegment(after: 12) == 2)
        #expect(playlist.firstSegment(after: 99) == 3)
    }

    @Test func encryptionIsNoticed() {
        let text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:6,\ns.ts\n"
        #expect(HLSPlaylist(text, base: base).isEncrypted)
        #expect(!HLSPlaylist("#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:6,\ns.ts\n", base: base).isEncrypted)
    }
}

/// Which URLs a source asked for, in order.
private actor Requests {
    var urls: [String] = []
    func note(_ url: URL) { urls.append(url.lastPathComponent) }
}

struct HLSCaptionAudioTests {
    private func fetcher(_ requests: Requests, files: [String: Data]) -> HLSCaptionAudio.Fetch {
        { url, _ in
            await requests.note(url)
            guard let data = files[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    @Test func readsTheSelectedRenditionFromTheSeekedSegmentOn() async throws {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:URI="fr.m3u8",TYPE=AUDIO,GROUP-ID="a",LANGUAGE="fr",NAME="French"
        #EXT-X-MEDIA:URI="en.m3u8",TYPE=AUDIO,GROUP-ID="a",LANGUAGE="en",NAME="English"
        #EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"
        v.m3u8
        """
        let media = "#EXTM3U\n#EXTINF:6,\ns0.aac\n#EXTINF:6,\ns1.aac\n#EXTINF:6,\ns2.aac\n#EXT-X-ENDLIST\n"
        // MPEG-TS segments (0x47) are refused, but only after being asked for.
        let ts = Data([0x47, 0x40, 0x00, 0x10])
        let requests = Requests()
        let source = try await HLSCaptionAudio.source(
            playlist: base, selection: .init(name: "English", language: "en"), start: 7,
            fetch: fetcher(requests, files: ["master.m3u8": Data(master.utf8), "en.m3u8": Data(media.utf8), "s1.aac": ts]))
        await #expect(throws: HLSCaptionAudio.Failure.self) { _ = try await source.next() }
        // The French playlist and the first segment were never touched.
        #expect(await requests.urls == ["master.m3u8", "en.m3u8", "s1.aac"])
    }

    @Test func fallsBackToTheLightestVariantWhenAudioIsMuxed() async throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=9000000
        high.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        low.m3u8
        """
        let media = "#EXTM3U\n#EXTINF:6,\nseg.aac\n#EXT-X-ENDLIST\n"
        let requests = Requests()
        let source = try await HLSCaptionAudio.source(
            playlist: base, selection: .init(), start: 0,
            fetch: fetcher(requests, files: ["master.m3u8": Data(master.utf8), "low.m3u8": Data(media.utf8), "seg.aac": Data([0x47])]))
        _ = try? await source.next()
        #expect(await requests.urls == ["master.m3u8", "low.m3u8", "seg.aac"])
    }

    @Test func refusesProtectedAndEmptyStreams() async {
        let requests = Requests()
        let protected = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:6,\ns.aac\n"
        await #expect(throws: HLSCaptionAudio.Failure.self) {
            _ = try await HLSCaptionAudio.source(playlist: base, selection: .init(), start: 0,
                fetch: fetcher(requests, files: ["master.m3u8": Data(protected.utf8)]))
        }
        await #expect(throws: HLSCaptionAudio.Failure.self) {
            _ = try await HLSCaptionAudio.source(playlist: base, selection: .init(), start: 0,
                fetch: fetcher(requests, files: ["master.m3u8": Data("#EXTM3U\n".utf8)]))
        }
    }
}

/// Needs real HLS packed audio segments (ADTS AAC behind an ID3 tag), e.g. two
/// consecutive segments of a YouTube audio rendition, as comma-separated paths
/// in CAPTION_PACKED_FIXTURE, with their playlist durations in
/// CAPTION_PACKED_DURATIONS ("5.772433,5.7057").
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CAPTION_PACKED_FIXTURE"] != nil))
struct PackedCaptionAudioIntegrationTests {
    @Test func decodesSegmentsOnThePlaylistsTimeline() async throws {
        let paths = try #require(ProcessInfo.processInfo.environment["CAPTION_PACKED_FIXTURE"]).split(separator: ",").map(String.init)
        let durations = (ProcessInfo.processInfo.environment["CAPTION_PACKED_DURATIONS"] ?? "")
            .split(separator: ",").compactMap { Double($0) }
        try #require(durations.count == paths.count)
        let feed = Feed(paths: paths, durations: durations)
        let source = RAVECaptionAudioSource.packedAudio { try await feed.next() }
        var first: Double?
        var through = 0.0
        var peak: Float = 0
        while let chunk = try await source.next() {
            if first == nil { first = chunk.time } else { #expect(abs(chunk.time - through) < 0.05) }
            through = chunk.time + Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            if let samples = chunk.buffer.floatChannelData?[0] {
                for index in 0 ..< Int(chunk.buffer.frameLength) { peak = max(peak, abs(samples[index])) }
            }
        }
        #expect(first == 0)
        // Both segments decoded whole, the second placed where the playlist puts it.
        #expect(abs(through - durations.reduce(0, +)) < 0.2)
        #expect(peak > 0.05)
    }

    private actor Feed {
        let paths: [String]
        let durations: [Double]
        var index = 0
        init(paths: [String], durations: [Double]) { self.paths = paths; self.durations = durations }
        func next() throws -> (data: Data, start: Double)? {
            guard index < paths.count else { return nil }
            defer { index += 1 }
            return (try Data(contentsOf: URL(fileURLWithPath: paths[index])), durations[..<index].reduce(0, +))
        }
    }
}
