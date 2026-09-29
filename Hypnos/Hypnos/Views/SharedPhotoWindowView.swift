/*
 Hypnos - Shared Photo Window View

 Pop-out viewer for images received via the system share sheet.
 Uses PhotoDisplayView for rendering and PhotoOrnamentView for controls.
 Includes a Save button to persist the image to Documents/Photos/.
 */

import DebugTrace
import SwiftUI

struct SharedPhotoWindowView: View {
    let item: SharedMediaItem
    @State private var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @OpenWindowProxy private var openWindow

    @State private var isSaving = false
    @State private var isSaved = false
    @State private var saveError: String?

    init(item: SharedMediaItem, appModel: AppModel) {
        self.item = item
        _windowModel = State(initialValue: PhotoWindowModel(image: item.asGalleryImage(), appModel: appModel))
    }

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: item.cachedFileURL.path) {
                PhotoDisplayView(windowModel: windowModel, enableSwipeNavigation: false)
            } else {
                unavailableContent
            }
        }
        .opacity(appModel.allWindowsHidden ? 0 : 1)
        .persistentSystemOverlays(windowModel.isWindowControlsHidden ? .hidden : .visible)
        .hidesStatusBar(windowModel.isUIHidden)
        .ornament(
            visibility: windowModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            contentAlignment: .top,
            ornament: {
                PhotoOrnamentView(
                    windowModel: windowModel,
                    context: .shared,
                    onGalleryButtonTap: {
                        appModel.showMainWindow(openWindow: openWindow)
                    },
                    extraMenuItems: {
                        Button(action: savePhoto) {
                            Label(
                                isSaved ? "Saved" : (saveError != nil ? "Save Failed" : "Save to Files"),
                                systemImage: isSaved ? "checkmark" : (saveError != nil ? "exclamationmark.triangle" : "square.and.arrow.down")
                            )
                        }
                        .disabled(isSaving || isSaved)
                    }
                )
                .offset(z: windowModel.isDioramaMode ? 30 : 0)
            }
        )
        .onAppear {
            windowModel.start()
            windowModel.startAutoHideTimer()
        }
        .onDisappear {
            windowModel.cleanup()
            Task {
                await SharedMediaCache.shared.removeCachedFile(for: item.id)
            }
        }
    }

    // MARK: - Unavailable Content

    private var unavailableContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("Shared photo is no longer available")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("The temporary cache was cleared.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Save

    private func savePhoto() {
        guard !isSaving && !isSaved else { return }
        isSaving = true
        saveError = nil

        Task {
            do {
                _ = try SharedMediaSaver.saveImage(
                    from: item.cachedFileURL,
                    originalFileName: item.originalFileName
                )
                isSaved = true
            } catch {
                saveError = error.localizedDescription
                AppLogger.sharedMedia.error("Failed to save shared photo: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
            isSaving = false
        }
    }
}
