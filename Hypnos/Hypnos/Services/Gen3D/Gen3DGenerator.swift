//
//  Gen3DGenerator.swift
//  Hypnos
//
//  Sideload/dev-only (HYPNOS_GEN3D): turns one picture into a wrap-around USDZ
//  through Gen3DServer. Cached per (picture, engine, options). A submitted job's
//  id is remembered, so closing the window mid-job and opening it again picks
//  the same job up instead of starting (and queueing) another two minutes.
//

#if HYPNOS_GEN3D

import Gen3DConversion
import DebugTrace
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class Gen3DGenerator {
    enum Phase: Equatable {
        case idle
        case loadingPicture
        case uploading
        /// Queued or running on the server.
        case generating(stage: String?, fraction: Double?)
        case downloading
        case converting
        case ready(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The cache key of the model that is ready (what the library files its adjustments under).
    private(set) var modelKey: String?

    /// A job is in flight (not idle, finished or failed).
    var isWorking: Bool {
        switch phase {
        case .idle, .ready, .failed: return false
        default: return true
        }
    }

    private static let pendingKey = "gen3dPendingJobs"
    private let log = AppLogger.gen3d

    /// Runs to completion (or failure); cancel the calling task to stop polling.
    /// A job already on the server is not cancelled with it — it finishes there
    /// and is picked up on the next open.
    /// `cacheKey` opens a model straight from the cache (the library, a restored
    /// volume), whatever engine and options are set now; without the file, or
    /// without a key, the picture is generated as usual.
    func run(for image: GalleryImage?, cacheKey: String? = nil, engine requested: String? = nil) async {
        if let cacheKey, let cached = Gen3DAssetCache.shared.cached(forKey: cacheKey) {
            modelKey = cacheKey
            phase = .ready(cached)
            noteOpened(key: cacheKey, image: image, engine: requested ?? Gen3DConfig.engine)
            return
        }
        guard let image else {
            phase = .failed("This model is no longer cached, and the picture it came from wasn't kept.")
            return
        }
        let engine = requested ?? Gen3DConfig.engine
        let options = Gen3DConfig.optionsJSON
        let key = Gen3DAssetCache.key(source: image.fullSizeURL, engine: engine, optionsJSON: options)
        if let cached = Gen3DAssetCache.shared.cached(forKey: key) {
            modelKey = key
            phase = .ready(cached)
            noteOpened(key: key, image: image, engine: engine)
            return
        }
        do {
            let client = try Gen3DClient()
            let jobID = try await existingOrNewJob(key: key, image: image, engine: engine, options: options, client: client)
            let finished = try await poll(jobID, client: client)
            guard let model = finished.result?.files.first(where: { $0.hasSuffix(".glb") }) else {
                throw Gen3DError.failed("The server finished without a model.")
            }
            phase = .downloading
            let glb = FileManager.default.temporaryDirectory.appendingPathComponent("gen3d-\(jobID).glb")
            defer { try? FileManager.default.removeItem(at: glb) }
            try await client.download(job: jobID, file: model, to: glb)

            phase = .converting
            let usdz = FileManager.default.temporaryDirectory.appendingPathComponent("gen3d-\(jobID).usdz")
            try await Task.detached(priority: .userInitiated) {
                try Gen3DConverter.convert(glb: glb, to: usdz)
            }.value
            let stored = try Gen3DAssetCache.shared.store(usdz, forKey: key)
            forget(key)
            log.info("Generated 3D ready (\(finished.result?.timings?.values.reduce(0, +) ?? 0, privacy: .public) s on the server)")
            modelKey = key
            phase = .ready(stored)
            noteOpened(key: key, image: image, engine: engine)
        } catch is CancellationError {
            phase = .idle
        } catch {
            log.error("Generated 3D failed: \(error.logCode, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func noteOpened(key: String, image: GalleryImage?, engine: String) {
        #if os(visionOS)
        Gen3DLibrary.shared.noteOpened(key: key, image: image, engine: engine)
        #endif
    }

    // MARK: - Steps

    private func existingOrNewJob(key: String, image: GalleryImage, engine: String,
                                  options: String, client: Gen3DClient) async throws -> String {
        if let remembered = pending[key] {
            // Still known to the server and not failed: carry on with it.
            if let status = try? await client.status(of: remembered), status.status != "failed" {
                return remembered
            }
            forget(key)
        }
        phase = .loadingPicture
        guard let data = try await ImageLoader.shared.loadImageData(from: image.fullSizeURL) else {
            throw Gen3DError.failed("The picture couldn't be loaded.")
        }
        try Task.checkCancellation()
        phase = .uploading
        guard let png = Self.pngData(from: data, maxPixel: 2048) else {
            throw Gen3DError.failed("The picture's format couldn't be read.")
        }
        let id = try await client.submit(image: png, engine: engine, optionsJSON: options)
        remember(key, jobID: id)
        return id
    }

    private func poll(_ jobID: String, client: Gen3DClient) async throws -> Gen3DJobStatus {
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                let status = try await client.status(of: jobID)
                failures = 0
                switch status.status {
                case "done":
                    return status
                case "failed":
                    throw Gen3DError.failed(Self.lastLine(of: status.error) ?? "The server couldn't generate it.")
                default:
                    phase = .generating(stage: status.status == "queued" ? "queued" : status.progress?.stage,
                                        fraction: status.progress?.fraction)
                }
            } catch let error as Gen3DError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The network blinked; the job is still running.
                failures += 1
                if failures >= 5 { throw error }
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Remembered jobs

    private var pending: [String: String] {
        HypnosDefaults.store.dictionary(forKey: Self.pendingKey) as? [String: String] ?? [:]
    }

    private func remember(_ key: String, jobID: String) {
        var all = pending
        all[key] = jobID
        HypnosDefaults.store.set(all, forKey: Self.pendingKey)
    }

    private func forget(_ key: String) {
        var all = pending
        guard all.removeValue(forKey: key) != nil else { return }
        HypnosDefaults.store.set(all, forKey: Self.pendingKey)
    }

    /// Whatever the device can decode (HEIC, JPEG, WebP, …) as PNG, at most
    /// `maxPixel` on the long side: the server reads PNG only and gains nothing
    /// from more pixels.
    nonisolated private static func pngData(from data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A Python traceback's last line is the error; the rest is frames.
    private static func lastLine(of text: String?) -> String? {
        text?.split(separator: "\n").last.map(String.init)
    }
}

#endif
