/*
 Hypnos - music playback: joins and crossfades through the real session and engine (macOS, DEBUG only)

 Launch the macOS build against the disposable dev Jellyfin, with its music from `scripts/gen-dev-music.py`
 (it needs the continuous "Unbroken Line" and "Night Drive Mix" albums and an ordinary one):

   HYPNOS_DEV_JELLYFIN_SIGNIN_USER=dev HYPNOS_DEV_JELLYFIN_SIGNIN_PASS=dev12345 \
     Hypnos.app/Contents/MacOS/Hypnos -MusicPlaybackHarness -UITest \
     -UITestDefault filmPlayer.jellyfinServer=http://127.0.0.1:8097

 With Crossfade at 6 s and "Unless the Album Is Seamless", it plays (muted) the end of an ordinary album's first
 song and of each continuous album's first song, and checks that the seam detector told them apart, that the ordinary
 one handed over when its fade began (6 s before the end) and the continuous one exactly at its end. Prints
 `HARNESS:` lines and exits. Puts the crossfade settings back as found.
 */

#if DEBUG && os(macOS)

import Foundation

@MainActor
enum MusicPlaybackHarness {
    private static var failures = 0

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-MusicPlaybackHarness") else { return }
        Task { @MainActor in
            await run()
            print("HARNESS: \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("HARNESS: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        fflush(stdout)
    }

    private static func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func run() async {
        // The dev sign-in runs beside the launch and replaces any saved token a moment in: let it land first.
        try? await Task.sleep(for: .seconds(3))
        guard await wait(20, until: { JellyfinAuth.shared.session != nil }), let library = LibraryService.current() else {
            check("signed in to the dev Jellyfin", false); return
        }
        let albums: [JellyfinMusicItem]
        do { albums = try await library.musicPage(MusicRequest(section: .albums), start: 0, limit: 200).Items } catch {
            check("albums load", false, "\(error)"); return
        }
        guard let continuous = albums.first(where: { $0.Name == "Unbroken Line" }),
              let mix = albums.first(where: { $0.Name == "Night Drive Mix" }),
              let ordinary = albums.first(where: { $0.Name != "Unbroken Line" && $0.Name != "Night Drive Mix" && ($0.ChildCount ?? 0) >= 3 })
        else { check("the dev library has Unbroken Line and an ordinary album (scripts/gen-dev-music.py)", false); return }

        let music = JellyfinMusicSession.shared
        let saved = (music.crossfadeSeconds, music.albumCrossfade)
        music.setCrossfadeSeconds(6)
        music.setAlbumCrossfade(.unlessSeamless)
        defer { music.setCrossfadeSeconds(saved.0); music.setAlbumCrossfade(saved.1); music.stop() }

        // Night Drive Mix is AAC whose index follows its audio: played once the whole file is on the device.
        for (album, fades) in [(ordinary, true), (continuous, false), (mix, false)] {
            guard let songs = try? await library.musicPage(MusicRequest(section: .songs, albumID: album.id), start: 0, limit: 10).Items,
                  songs.count >= 2 else { check("\(album.Name) has songs", false); continue }
            music.play(songs[0], from: songs)
            if !music.isMuted { music.toggleMute() }
            let expected: MusicTimeline.Transition = fades ? .crossfade(seconds: 6) : .gapless
            // The seam is measured once both files are on the device; until then the plan is gapless.
            let measured = await wait(30) {
                MusicSeams.shared.known(songs[0].Id) != nil && MusicSeams.shared.known(songs[1].Id) != nil
                    && music.upcomingTransition == expected && music.currentTime > 0.3
            }
            let edges = [songs[0], songs[1]].map { MusicSeams.shared.known($0.Id).map { String(format: "%.0f/%.0f dB", $0.head, $0.tail) } ?? "?" }
            check("\(album.Name): the seam is heard as \(fades ? "separate" : "continuous") and planned as \(expected)", measured,
                  "planned \(String(describing: music.upcomingTransition)), edges \(edges)")
            // Jump to 9 s before the end; the next song is heard 3 s later (crossfade) or 9 s later (gapless).
            let length = music.duration
            music.seek(to: length - 9)
            let from = Date()
            let advanced = await wait(15) { music.current?.Id == songs[1].Id }
            let took = Date().timeIntervalSince(from)
            let target = fades ? 3.0 : 9.0
            check("\(album.Name): the next song takes over \(fades ? "as the fade begins" : "at the end")",
                  advanced && abs(took - target) < 0.6, String(format: "after %.2f s, expected %.1f s (song %.3f s)", took, target, length))
            if !fades {
                check("\(album.Name) is remembered as a seamless album", MusicSeams.shared.seamlessAlbums.contains(album.id))
            }
            music.stop()
        }
    }
}

#endif
