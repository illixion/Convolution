import Foundation
import TVServices

@objc(TopShelfContentProvider)
final class TopShelfContentProvider: TVTopShelfContentProvider {
    private let appGroup = "group.com.illixion.hypnos"

    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            completionHandler(nil)
            return
        }
        let directory = container.appending(path: "TopShelf", directoryHint: .isDirectory)
        let snapshotURL = directory.appending(path: "continue-watching.json")
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.entries.isEmpty else {
            completionHandler(nil)
            return
        }

        let items = snapshot.entries.compactMap { entry -> TVTopShelfSectionedItem? in
            let imageURL = directory.appending(path: entry.imageName)
            guard FileManager.default.fileExists(atPath: imageURL.path) else { return nil }

            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.imageShape = .hdtv
            item.title = entry.displayTitle
            item.playbackProgress = entry.progress
            item.setImageURL(imageURL, for: .screenScale1x)
            item.setImageURL(imageURL, for: .screenScale2x)

            var components = URLComponents()
            components.scheme = "hypnos"
            components.host = "library-play"
            components.queryItems = [URLQueryItem(name: "id", value: entry.id)]
            if let url = components.url {
                let action = TVTopShelfAction(url: url)
                item.playAction = action
                item.displayAction = action
            }
            return item
        }

        guard !items.isEmpty else {
            completionHandler(nil)
            return
        }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "Continue Watching"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }

    private struct Snapshot: Decodable {
        var entries: [Entry]
    }

    private struct Entry: Decodable {
        var id: String
        var title: String
        var subtitle: String
        var progress: Double
        var imageName: String

        var displayTitle: String {
            subtitle.isEmpty ? title : subtitle
        }
    }
}
