/*
 Hypnos - Media quick actions

 What a thumbnail's long-press (right-click on macOS) context menu can do to
 one picture or video without opening it: the Info sheet, a rating, Share,
 and Delete behind the same confirmation the viewer and bulk delete use.

 A grid owns one `MediaQuickActions` (`@State`) and applies
 `.mediaQuickActions(_:)` once; each cell's menu only records what it wants
 (`showInfo`, `confirmDelete`), and the grid presents it. A menu can't host a
 sheet or a dialog itself: it is gone by the time either would appear.

 What Delete means depends on where the item lives (`MediaDeletion`):
 - Stash: "Remove from Stash" or "Delete File from Disk", the same two choices
   `MediaDetailSheet` and the bulk-delete bar offer.
 - Photos library: delete the asset. PhotoKit asks in its own alert, so
   there is no second confirmation here.
 - Local (the app's Documents folder): delete the file.
 Nextcloud and share-sheet media have nothing to delete from here, so their
 menus offer no Delete at all. Neither does anything on tvOS: a TV has no
 lock screen, so whoever holds the remote could otherwise delete the library.
 */

import DebugTrace
import Photos
import SwiftUI

// MARK: - Deletion

/// Where a picture or video can be deleted from, which decides the
/// confirmation's buttons.
enum MediaDeletion: Equatable {
    case stash(id: String)
    case photosLibrary(localIdentifier: String)
    case localFile(URL)

    /// Nothing can be deleted from a TV: it has no lock screen, so anyone
    /// holding the remote would be able to delete the library's media.
    static var isAvailable: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    static func forImage(_ image: GalleryImage) -> MediaDeletion? {
        guard isAvailable else { return nil }
        if let id = image.stashId, !id.isEmpty { return .stash(id: id) }
        return forURL(image.fullSizeURL, isLocal: image.source == .local)
    }

    static func forVideo(_ video: GalleryVideo) -> MediaDeletion? {
        guard isAvailable else { return nil }
        if let id = video.stashId, !id.isEmpty { return .stash(id: id) }
        return forURL(video.streamURL, isLocal: isInLocalLibrary(video.streamURL))
    }

    private static func forURL(_ url: URL, isLocal: Bool) -> MediaDeletion? {
        #if !os(tvOS)
        if let id = PhotosAssetURL.localIdentifier(from: url) { return .photosLibrary(localIdentifier: id) }
        #endif
        if url.isFileURL, isLocal { return .localFile(url) }
        return nil
    }

    /// A video carries no `MediaSource`; one inside the Local library's roots
    /// is the user's own file, unlike share-sheet media in the cache.
    private static func isInLocalLibrary(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        return [LocalMediaSource.photosDirectory, LocalMediaSource.videosDirectory]
            .contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }
}

// MARK: - Targets

/// One picture or video a menu acted on.
enum MediaQuickActionTarget: Identifiable {
    case image(GalleryImage)
    case video(GalleryVideo)

    var id: UUID {
        switch self {
        case .image(let image): return image.id
        case .video(let video): return video.id
        }
    }

    var displayName: String {
        // Stash sends "" rather than nil for an untitled item.
        let candidates: [String?]
        switch self {
        case .image(let image):
            candidates = [image.title, image.fileName, image.fullSizeURL.deletingPathExtension().lastPathComponent]
        case .video(let video):
            candidates = [video.title, video.fileName, video.streamURL.deletingPathExtension().lastPathComponent]
        }
        return candidates.compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled"
    }

    var deletion: MediaDeletion? {
        switch self {
        case .image(let image): return .forImage(image)
        case .video(let video): return .forVideo(video)
        }
    }

    var stashId: String? {
        switch self {
        case .image(let image): return image.stashId
        case .video(let video): return video.stashId
        }
    }

