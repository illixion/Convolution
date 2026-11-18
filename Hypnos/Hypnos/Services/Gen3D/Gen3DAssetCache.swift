//
//  Gen3DAssetCache.swift
//  Hypnos
//
//  Sideload/dev-only (HYPNOS_GEN3D): the USDZ files the generator made, one per
//  (picture, engine, options). On the shared LRUDiskCache engine like every
//  other cache, so the budget, eviction and Settings → Cache cover it.
//

#if HYPNOS_GEN3D

import Foundation

final class Gen3DAssetCache: @unchecked Sendable {
    static let shared = Gen3DAssetCache()

    private let engine: LRUDiskCache

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        engine = LRUDiskCache(
            directory: caches.appendingPathComponent("Gen3DCache", isDirectory: true),
            domain: .gen3d,
            log: AppLogger.diskCache,
            formatVersion: 1
        )
    }

    /// What a result depends on: the picture, the engine and what it was asked for.
    static func key(source: URL, engine: String, optionsJSON: String) -> String {
        return LRUDiskCache.sha256Key("\(source.absoluteString)|\(engine)|\(optionsJSON)")
    }

    func url(forKey key: String) -> URL {
        engine.directory.appendingPathComponent(key + ".usdz")
    }

    /// The cached model, touched so it counts as recently used.
    func cached(forKey key: String) -> URL? {
        let url = url(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        engine.touch(url)
        return url
    }

    /// Takes ownership of a freshly converted file.
    func store(_ file: URL, forKey key: String) throws -> URL {
        let destination = url(forKey: key)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        engine.noteWrite(at: destination)
        engine.evictIfNeeded()
        return destination
    }

    func clear() { engine.clear() }
}

#endif
