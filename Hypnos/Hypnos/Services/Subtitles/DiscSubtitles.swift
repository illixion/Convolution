/*
 Hypnos - a Blu-ray disc's own subtitles (PGS bitmaps)

 A disc's subtitles are bitmaps muxed into the same clip as the base view,
 so they arrive as the picture decoder reads it: `MVCPictureSource` asks
 mvc3d for the playlist's PGS PIDs alongside the video and hands their
 packets here. Every track is collected whichever is showing (they are a
 few kilobytes a minute), so switching tracks shows what has been read
 already; only the showing track's bitmaps are ever decoded, and each one
 only while it is on screen (`RAVESubtitleImage`).

 A caption lasts until the next caption of its track, which the reader
 has normally seen by the time the picture gets there (subtitles are
 muxed ahead of their pictures, and decoding runs ahead of playback). A
 caption whose successor wasn't read (the reading moved away: a seek) is
 cut off where the reading stopped, and at `maximumOpenSeconds` while
 reading continues. Reading restarts at an entry point on each seek, so a
 caption that began before that point shows from the next one in its
 track (Blu-ray repeats complete captions at acquisition points, mostly
 every caption on the discs seen).

 Times here are film time: playlist time + `originSeconds`, the picture's.
 */

import CoreGraphics
import Foundation
import MVC3D
import RAVEUI

final class DiscSubtitles: @unchecked Sendable {
    struct Track: Sendable {
        var pid: UInt16
        var language: String?
    }

    let tracks: [Track]
    private let origin: Int64
    private let lock = NSLock()
    private var decoders: [UInt16: PGSDecoder] = [:]
    /// Captions by PID, keyed by playlist PTS (a re-read replaces its own).
    private var captions: [UInt16: [Int64: PGSCaption]] = [:]
    /// Playlist PTS ranges read without a break, one per run, merged.
    private var covered: [ClosedRange<Int64>] = []
    private var reading: ClosedRange<Int64>?
    private var listeners: [UInt16: [UUID: AsyncStream<RAVESubtitleTrack>.Continuation]] = [:]

    /// Longest a caption is shown while its end hasn't been read yet.
    static let maximumOpenSeconds = 10.0

    init(playlist: BlurayPlaylist, originSeconds: Double) {
        // PGS only: 0x90. (0x91 is interactive graphics, 0x92 text subtitles, which no disc seen uses.)
        tracks = (playlist.items.first?.subtitleStreams ?? [])
            .filter { $0.codingType == 0x90 }
            .map { Track(pid: $0.pid, language: $0.language) }
        origin = Int64((originSeconds * 90_000).rounded())
    }

    var pids: Set<UInt16> { Set(tracks.map(\.pid)) }

    /// A new read from `playlistPTS` (a seek): partial display sets are dropped.
    func beginRun(at playlistPTS: Int64) {
        lock.withLock {
            closeReading()
            for pid in decoders.keys { decoders[pid]?.reset() }
            reading = playlistPTS ... playlistPTS
        }
    }

    /// Side packets from the decoder, in stream order, playlist timestamps.
    func feed(_ packets: [PESPacket]) {
        var changed: Set<UInt16> = []
        lock.withLock {
            for packet in packets {
                // Reading starts at the entry point before the seek target.
                if let pts = packet.pts, let range = reading, !range.contains(pts) {
                    reading = min(range.lowerBound, pts) ... max(range.upperBound, pts)
                }
                guard pids.contains(packet.pid) else { continue }
                var decoder = decoders[packet.pid] ?? PGSDecoder()
                for caption in decoder.feed(pes: packet.payload, pts: packet.pts) {
                    captions[packet.pid, default: [:]][caption.pts] = caption
                    changed.insert(packet.pid)
                }
                decoders[packet.pid] = decoder
            }
        }
        for pid in changed { publish(pid) }
    }

    /// The cues of `pid` as they become known: one track now, another each
    /// time a caption arrives.
    func cues(pid: UInt16) -> AsyncStream<RAVESubtitleTrack> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RAVESubtitleTrack>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock { listeners[pid, default: [:]][id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.listeners[pid]?.removeValue(forKey: id) }
        }
        continuation.yield(track(pid: pid))
        return stream
    }

    private func publish(_ pid: UInt16) {
        let continuations = lock.withLock { listeners[pid].map { Array($0.values) } ?? [] }
        guard !continuations.isEmpty else { return }
        let track = track(pid: pid)
        for continuation in continuations { continuation.yield(track) }
    }

    private func closeReading() {
        guard let reading else { return }
        var merged = covered + [reading]
        merged.sort { $0.lowerBound < $1.lowerBound }
        covered = merged.reduce(into: []) { result, range in
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        self.reading = nil
    }

    /// Which unbroken read `pts` falls in, and whether it is the one still going.
    private func coverage(of pts: Int64) -> (range: ClosedRange<Int64>, isOpen: Bool)? {
        if let reading, reading.contains(pts) { return (reading, true) }
        return covered.first { $0.contains(pts) }.map { ($0, false) }
    }

    private func track(pid: UInt16) -> RAVESubtitleTrack {
        lock.withLock {
            let list = (captions[pid] ?? [:]).values.sorted { $0.pts < $1.pts }
            var cues: [RAVESubtitleCue] = []
            for (index, caption) in list.enumerated() where !caption.isEmpty {
                guard let bounds = caption.bounds, caption.videoWidth > 0, caption.videoHeight > 0 else { continue }
                let start = caption.pts
                let span = coverage(of: start)
                var end = start + Int64(Self.maximumOpenSeconds * 90_000)
                if index + 1 < list.count, span?.range.contains(list[index + 1].pts) ?? false {
                    end = list[index + 1].pts
                } else if let span, !span.isOpen {
                    end = min(end, span.range.upperBound)
                }
                let frame = CGRect(x: Double(bounds.x) / Double(caption.videoWidth),
                                   y: Double(bounds.y) / Double(caption.videoHeight),
                                   width: Double(bounds.width) / Double(caption.videoWidth),
                                   height: Double(bounds.height) / Double(caption.videoHeight))
                let image = RAVESubtitleImage(id: Self.imageID(pid: pid, pts: start), frame: frame) {
                    Self.makeImage(caption)
                }
                cues.append(RAVESubtitleCue(start: Double(start + origin) / 90_000, end: Double(end + origin) / 90_000,
                                            image: image))
            }
            return RAVESubtitleTrack(cues: cues)
        }
    }

    /// Stable per caption, so a cue rebuilt into a new track keeps its
    /// decoded bitmap in the views that show it.
    private static func imageID(pid: UInt16, pts: Int64) -> Int {
        Int(pid) << 40 ^ Int(truncatingIfNeeded: pts)
    }

    static func makeImage(_ caption: PGSCaption) -> CGImage? {
        guard let rendered = caption.renderRGBA() else { return nil }
        let data = rendered.pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: rendered.width, height: rendered.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rendered.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
