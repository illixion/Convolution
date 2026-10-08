/*
 Hypnos - a Blu-ray disc on the device opens in the film player

 A disc image (.iso) in the Local library, or opened from Files, arrives
 as an ordinary video, so it would land in a video window, whose players
 can't read a disc. Each platform's video window root shows this instead:
 it loads the disc into the film player (`FilmSession.loadLocalDisc`: the
 picture decoded on the device, the disc's own 5.1 as sound), opens the
 film player window and closes itself.

 A Library download that plays in the film player (an object-audio film,
 whose MP4 in Files is its video alone, or a disc) is handed over the same
 way, so opening it from the Local library keeps its object audio.
 */

import RAVEFilm
import SwiftUI

extension GalleryVideo {
    /// A Blu-ray disc image on the device, or a Library download that
    /// plays in the film player.
    var opensInFilmPlayer: Bool {
        guard streamURL.isFileURL else { return false }
        return streamURL.pathExtension.lowercased() == "iso" || filmDownload != nil
    }

    /// The Library download this local file is, when it plays in the film player.
    var filmDownload: LibraryOfflineRecord? {
        guard streamURL.isFileURL else { return nil }
        let path = streamURL.standardizedFileURL.path
        return LibraryOfflineStore.shared.records.first {
            $0.playback != .video && LibraryOfflineStore.mediaURL($0).standardizedFileURL.path == path
        }
    }
}

struct LocalDiscHandoffView: View {
    let video: GalleryVideo
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 16) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .multilineTextAlignment(.center)
                Button("Close") { dismissWindow() }
            } else {
                ProgressView(video.filmDownload == nil ? "Opening disc…" : "Opening…")
            }
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 200)
        .task {
            let session = FilmSession.shared
            let title = video.title ?? video.streamURL.deletingPathExtension().lastPathComponent
            let loaded = if let download = video.filmDownload {
                await session.load(itemId: download.id, name: download.item.title, productionYear: download.item.year,
                                   isBlurayDisc: download.playback == .disc)
            } else {
                await session.loadLocalDisc(video.streamURL, title: title)
            }
            guard loaded else {
                failure = session.error ?? "The disc couldn't be read."
                return
            }
            session.player.play()
            openWindow(id: FilmPlayerView.windowID)
            dismissWindow()
        }
    }
}
