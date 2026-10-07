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
import SwiftUI

@MainActor
@Observable
final class MediaSegmentSkipper {
    private(set) var segments: [LibraryMediaSegment] = []
    @ObservationIgnored private var loadedItemId: String?

    /// How long a segment's button shows without the controls.
    static let promptSeconds: Double = 8
    /// Shorter segments aren't worth a button that would vanish as it appears.
    private static let minimumLength: Double = 4

    /// Loads `itemId`'s segments, or clears them for nil (not a Library title).
    func load(itemId: String?) async {
        guard itemId != loadedItemId else { return }
        loadedItemId = itemId
        segments = []
        guard let itemId, let library = LibraryService.current() else { return }
        let loaded = (try? await library.mediaSegments(itemId: itemId)) ?? []
        guard loadedItemId == itemId else { return }
        segments = loaded.filter { $0.endSeconds - $0.startSeconds >= Self.minimumLength }
        if !segments.isEmpty {
            AppLogger.library.info("Skippable segments: \(self.segments.map { "\($0.kind.rawValue) \(Int($0.startSeconds))-\(Int($0.endSeconds))" }.joined(separator: ", "), privacy: .public)")
        }
    }

    /// The segment `time` is in, if a skip would still save something.
    func segment(at time: Double) -> LibraryMediaSegment? {
        segments.first { time >= $0.startSeconds - 0.25 && time < $0.endSeconds - 1 }
    }

    /// The segment to offer a skip for: within its first seconds always,
    /// later only with the controls up.
    func offered(at time: Double, controlsVisible: Bool) -> LibraryMediaSegment? {
        guard let segment = segment(at: time) else { return nil }
        return controlsVisible || time < segment.startSeconds + Self.promptSeconds ? segment : nil
    }

    /// Where skipping `segment` lands.
    nonisolated static func target(for segment: LibraryMediaSegment, duration: Double) -> Double {
        guard duration > 1 else { return segment.endSeconds }
        return min(segment.endSeconds, duration - 0.5)
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
