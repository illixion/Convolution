/*
 Hypnos - shared Continue Watching snapshot for the tvOS Top Shelf extension

 The app owns Jellyfin authentication and refreshes this small, artwork-only
 snapshot when Library home loads. The extension reads it without credentials
 or network access, so it can render instantly and work while the server is
 offline.
 */

#if os(tvOS)

import CryptoKit
import Foundation
import TVServices

enum TVTopShelfCache {
    static let appGroup = "group.com.illixion.hypnos"
    private static let folderName = "TopShelf"

    struct Entry: Codable {
        var id: String
        var title: String
        var subtitle: String
        var progress: Double
        var imageName: String
    }

    private struct Snapshot: Codable {
        var entries: [Entry]
    }

    @MainActor
    static func refreshFromLibrary() async {
        guard let library = LibraryService.current(),
              let home = try? await library.home()
        else { return }
        let items = home.shelves.first(where: { $0.id == "up-next" })?.items ?? []
        await refresh(items: items, library: library)
    }

    static func refresh(items: [LibraryItem], library: JellyfinLibrary) async {
        guard let directory = cacheDirectory() else { return }
        let resumable = Array(items.filter { $0.userData.resumeSeconds != nil }.prefix(12))
        var entries: [Entry] = []

        for item in resumable {
            let artwork = item.image(.thumb) ?? item.image(.backdrop) ?? item.image(.primary)
            guard let artwork else { continue }
            let ownerID = artwork.ownerId ?? item.id
            let imageName = "\(stableName(for: item.id + (artwork.tag ?? ""))).jpg"
            let imageURL = directory.appending(path: imageName)
            if !FileManager.default.fileExists(atPath: imageURL.path) {
                do {
                    let data = try await library.artworkData(ownerId: ownerID, kind: artwork.kind)
                    try data.write(to: imageURL, options: .atomic)
                } catch {
                    continue
                }
            }

            let episode = item.episodeLabel.map { "\($0) · " } ?? ""
            let series = item.seriesName.map { "\($0) · " } ?? ""
            let subtitle = series + episode + item.title
            let percentage = item.runtimeSeconds.flatMap { runtime in
                guard runtime > 0 else { return nil }
                return item.userData.resumeSeconds.map { min(1, max(0, $0 / runtime)) }
            } ?? ((item.userData.playedPercentage ?? 0) / 100)
            entries.append(Entry(id: item.id, title: item.title, subtitle: subtitle,
                                 progress: min(1, max(0, percentage)), imageName: imageName))
        }

        let retainedImages = Set(entries.map(\.imageName))
        if let cachedFiles = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in cachedFiles where file.pathExtension == "jpg" && !retainedImages.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        do {
            let data = try JSONEncoder().encode(Snapshot(entries: entries))
            try data.write(to: directory.appending(path: "continue-watching.json"), options: .atomic)
            TVTopShelfContentProvider.topShelfContentDidChange()
        } catch {
            // Top Shelf data is optional presentation cache; Library playback remains unaffected.
        }
    }

    private static func cacheDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let directory = container.appending(path: folderName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func stableName(for id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

}

#endif
