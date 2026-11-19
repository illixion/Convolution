//
//  Gen3DLibrary.swift
//  Hypnos
//
//  Sideload/dev-only (HYPNOS_GEN3D): what the generated-model cache holds, as a
//  browsable list. The cache itself is keyed by hash alone, so this keeps the
//  rest: which picture a model came from, when it was last opened and how the
//  viewer left it (size, turn, light). A model on disk that nothing recorded
//  (made before the library existed) is listed too, without a picture.
//
//  Also remembers which volumes were open, so a relaunch can bring them back
//  when visionOS doesn't (`Gen3DOpenWindows`).
//

#if HYPNOS_GEN3D && os(visionOS)

import DebugTrace
import Foundation
import Observation
import SwiftUI

#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif

/// One model and the adjustments it was left with.
struct Gen3DModelRecord: Codable, Identifiable, Hashable {
    /// The cache key (`Gen3DAssetCache.key`).
    var id: String
    /// The picture it came from. Nil for a model that was cached before the library.
    var image: GalleryImage?
    var engine: String
    var lastOpened: Date
    var size: String = Gen3DSize.life.rawValue
    var yaw: Float = 0
    var lighting: String?
}

/// A row of the library: the record, merged with its file.
struct Gen3DLibraryItem: Identifiable, Hashable {
    var record: Gen3DModelRecord
    var bytes: Int64
    var id: String { record.id }
    var title: String {
        record.image?.title ?? record.image?.fileName
            ?? "Model from " + record.lastOpened.formatted(date: .abbreviated, time: .shortened)
    }
}

@MainActor
@Observable
final class Gen3DLibrary {
    static let shared = Gen3DLibrary()

    private(set) var items: [Gen3DLibraryItem] = []
    /// Bumped when a thumbnail lands, so a card redraws.
    private(set) var thumbnailVersion = 0

    @ObservationIgnored private var records: [String: Gen3DModelRecord] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailsInFlight: Set<String> = []

    private let folder: URL
    private var manifest: URL { folder.appendingPathComponent("library.json") }
    private var thumbnailFolder: URL { folder.appendingPathComponent("Thumbnails", isDirectory: true) }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        folder = support.appendingPathComponent("Gen3D", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifest),
           let saved = try? JSONDecoder().decode([Gen3DModelRecord].self, from: data) {
            records = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        refresh()
    }

    // MARK: - Reading

    /// The record for a key, if one was kept.
    func record(for key: String) -> Gen3DModelRecord? { records[key] }

    /// Rebuilds the list from what the cache holds now (the cache evicts on its
    /// own, and Settings can clear it).
    func refresh() {
        let files = Gen3DAssetCache.shared.allModels()
        var merged: [Gen3DLibraryItem] = []
        for file in files {
            let record = records[file.key] ?? Gen3DModelRecord(
                id: file.key, image: nil, engine: Gen3DConfig.defaultEngine, lastOpened: file.used)
            merged.append(Gen3DLibraryItem(record: record, bytes: file.bytes))
        }
        items = merged.sorted { $0.record.lastOpened > $1.record.lastOpened }
        // Records of models the cache let go of, and their thumbnails.
        let present = Set(files.map(\.key))
        let gone = records.keys.filter { !present.contains($0) }
        if !gone.isEmpty {
            for key in gone {
                records[key] = nil
                try? FileManager.default.removeItem(at: thumbnailURL(for: key))
            }
            scheduleSave()
        }
    }

    // MARK: - Writing

    /// A model was made or opened: remember where it came from and bump it to the top.
    func noteOpened(key: String, image: GalleryImage?, engine: String) {
        var record = records[key] ?? Gen3DModelRecord(id: key, image: image, engine: engine, lastOpened: .now)
        if record.image == nil { record.image = image }
        record.lastOpened = .now
        records[key] = record
        scheduleSave()
        refresh()
    }

