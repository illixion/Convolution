/*
 Hypnos - Film Player tuning (Settings → Developer)

 The server address, sign-in and film search that used to live here moved to
 `JellyfinServerSection` (server config) and the Library tab (browsing and
 opening a film) once those existed — see decision #3 in the Library
 feature's brief: "the Film Player tuning controls that live in
 FilmPlayerSection should move somewhere sensible... don't lose them." What's
 left is exactly that: the listener-distance/map tuning
 (`FilmTuning`/`FilmTelemetry`) for whichever film the Library tab has open,
 plus a manual Open/Close in case a window needs recovering. `FilmSession`
 itself (the loaded item, the player) is unchanged — this view just no
 longer decides what gets loaded into it.
 */

import RAVEFilm
import SwiftUI

struct FilmPlayerSection: View {
    @Bindable private var session = FilmSession.shared
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow

    var body: some View {
        Section("Film Player Tuning") {
            if let item = session.loadedItem {
                HStack {
                    Text(item.name)
                    Spacer()
                    Button {
                        session.isPlayerOpen ? closePlayer() : openPlayer()
                    } label: {
                        Label(session.isPlayerOpen ? "Close Player" : "Open Player",
                              systemImage: session.isPlayerOpen ? "xmark.circle" : "play.rectangle")
                    }
                }

                #if os(visionOS)
                if session.isPlayerOpen {
                    FilmTuning()
                    FilmTelemetry(player: session.player)
                }
                #endif
            } else {
                Text("Play a film from the Library tab to tune it here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = session.error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            Text("Plays the film's picture (HDR through the system decoder) with its sound objects as spatial sources in a virtual room around you, the screen as its front wall, on one clock. Needs the Hypnos Object Audio plugin on the Jellyfin server; films without object audio play through the Library's own generic player instead.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func openPlayer() {
        openWindow(id: FilmPlayerView.windowID)
    }

    private func closePlayer() {
        dismissWindow(id: FilmPlayerView.windowID)
    }
}
