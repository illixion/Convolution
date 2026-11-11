/*
 Hypnos - Music section: the playing song's name, flickable.

 The title block of the mini player, the Mini Player window and Now Playing. Its artist and album are links
 (see `MusicLinks.swift`), and flicking it left or right goes to the next or the previous song, sliding the way a
 page turns: the song you are leaving moves off one side while the next one comes in from the other.

 A flick that skips a song by accident is worse than one that does nothing, so the gesture is deliberately hard
 to make:
  - it only starts on a drag that is mostly sideways (a scroll, or a sheet being dragged down, never skips);
  - the song has to be pulled most of the way across (`commitDistance`: at least 120 points and 45% of the
    block's width), and still be there when the finger lifts: speed alone never skips;
  - while it is being pulled, the song that would play peeks in from the edge, so you see what you would get;
    going past the threshold ticks, and pulling back under it cancels;
  - a direction with no song behind it (the end of a queue that stops there) only stretches.
 */

import SwiftUI

/// How big the labels are drawn, which is where they sit.
enum MusicTrackStyle {
    /// The library's compact mini player: one line of title, one of artist, leading.
    case bar
    /// The Mini Player window: title, artist and album, centred under the cover.
    case panel
    /// Now Playing: a large title, "artist · album" and the file's quality, centred.
    case nowPlaying
}

struct MusicTrackLabels: View {
    let music: JellyfinMusicSession
    let style: MusicTrackStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the settled layer shows. It follows `music.current`, but on its own schedule so a change can slide.
    @State private var shown: JellyfinMusicItem?
    @State private var shownIndex: Int?
    /// Where the settled layer is, in points from the middle. Zero at rest; the drag and the slide move it.
    @State private var offset: CGFloat = 0
    /// The song that just left (after a change that did not come from a flick), and which side of `shown` it is on.
    @State private var leaving: JellyfinMusicItem?
    @State private var leavingSide: CGFloat = -1
    /// The song a committed flick is bringing in; Next has already moved `music` on, so it can't be asked.
    @State private var arriving: JellyfinMusicItem?
    @State private var isCommitting = false
    @State private var width: CGFloat = 300
    /// Whether this drag is a sideways one: decided once, when it starts, and kept until it ends.
    @State private var dragIsSideways: Bool?
    @State private var armed = false

    init(music: JellyfinMusicSession, style: MusicTrackStyle) {
        self.music = music
        self.style = style
        _shown = State(initialValue: music.current)
        _shownIndex = State(initialValue: music.currentIndex)
    }

    // MARK: Geometry

    /// How far apart the songs sit: the block's width and a gap, so a neighbour is fully out of sight at rest.
    private var pitch: CGFloat { max(width, 120) + 28 }

    private var neighbourOnLeft: JellyfinMusicItem? { isCommitting && offset > 0 ? arriving : music.previousItem }
    private var neighbourOnRight: JellyfinMusicItem? { isCommitting && offset < 0 ? arriving : music.nextItem }

    // MARK: Body

