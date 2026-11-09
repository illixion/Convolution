/*
 Hypnos - what the YouTube tab currently offers its ornament (sideload builds only: `HYPNOS_YOUTUBE`)

 The tab's Hide Watched button lives in the visionOS tab-bar ornament, which
 is outside the tab's view tree, and appears only while the list on screen is
 one the filter applies to (search results, Home, Subscriptions, Watch Later;
 not History or Watched, which are what was watched). The tab publishes that
 here.
 */

#if HYPNOS_YOUTUBE

import Observation

@MainActor @Observable
final class YouTubeFilterOffer {
    static let shared = YouTubeFilterOffer()

    /// Whether the list on screen is one Hide Watched applies to.
    var offersHideWatched = false
}

#endif
