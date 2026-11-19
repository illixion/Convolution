//
//  OfflineCatalog.swift
//  Hypnos
//
//  Everything the device holds that can be opened without a network, from any
//  source, as one list. Filters → On This Device browses it.
//
//  What counts, per type:
//  - Pictures: files in Documents/Photos, and any picture from a server (Stash,
//    Nextcloud) whose full-size file is in the disk cache. The disk cache is
//    keyed by a hash of the URL and keeps nothing of the picture, so the app
//    records each picture's metadata the first time it caches the full size
//    (`notePicture`). Pictures cached before the index existed are not listed
//    until they are opened again.
//  - Videos: files in Documents/Videos (not the Library's downloads, which are
//    Films & Shows).
//  - Films & Shows: Library (Jellyfin) downloads.
//  - 3D Models: generated models still in their cache (sideload builds on
//    visionOS only).
//  The Photos library is the device's own and has its own source, so it is not
//  mixed in here.
//

import DebugTrace
import Foundation
import Observation

/// The kinds of thing On This Device can show, and filter by.
enum OfflineMediaType: String, CaseIterable, Identifiable, Codable {
    case pictures, videos, films, models

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pictures: return "Pictures"
        case .videos: return "Videos"
        case .films: return "Films & Shows"
        case .models: return "3D Models"
        }
    }

    var symbol: String {
        switch self {
        case .pictures: return "photo"
        case .videos: return "video"
        case .films: return "film"
        case .models: return "cube.transparent"
        }
    }

    /// Whether this build and platform can open the type.
    static var available: [OfflineMediaType] {
        allCases.filter { type in
            if type == .models {
                #if HYPNOS_GEN3D && os(visionOS)
                return true
                #else
                return false
                #endif
            }
            return true
        }
    }
}

/// One thing on the device.
struct OfflineItem: Identifiable {
    enum Payload {
        case picture(GalleryImage)
        case video(GalleryVideo)
        case film(LibraryItem)
        #if HYPNOS_GEN3D && os(visionOS)
        case model(Gen3DLibraryItem)
        #endif
    }

    let id: String
    let type: OfflineMediaType
    let title: String
    /// A line under the title (the show, the year, the source).
    let subtitle: String?
    /// When it arrived or was last used; the default sort.
    let date: Date
    let bytes: Int64
    let payload: Payload
}

/// A picture the app has the full size of, remembered with what it takes to open it.
struct OfflinePictureRecord: Codable, Identifiable {
    var id: String { image.fullSizeURL.absoluteString }
    var image: GalleryImage
    var lastSeen: Date
}

@MainActor
@Observable
final class OfflineCatalog {
    static let shared = OfflineCatalog()

    private(set) var items: [OfflineItem] = []
    private(set) var isLoading = false
    private(set) var loadedAt: Date?

    @ObservationIgnored private var pictures: [String: OfflinePictureRecord] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let file: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutableFolder = folder
        try? mutableFolder.setResourceValues(excluded)
        file = folder.appendingPathComponent("pictures.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([OfflinePictureRecord].self, from: data) {
            pictures = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - Recording

    /// A picture's full size is on the device now (the viewer just loaded it).
    /// Local and Photos pictures are on the device anyway and are listed from
    /// their own sources.
    func notePicture(_ image: GalleryImage) {
        switch image.source {
        case .local, .photos, .shared: return
        default: break
        }
        var record = OfflinePictureRecord(image: image, lastSeen: .now)
        if let existing = pictures[record.id] { record.image = existing.image }
        pictures[record.id] = record
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(Array(self.pictures.values)) {
                try? data.write(to: self.file, options: .atomic)
            }
        }
    }

    // MARK: - Reading

    /// Rebuilds the list from what is on the device now.
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        var found: [OfflineItem] = []
        found += await cachedServerPictures()
        found += await localPictures()
        found += await localVideos()
        found += filmDownloads()
        #if HYPNOS_GEN3D && os(visionOS)
        found += models()
        #endif
        items = found
        loadedAt = .now
        AppLogger.appModel.info("On This Device: \(found.count, privacy: .public) items")
    }

    /// Server pictures whose full size the cache still has; the rest are forgotten.
    private func cachedServerPictures() async -> [OfflineItem] {
        var result: [OfflineItem] = []
        var gone: [String] = []
        for record in pictures.values {
            guard let url = await DiskImageCache.shared.cachedFileURL(for: record.image.fullSizeURL) else {
                gone.append(record.id)
                continue
            }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            result.append(OfflineItem(
                id: "picture:" + record.id, type: .pictures,
                title: record.image.title ?? record.image.fileName ?? "Picture",
                subtitle: record.image.source.rawValue.capitalized,
                date: record.lastSeen, bytes: bytes, payload: .picture(record.image)))
        }
        if !gone.isEmpty {
            for id in gone { pictures[id] = nil }
            scheduleSave()
        }
        return result
    }

    private func localPictures() async -> [OfflineItem] {
        let files = await LocalMediaSource.shared.scanImages()
        return files.map { file in
            OfflineItem(
                id: "local-picture:" + file.url.path, type: .pictures, title: file.name, subtitle: "On This Device",
                date: file.modifiedDate, bytes: file.fileSize,
                payload: .picture(GalleryImage(thumbnailURL: file.url, fullSizeURL: file.url, title: file.name, source: .local)))
        }
    }

    private func localVideos() async -> [OfflineItem] {
        let files = await LocalMediaSource.shared.scanVideos()
        let sizes = Dictionary(files.map { ($0.url.path, ($0.modifiedDate, $0.fileSize)) }, uniquingKeysWith: { first, _ in first })
        guard let result = try? await LocalVideoSource().fetchVideos(page: 0, pageSize: files.count + 1) else { return [] }
        return result.videos.compactMap { video in
            // The Library's downloads sit in Documents/Videos/Jellyfin and are Films & Shows.
            guard !video.streamURL.path.contains("/Videos/Jellyfin/") else { return nil }
            let info = sizes[video.streamURL.path]
            return OfflineItem(
                id: "local-video:" + video.identity, type: .videos, title: video.title ?? video.streamURL.lastPathComponent,
                subtitle: "On This Device", date: info?.0 ?? .distantPast, bytes: info?.1 ?? 0, payload: .video(video))
        }
    }

    private func filmDownloads() -> [OfflineItem] {
        LibraryOfflineStore.shared.records.map { record in
            let item = record.displayItem
            let subtitle: String?
            if item.kind == .episode {
                subtitle = [record.series?.title ?? item.seriesName, item.year.map(String.init)]
                    .compactMap { $0 }.joined(separator: " · ")
            } else {
                subtitle = item.year.map(String.init)
            }
            return OfflineItem(
                id: "film:" + record.id, type: .films, title: item.title, subtitle: subtitle,
                date: record.downloadedAt, bytes: record.bytes, payload: .film(item))
        }
    }

    #if HYPNOS_GEN3D && os(visionOS)
    private func models() -> [OfflineItem] {
        Gen3DLibrary.shared.refresh()
        return Gen3DLibrary.shared.items.map { item in
            OfflineItem(
                id: "model:" + item.id, type: .models, title: item.title, subtitle: item.record.engine,
                date: item.record.lastOpened, bytes: item.bytes, payload: .model(item))
        }
    }
    #endif
}