    var body: some View {
        ZStack {
            if reduceMotion {
                if let item = shown {
                    MusicTrackText(item: item, style: style, music: music)
                        .id(item.id)
                        .transition(.opacity)
                }
            } else {
                carousel
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        #if !os(tvOS)
        .gesture(flick, isEnabled: !reduceMotion)
        #endif
        .sensoryFeedback(.alignment, trigger: armed) { _, now in now }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Next Song") { if music.nextItem != nil { music.next() } }
        .accessibilityAction(named: "Previous Song") { if music.previousItem != nil { music.skipBack() } }
        .onChange(of: music.current) { old, current in sync(from: old, to: current) }
    }

    @ViewBuilder
    private var carousel: some View {
        if let item = shown {
            MusicTrackText(item: item, style: style, music: music)
                .frame(maxWidth: .infinity)
                .offset(x: offset)
                .opacity(opacity(at: offset))
            if let leaving {
                MusicTrackText(item: leaving, style: style, music: music)
                    .frame(maxWidth: .infinity)
                    .offset(x: offset + leavingSide * pitch)
                    .opacity(opacity(at: offset + leavingSide * pitch))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if offset < -0.5, let next = neighbourOnRight {
                MusicTrackText(item: next, style: style, music: music)
                    .frame(maxWidth: .infinity)
                    .offset(x: offset + pitch)
                    .opacity(opacity(at: offset + pitch))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if offset > 0.5, let previous = neighbourOnLeft {
                MusicTrackText(item: previous, style: style, music: music)
                    .frame(maxWidth: .infinity)
                    .offset(x: offset - pitch)
                    .opacity(opacity(at: offset - pitch))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// A song fades as it leaves the middle, so what slides past never overlaps what arrives.
    private func opacity(at x: CGFloat) -> Double {
        max(0, 1 - Double(abs(x) / (pitch * 0.85)))
    }

    // MARK: The flick

    #if !os(tvOS)
    private var flick: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !isCommitting else { return }
                let dx = value.translation.width, dy = value.translation.height
                if dragIsSideways == nil { dragIsSideways = MusicFlick.startsSideways(dx: dx, dy: dy) }
                guard dragIsSideways == true else { return }
                let canGoThisWay = dx < 0 ? music.nextItem != nil : music.previousItem != nil
                offset = MusicFlick.travel(dx: dx, width: width, canGo: canGoThisWay)
                let beyond = MusicFlick.isArmed(dx: dx, dy: dy, width: width, canGo: canGoThisWay)
                if beyond != armed { armed = beyond }
            }
            .onEnded { value in
                defer { dragIsSideways = nil; armed = false }
                guard !isCommitting, dragIsSideways == true else { return }
                let outcome = MusicFlick.outcome(dx: value.translation.width, dy: value.translation.height, width: width,
                                                 hasNext: music.nextItem != nil, hasPrevious: music.previousItem != nil)
                if case .skip(let forward) = outcome, let item = forward ? music.nextItem : music.previousItem {
                    commit(forward ? 1 : -1, bringing: item)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { offset = 0 }
                }
            }
    }
    #endif

    /// Skip a song: Next or Previous starts at once, and the block finishes the slide it began.
    private func commit(_ direction: Int, bringing item: JellyfinMusicItem) {
        isCommitting = true
        arriving = item
        if direction > 0 { music.next() } else { music.skipBack() }
        let target = -CGFloat(direction) * pitch
        withAnimation(.smooth(duration: 0.3), completionCriteria: .logicallyComplete) {
            offset = target
        } completion: {
            // The song that slid in is the one now playing, so nothing moves when it takes the middle.
            shown = music.current
            shownIndex = music.currentIndex
            withTransaction(Transaction(animation: nil)) {
                offset = 0
                leaving = nil
                arriving = nil
            }
            isCommitting = false
        }
    }

    /// `music.current` changed. A flick handles its own; any other change (the song ended, a button, the remote,
    /// a tap in Up Next) slides the same way, forward unless the queue went backwards.
    private func sync(from old: JellyfinMusicItem?, to current: JellyfinMusicItem?) {
        guard let current else { return }
        guard !isCommitting else { return }
        guard current.id != shown?.id || music.currentIndex != shownIndex else {
            // The same song with fresher details (an edit, a rating).
            shown = current
            return
        }
        let forward = (music.currentIndex ?? 0) >= (shownIndex ?? 0)
        dragIsSideways = nil
        armed = false
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.18)) { shown = current }
            shownIndex = music.currentIndex
            return
        }
        leaving = shown
        leavingSide = forward ? -1 : 1
        shown = current
        shownIndex = music.currentIndex
        withTransaction(Transaction(animation: nil)) { offset = forward ? pitch : -pitch }
        withAnimation(.smooth(duration: 0.4), completionCriteria: .logicallyComplete) {
            offset = 0
        } completion: {
            leaving = nil
        }
    }
}

/// One song's labels at a style. The artist and the album are links.
private struct MusicTrackText: View {
    let item: JellyfinMusicItem
    let style: MusicTrackStyle
    let music: JellyfinMusicSession

    var body: some View {
        switch style {
        case .bar:
            VStack(alignment: .leading, spacing: 2) {
                Text(item.Name).font(.subheadline.weight(.semibold)).lineLimit(1)
                MusicArtistLine(item: item).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .panel:
            VStack(spacing: 2) {
                Text(item.Name).font(.title3.weight(.semibold)).lineLimit(1)
                MusicArtistLine(item: item).font(.body).foregroundStyle(.secondary)
                MusicAlbumLink(item: item, fallback: " ").font(.subheadline).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        case .nowPlaying:
            VStack(spacing: 4) {
                Text(item.Name).font(.title2.bold()).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
                MusicSongSubtitle(song: item).foregroundStyle(.secondary)
                Text(qualityLine ?? " ").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var qualityLine: String? {
        var parts: [String] = []
        if let quality = item.quality { parts.append(quality.isLossless ? "\(quality.badge) · \(quality.detail)" : quality.detail) }
        if music.soundCheck, let gain = item.NormalizationGain ?? item.AlbumNormalizationGain {
            parts.append("Sound Check \(String(format: "%+.1f", gain)) dB")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }
}
