/*
 Hypnos - YouTube: the one-time approval (sideload builds only: `HYPNOS_YOUTUBE`)

 Everything YouTube does talks to services outside the user's own servers:
 YouTube's player API, search and site (Google), its thumbnail CDN, and
 SponsorBlock for skip segments. None of it may happen until the person has
 said yes once, on the YouTube tab's wall (`YouTubeConsentWall`). The answer
 is kept, so the feature stays on from then on. There is deliberately no off
 switch: nothing is sent unless the person uses the tab or opens a YouTube
 link.

 The wall is the visible gate; the services check `isGranted` themselves
 too (`YouTubeInnertube`, the hidden and visible pages, SponsorBlock,
 `YouTubeResolver`), so a path that isn't the tab, such as a shared
 `hypnos://play` YouTube link or a restored video window, can't reach out
 either. The user's own web-yt-dlp backend is not gated: it is theirs.
 */

#if HYPNOS_YOUTUBE

import Foundation

enum YouTubeConsent {
    static let defaultsKey = "youtube.consentGranted"

    static var isGranted: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Throws what the person sees when something asks for YouTube before
    /// it is turned on.
    static func require() throws {
        guard isGranted else { throw NotGranted() }
    }

    struct NotGranted: LocalizedError {
        var errorDescription: String? {
            "YouTube is turned off. Turn it on in the YouTube tab to play YouTube videos."
        }
    }
}

#endif