    var identity: String {
        switch self {
        case .image(let image): return image.identity
        case .video(let video): return video.identity
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}

// MARK: - Model

@MainActor
@Observable
final class MediaQuickActions {
    /// The item whose Info sheet is up.
    var infoTarget: MediaQuickActionTarget?
    /// The item awaiting delete confirmation.
    var deleteTarget: MediaQuickActionTarget?
    /// Called after a delete lands, for a view that lists items itself rather
    /// than through `AppModel`'s gallery arrays (the Local folder browser).
    @ObservationIgnored var onDeleted: ((MediaQuickActionTarget) -> Void)?

    func showInfo(_ target: MediaQuickActionTarget) {
        guard target.stashId != nil else { return }
        infoTarget = target
    }

    func confirmDelete(_ target: MediaQuickActionTarget, appModel: AppModel) {
        switch target.deletion {
        case nil:
            return
        case .photosLibrary:
            // PhotoKit shows its own confirmation; a second one here first
            // would ask twice.
            Task { await delete(target, deleteFile: true, appModel: appModel) }
        case .stash, .localFile:
            deleteTarget = target
        }
    }

    /// Deletes `target` and drops it from the app's lists. `deleteFile` only
    /// matters for Stash, where the alternative is removing the entry alone.
    func delete(_ target: MediaQuickActionTarget, deleteFile: Bool, appModel: AppModel) async {
        guard let deletion = target.deletion else { return }
        do {
            switch deletion {
            case .stash(let id):
                if target.isVideo {
                    try await appModel.apiClient.destroyScene(id: id, deleteFile: deleteFile)
                } else {
                    try await appModel.apiClient.destroyImage(id: id, deleteFile: deleteFile)
                }
            case .photosLibrary(let localIdentifier):
                #if !os(tvOS)
                try await PHPhotoLibrary.shared().performChanges {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
                    PHAssetChangeRequest.deleteAssets(assets)
                }
                #endif
            case .localFile(let url):
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            // Includes the user declining PhotoKit's own confirmation.
            AppLogger.views.error("Quick delete failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return
        }
        appModel.removeQuickActionTarget(target)
        onDeleted?(target)
    }

    /// Sets a Stash rating from a menu and mirrors it into the gallery.
    func setRating(_ rating100: Int?, for target: MediaQuickActionTarget, appModel: AppModel) async {
        guard let id = target.stashId else { return }
        do {
            if target.isVideo {
                try await appModel.apiClient.updateSceneRating(sceneId: id, rating100: rating100)
                appModel.applyVideoRating(rating100, identity: target.identity)
            } else {
                try await appModel.updateImageRating(stashId: id, rating100: rating100)
            }
        } catch {
            AppLogger.views.error("Quick rating failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }
}

extension AppModel {
    /// Drops a deleted item from the gallery arrays and any selection.
    func removeQuickActionTarget(_ target: MediaQuickActionTarget) {
        let identity = target.identity
        switch target {
        case .image:
            galleryImages.removeAll { $0.identity == identity }
            if let id = target.stashId { selectedImageIds.remove(id) }
        case .video:
            galleryVideos.removeAll { $0.identity == identity }
            if let id = target.stashId { selectedVideoIds.remove(id) }
        }
    }

    func applyVideoRating(_ rating100: Int?, identity: String) {
        if let index = galleryVideos.firstIndex(where: { $0.identity == identity }) {
            galleryVideos[index].rating100 = rating100
        }
    }

    func applyImageRating(_ rating100: Int?, identity: String) {
        if let index = galleryImages.firstIndex(where: { $0.identity == identity }) {
            galleryImages[index].rating100 = rating100
        }
    }
}

// MARK: - Presentation

extension View {
    /// Hosts the Info sheet and delete confirmation that `actions`' menus ask for.
    func mediaQuickActions(_ actions: MediaQuickActions) -> some View {
        modifier(MediaQuickActionsPresenter(actions: actions))
    }
}

private struct MediaQuickActionsPresenter: ViewModifier {
    @Bindable var actions: MediaQuickActions
    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.infoTarget) { target in
                if let id = target.stashId {
                    MediaDetailSheet(
                        mediaType: target.isVideo ? .scene(stashId: id) : .image(stashId: id),
                        onDelete: { appModel.removeQuickActionTarget(target) },
                        onSaved: { rating in
                            if target.isVideo {
                                appModel.applyVideoRating(rating, identity: target.identity)
                            } else {
                                appModel.applyImageRating(rating, identity: target.identity)
                            }
                        }
                    )
                }
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: Binding(get: { actions.deleteTarget != nil },
                                     set: { if !$0 { actions.deleteTarget = nil } }),
                titleVisibility: .visible,
                presenting: actions.deleteTarget
            ) { target in
                switch target.deletion {
                case .stash:
                    Button("Remove from Stash", role: .destructive) { delete(target, deleteFile: false) }
                    Button("Delete File from Disk", role: .destructive) { delete(target, deleteFile: true) }
                case .localFile:
                    Button("Delete File", role: .destructive) { delete(target, deleteFile: true) }
                case .photosLibrary, nil:
                    EmptyView()
                }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                switch target.deletion {
                case .stash:
                    Text("Removing keeps the file on the server's disk.")
                case .localFile, .photosLibrary, nil:
                    Text("This can't be undone.")
                }
            }
    }

    private var deleteTitle: String {
        guard let target = actions.deleteTarget else { return "" }
        return "Delete “\(target.displayName)”?"
    }

    private func delete(_ target: MediaQuickActionTarget, deleteFile: Bool) {
        Task { await actions.delete(target, deleteFile: deleteFile, appModel: appModel) }
    }
}

// MARK: - Menu items

/// The menu's shared tail for one picture or video: Info, rating, Share,
/// Select and Delete, each only where the item's source supports it.
struct MediaQuickActionMenuItems: View {
    let target: MediaQuickActionTarget
    let actions: MediaQuickActions
    /// Enters multi-select with this item selected; nil where the grid has no
    /// selection mode.
    var onSelect: (() -> Void)? = nil
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if target.stashId != nil {
            Section {
                Button("Info", systemImage: "info.circle") { actions.showInfo(target) }
                ratingMenu
            }
        }
        #if !os(tvOS)
        if let shareURL {
            ShareLink(item: shareURL)
        }
        #endif
        if let onSelect, target.stashId != nil {
            Button("Select", systemImage: "checkmark.circle", action: onSelect)
        }
        if target.deletion != nil {
            Section {
                Button("Delete…", systemImage: "trash", role: .destructive) { actions.confirmDelete(target, appModel: appModel) }
            }
        }
    }

    /// Stash ratings are 0–100 in steps of 20 for five stars.
    private var ratingMenu: some View {
        Picker(selection: Binding(
            get: { currentStars },
            set: { stars in
                Task { await actions.setRating(stars == 0 ? nil : stars * 20, for: target, appModel: appModel) }
            }
        )) {
            Text("No Rating").tag(0)
            ForEach(1...5, id: \.self) { stars in
                Text(String(repeating: "★", count: stars)).tag(stars)
            }
        } label: {
            Label("Rating", systemImage: "star")
        }
        .pickerStyle(.menu)
    }

    /// Reads the gallery's copy, which a rating set here updates.
    private var currentStars: Int {
        let identity = target.identity
        let rating: Int?
        switch target {
        case .image(let image):
            rating = appModel.galleryImages.first { $0.identity == identity }?.rating100 ?? image.rating100
        case .video(let video):
            rating = appModel.galleryVideos.first { $0.identity == identity }?.rating100 ?? video.rating100
        }
        return Int(((Double(rating ?? 0)) / 20).rounded())
    }

    /// Only files already on this device; a remote original would have to be
    /// downloaded first, which the viewer's Share button does.
    private var shareURL: URL? {
        let url: URL
        switch target {
        case .image(let image): url = image.fullSizeURL
        case .video(let video): url = video.streamURL
        }
        return url.isFileURL ? url : nil
    }
}
