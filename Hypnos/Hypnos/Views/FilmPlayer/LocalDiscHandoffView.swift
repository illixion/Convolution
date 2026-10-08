/*
 Hypnos - a Blu-ray disc on the device opens in the film player

 A disc image (.iso) in the Local library, or opened from Files, arrives
 as an ordinary video, so it would land in a video window, whose players
 can't read a disc. Each platform's video window root shows this instead:
 it loads the disc into the film player (`FilmSession.loadLocalDisc`: the
 picture decoded on the device, the disc's own 5.1 as sound), opens the
 film player window and closes itself.
 */

import RAVEFilm
import SwiftUI

extension GalleryVideo {
    /// A Blu-ray disc image on the device.
    var isLocalDisc: Bool {
        streamURL.isFileURL && streamURL.pathExtension.lowercased() == "iso"
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
                ProgressView("Opening disc…")
            }
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 200)
        .task {
            let session = FilmSession.shared
            let title = video.title ?? video.streamURL.deletingPathExtension().lastPathComponent
            guard await session.loadLocalDisc(video.streamURL, title: title) else {
                failure = session.error ?? "The disc couldn't be read."
                return
            }
            session.player.play()
            openWindow(id: FilmPlayerView.windowID)
            dismissWindow()
        }
    }
}
