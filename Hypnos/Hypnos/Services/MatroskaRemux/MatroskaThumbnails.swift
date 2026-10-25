/*
 Hypnos - thumbnails of MKV and WebM files

 AVAssetImageGenerator can't open Matroska, so a local MKV's grid cell
 stayed a placeholder (WebM had WebKit's offscreen capture on iOS and
 visionOS only), and so did a Nextcloud MKV or WebM whenever the server
 renders no preview for it (it needs its movie preview provider and
 ffmpeg). `MatroskaRemux.VideoStill` makes the smallest MP4 with one
 keyframe a tenth of the way in (at most ten minutes): the video's init
 segment and one fragment. AVAssetImageGenerator opens that from a
 temporary file. A server's file is read in a few ranges (the head and
 Cues, the keyframe's cluster start and the keyframe: under 1 MB for a
 1080p film), with the credential every AVFoundation read uses
 (`RemoteByteSource`).

 This is the fallback when the normal path fails: `ThumbnailGenerator`
 (local files) and `ImageLoader.loadMatroskaThumbnail` (a server's video
 without a preview). Stash makes its own thumbnails and is never asked.
 At most two run at once: a grid asks for a screenful together. A file the
 remux declines (VP8, say) isn't read again for the rest of the launch.
 */

import AVFoundation
import CoreGraphics
import DebugTrace
import Foundation
import MatroskaRemux
import Synchronization

enum MatroskaThumbnails {
    /// Worth trying for this file: by its name (a grid asks for hundreds,
    /// so nothing is read to find out).
    static func handles(_ url: URL, fileName: String? = nil) -> Bool {
        guard url.isFileURL || url.scheme == "http" || url.scheme == "https" else { return false }
        return [fileName.map { ($0 as NSString).pathExtension }, url.pathExtension].contains {
            ["mkv", "mk3d", "webm"].contains($0?.lowercased() ?? "")
        }
    }

    /// A frame of the video at `url`, fitting `maxSize`, or nil.
    static func image(for url: URL, maxSize: CGFloat) async -> CGImage? {
        guard !declined.withLock({ $0.contains(url.absoluteString) }) else { return nil }
        await gate.acquire()
        defer { Task { await gate.release() } }
        let started = ContinuousClock.now
        let still: VideoStill
        do {
            let source: any ByteSource = url.isFileURL ? try FileByteSource(url: url) : RemoteByteSource(url: url)
            still = try await VideoStill.make(source: source)
        } catch let error as RemuxError {
            AppLogger.imageLoader.debug("No Matroska still: \(error.description, privacy: .public)")
            _ = declined.withLock { $0.insert(url.absoluteString) }
            return nil
        } catch {
            AppLogger.imageLoader.warning("Matroska still failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try still.mp4.write(to: file)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSize, height: maxSize)
            let image = try await generator.image(at: .zero).image
            let elapsed = (ContinuousClock.now - started).components
            let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            AppLogger.imageLoader.debug("""
                Matroska thumbnail from \(still.seconds, format: .fixed(precision: 1), privacy: .public) s in: \
                \(still.reads, privacy: .public) reads, \(still.bytesRead, privacy: .public) bytes, \
                \(milliseconds, privacy: .public) ms
                """)
            return image
        } catch {
            AppLogger.imageLoader.warning("Matroska still didn't decode: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }

    private static let gate = Gate(permits: 2)
    private static let declined = Mutex<Set<String>>([])

    /// A counting semaphore for async callers.
    private actor Gate {
        private var permits: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(permits: Int) { self.permits = permits }

        func acquire() async {
            if permits > 0 {
                permits -= 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                permits += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }
}
