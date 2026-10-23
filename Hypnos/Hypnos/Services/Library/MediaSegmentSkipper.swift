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
 - Every skip, SponsorBlock's automatic ones included, can be undone for
   `LibrarySegmentSkipPolicy.undoSeconds` (`UndoSkipButton`): back to where
   it left from, and that segment isn't offered again, since the viewer
   chose to watch it (a wrongly marked SponsorBlock segment, say).
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

    /// The last skip, while it can still be undone.
    struct Undo: Equatable {
        let segment: LibraryMediaSegment
        /// Where the playhead was when it skipped.
        let returnTo: Double
        /// "Skipped Intro", "Skipped Sponsor".
        let title: String
        /// When it can no longer be undone.
        let deadline: Date
        let id = UUID()
    }

    private(set) var undo: Undo?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    /// Segments the viewer went back into: not offered again.
    @ObservationIgnored private var declined: Set<LibraryMediaSegment> = []

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
        resetSkips()
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
    /// Segments that skip by themselves, with what the undo button calls them.
    @ObservationIgnored private var autoSkipLabels: [LibraryMediaSegment: String] = [:]
    /// Each auto-skip fires once: a viewer who scrubs back into one wants
    /// to watch it.
    @ObservationIgnored private var autoSkipped: Set<LibraryMediaSegment> = []

    private func loadSponsorBlock(_ id: YouTubeVideoID) async {
        let key = id.videoIdentity
        guard key != loadedItemId else { return }
        loadedItemId = key
        resetSkips()
        segments = []
        autoSkipLabels = [:]
        autoSkipped = []
        let loaded = await SponsorBlock.segments(for: id)
        guard loadedItemId == key else { return }
        segments = loaded.map(\.librarySegment).filter(LibrarySegmentSkipPolicy.eligible)
        for segment in loaded where segment.category.mode == .auto {
            autoSkipLabels[segment.librarySegment] = segment.category.shortName
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

    /// The segments still offered: all but the ones the viewer went back into.
    private var offerable: [LibraryMediaSegment] {
        declined.isEmpty ? segments : segments.filter { !declined.contains($0) }
    }

    /// The segment `time` is in, if a skip would still save something.
    func segment(at time: Double) -> LibraryMediaSegment? {
        LibrarySegmentSkipPolicy.segment(at: time, in: offerable)
    }

    /// The segment to offer a skip for: within its first seconds always,
    /// later only with the controls up.
    func offered(at time: Double, controlsVisible: Bool) -> LibraryMediaSegment? {
        LibrarySegmentSkipPolicy.offered(at: time, controlsVisible: controlsVisible, in: offerable)
    }

    /// The stretches to mark on the timeline.
    var markedRanges: [ClosedRange<Double>] {
        segments.map { $0.startSeconds ... max($0.startSeconds, $0.endSeconds) }
    }

    // MARK: Undo

    /// A skip from `time` past `segment` happened: it can be undone for a
    /// few seconds. `name` overrides the segment's own ("Sponsor").
    func noteSkipped(_ segment: LibraryMediaSegment, from time: Double, name: String? = nil) {
        let undo = Undo(segment: segment, returnTo: max(0, min(time, segment.endSeconds)),
                        title: "Skipped \(name ?? segment.name)",
                        deadline: .now.addingTimeInterval(LibrarySegmentSkipPolicy.undoSeconds))
        self.undo = undo
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LibrarySegmentSkipPolicy.undoSeconds))
            guard !Task.isCancelled, let self, self.undo?.id == undo.id else { return }
            self.undo = nil
        }
    }

    /// Where to go back to, and the segment is no longer offered; nil when
    /// there is nothing to undo.
    func takeUndo() -> Double? {
        guard let undo else { return nil }
        undoExpiry?.cancel()
        self.undo = nil
        declined.insert(undo.segment)
        return undo.returnTo
    }

    private func resetSkips() {
        undoExpiry?.cancel()
        undo = nil
        declined = []
    }

    /// Where skipping `segment` lands.
    nonisolated static func target(for segment: LibraryMediaSegment, duration: Double) -> Double {
        LibrarySegmentSkipPolicy.target(for: segment, duration: duration)
    }
}

/// Undo for the last skip: "Skipped Sponsor · Undo", a lighter capsule than
/// the skip button's, with a ring running down the seconds left to undo it.
struct UndoSkipButton: View {
    let undo: MediaSegmentSkipper.Undo
    let action: () -> Void
    @State private var remaining: CGFloat = 1

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
                    Circle().trim(from: 0, to: remaining)
                        .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption.weight(.bold))
                }
                .frame(width: 26, height: 26)
                Text(undo.title).foregroundStyle(.secondary)
                Text("Undo").fontWeight(.semibold)
            }
            .font(.headline)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        #if os(iOS) || os(macOS)
        .tint(.white)
        #endif
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        // From the time left, so a button made again mid-countdown (the
        // controls showing or hiding) carries on where it was.
        .onAppear {
            let left = max(0, undo.deadline.timeIntervalSinceNow)
            remaining = left / LibrarySegmentSkipPolicy.undoSeconds
            withAnimation(.linear(duration: left)) { remaining = 0 }
        }
        .id(undo.id)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .accessibilityLabel("\(undo.title). Undo")
        .accessibilityIdentifier("player.undoSkip")
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