    /// The viewer changed how the model is shown.
    func noteAdjusted(key: String, size: Gen3DSize, yaw: Float, lighting: Gen3DLighting) {
        guard var record = records[key] else { return }
        let (rawSize, rawLighting) = (size.rawValue, lighting.rawValue)
        guard record.size != rawSize || record.yaw != yaw || record.lighting != rawLighting else { return }
        record.size = rawSize
        record.yaw = yaw
        record.lighting = rawLighting
        records[key] = record
        scheduleSave()
    }

    func remove(key: String) {
        Gen3DAssetCache.shared.remove(key: key)
        records[key] = nil
        try? FileManager.default.removeItem(at: thumbnailURL(for: key))
        scheduleSave()
        refresh()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(Array(self.records.values)) {
                try? data.write(to: self.manifest, options: .atomic)
            }
        }
    }

    // MARK: - Thumbnails

    func thumbnailURL(for key: String) -> URL {
        thumbnailFolder.appendingPathComponent(key + ".png")
    }

    /// Makes the model's thumbnail once (QuickLook renders the USDZ itself),
    /// falling back to the picture it came from.
    func makeThumbnailIfNeeded(for item: Gen3DLibraryItem) async {
        let key = item.id
        guard !FileManager.default.fileExists(atPath: thumbnailURL(for: key).path),
              thumbnailsInFlight.insert(key).inserted else { return }
        defer { thumbnailsInFlight.remove(key) }
        var png: Data?
        #if canImport(QuickLookThumbnailing)
        let request = QLThumbnailGenerator.Request(
            fileAt: Gen3DAssetCache.shared.url(forKey: key),
            size: CGSize(width: 320, height: 320), scale: 2, representationTypes: .thumbnail)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            png = representation.uiImage.pngData()
        }
        #endif
        if png == nil, let url = item.record.image?.thumbnailURL,
           let data = try? await ImageLoader.shared.loadImageData(from: url) {
            png = data
        }
        guard let png else { return }
        try? png.write(to: thumbnailURL(for: key), options: .atomic)
        thumbnailVersion += 1
    }
}

// MARK: - Which volumes are open

/// The volumes that are open, kept so a relaunch can reopen them. visionOS
/// restores a scene by itself only sometimes (not after the app was replaced by
/// an install, or ended by the system), and what it doesn't bring back was
/// simply lost. A volume's window position is the system's, so a reopened one
/// comes up in front of the wearer, not where it was.
@MainActor
enum Gen3DOpenWindows {
    private static let key = "gen3dOpenWindows"
    /// Volumes showing right now (restored by the system or opened by us).
    private(set) static var live: Set<UUID> = []
    private static var restoredThisLaunch = false

    private static var saved: [Gen3DWindowValue] {
        get {
            guard let data = HypnosDefaults.store.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Gen3DWindowValue].self, from: data)) ?? []
        }
        set { HypnosDefaults.store.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func opened(_ value: Gen3DWindowValue) {
        live.insert(value.id)
        if !saved.contains(value) { saved.append(value) }
    }

    /// The volume went away because it was closed (not because the system took the scene).
    static func closed(_ value: Gen3DWindowValue) {
        live.remove(value.id)
        saved.removeAll { $0 == value }
    }

    /// The system dropped the scene (room change, memory): not remembered as closed.
    static func suspended(_ value: Gen3DWindowValue) {
        live.remove(value.id)
    }

    /// Opens what was open at the last launch and isn't showing, once per launch.
    static func restoreIfNeeded(open: (Gen3DWindowValue) -> Void) async {
        guard !restoredThisLaunch else { return }
        restoredThisLaunch = true
        // Give the system its own restoration first.
        try? await Task.sleep(for: .seconds(2))
        let missing = saved.filter { !live.contains($0.id) }
        guard !missing.isEmpty else { return }
        AppLogger.gen3d.info("Reopening \(missing.count, privacy: .public) generated model volume(s) from the last session")
        for value in missing {
            open(value)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

#endif
