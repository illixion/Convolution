/*
 Hypnos - Library feature: Skip Intro / Skip Credits

 One per player. Loads a Library title's media segments
 (`MediaServerLibrary.mediaSegments`) and answers which one the playhead is
 in, so every player (the video window, the object-audio film player, the
 tvOS and Mac system players) offers the same skip button off the same
 rules:

 - The button shows by itself for the first few seconds of a segment, the
   way Infuse and the Apple TV app offer it, then only while the player's
   controls are up, so a viewer who let the intro run isn't stared at by it.
 - A skip lands half a second before the end of the title at the latest:
   skipping end credits lets the title finish on its own, so the next
   episode autoplays exactly as if the credits had run out.
 */

import DebugTrace
import Foundation
import Observation
import RAVEUI
import SwiftUI

@MainActor
@Observable
final class MediaSegmentSkipper {
    private(set) var segments: [LibraryMediaSegment] = []
    @ObservationIgnored private var loadedItemId: String?

    /// How long a segment's button shows without the controls.
    static let promptSeconds = LibrarySegmentSkipPolicy.promptSeconds

    /// Loads the segments for whatever a player is showing: a Library
    /// title's intro/credits, or (sideload builds) a YouTube video's
    /// SponsorBlock segments. Anything else has none.
    func load(videoIdentity: String) async {
        #if HYPNOS_YOUTUBE
        if let id = YouTubeVideoID(videoIdentity: videoIdentity) {
            await loadSponsorBlock(id)
            return
        }
        #endif
        await load(itemId: LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: videoIdentity))
    }

    /// Loads `itemId`'s segments, or clears them for nil (not a Library title).
    func load(itemId: String?) async {
        guard itemId != loadedItemId else { return }
        loadedItemId = itemId
        segments = []
        guard let itemId, let library = LibraryService.current() else { return }
        let loaded = (try? await library.mediaSegments(itemId: itemId)) ?? []
        guard loadedItemId == itemId else { return }
        segments = loaded.filter(LibrarySegmentSkipPolicy.eligible)
        if !segments.isEmpty {
            AppLogger.library.info("Skippable segments: \(self.segments.map { "\($0.kind.rawValue) \(Int($0.startSeconds))-\(Int($0.endSeconds))" }.joined(separator: ", "), privacy: .public)")
        }
    }

    #if HYPNOS_YOUTUBE
    /// Segments that skip by themselves, with what the notice calls them.
    @ObservationIgnored private var autoSkipLabels: [LibraryMediaSegment: String] = [:]
    /// Each auto-skip fires once: a viewer who scrubs back into one wants
    /// to watch it.
    @ObservationIgnored private var autoSkipped: Set<LibraryMediaSegment> = []

    private func loadSponsorBlock(_ id: YouTubeVideoID) async {
        let key = id.videoIdentity
        guard key != loadedItemId else { return }
        loadedItemId = key
        segments = []
        autoSkipLabels = [:]
        autoSkipped = []
        let loaded = await SponsorBlock.segments(for: id)
        guard loadedItemId == key else { return }
        segments = loaded.map(\.librarySegment).filter(LibrarySegmentSkipPolicy.eligible)
        for segment in loaded where segment.category.mode == .auto {
            autoSkipLabels[segment.librarySegment] = segment.category.displayName.lowercased()
        }
        if !loaded.isEmpty {
            AppLogger.youtube.info("SponsorBlock: \(loaded.map { "\($0.category.rawValue) \(Int($0.start))-\(Int($0.end))" }.joined(separator: ", "), privacy: .public)")
        }
    }

    /// The auto-skip segment `time` has just entered, marked as skipped.
    func autoSkip(at time: Double) -> (segment: LibraryMediaSegment, label: String)? {
        guard !autoSkipLabels.isEmpty, time.isFinite else { return nil }
        guard let hit = autoSkipLabels.first(where: { segment, _ in
            !autoSkipped.contains(segment) && time >= segment.startSeconds && time < segment.endSeconds - 0.3
        }) else { return nil }
        autoSkipped.insert(hit.key)
        return (hit.key, hit.value)
    }
    #endif

    /// The segment `time` is in, if a skip would still save something.
    func segment(at time: Double) -> LibraryMediaSegment? {
        LibrarySegmentSkipPolicy.segment(at: time, in: segments)
    }

    /// The segment to offer a skip for: within its first seconds always,
    /// later only with the controls up.
    func offered(at time: Double, controlsVisible: Bool) -> LibraryMediaSegment? {
        LibrarySegmentSkipPolicy.offered(at: time, controlsVisible: controlsVisible, in: segments)
    }

    /// Where skipping `segment` lands.
    nonisolated static func target(for segment: LibraryMediaSegment, duration: Double) -> Double {
        LibrarySegmentSkipPolicy.target(for: segment, duration: duration)
    }
}

/// The skip button: a solid capsule that reads over any picture.
struct SkipSegmentButton: View {
    let segment: LibraryMediaSegment
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(segment.skipTitle, systemImage: "forward.end.fill")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        #if os(visionOS)
        .buttonStyle(.borderedProminent)
        #elseif os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(.black)
        #endif
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .accessibilityIdentifier("player.skipSegment")
    }
}
