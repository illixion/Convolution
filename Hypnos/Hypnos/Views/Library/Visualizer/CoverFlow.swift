/*
 Hypnos - Music visualizer: Cover Flow.

 The album art of the current queue, one cover per run of songs from the same album, the playing album facing
 you in the middle and the rest fanned out to either side on a floor that reflects them. Drag, scroll, the arrow
 keys or a tap on a cover move through them; the view follows playback on its own and glides back to the playing
 album after a while if you wander off.

 The maths (`CoverFlowLayout`) knows nothing of SwiftUI or Jellyfin, so the flat view here and the visionOS
 RealityKit one (`CoverFlowSpatialView`) place their covers the same way.
 */

#if !os(tvOS)

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Layout

/// Where a cover sits at a distance `d` from the middle, in covers (0 = in the middle, 1 = the next one along).
/// Between 0 and 1 it turns and slides smoothly, so a cover passing the middle never jumps.
struct CoverFlowLayout: Equatable, Sendable {
    /// How far the cards beside the middle one are turned toward it.
    var sideAngle: Double = 34
    /// Where the first card beside the middle one sits, in card widths from the middle: close enough that the
    /// middle card overlaps its edge.
    var firstOffset: Double = 0.82
    /// How far apart the cards beyond that are, in card widths: they overlap, like a fanned deck.
    var spacing: Double = 0.42
    /// How far back, in card widths, the cards beside the middle one are pushed.
    var sideDepth: Double = 0.3

    struct Slot: Equatable, Sendable {
        /// Left of the middle is negative; in card widths.
        var x: Double
        /// Degrees about the vertical axis: positive turns the card's face to the right.
        var angle: Double
        /// Card widths away from the viewer (0 in the middle).
        var depth: Double
        var scale: Double
        var opacity: Double
    }

    static func smoothstep(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }

    func slot(at distance: Double) -> Slot {
        let magnitude = abs(distance)
        let sign: Double = distance < 0 ? -1 : 1
        let turn = Self.smoothstep(min(magnitude, 1))
        // Cards on the left face right (positive), cards on the right face left.
        let angle = -sign * sideAngle * turn
        let x = sign * (firstOffset * turn + spacing * max(0, magnitude - 1))
        let beyond = min(max(magnitude - 1, 0), 3)
        let depth = sideDepth * turn + 0.08 * beyond
        let scale = 1 - 0.1 * turn - 0.05 * beyond
        // Far cards dissolve rather than stop at a hard edge.
        let opacity = 1 - Self.smoothstep((magnitude - 3.2) / 2.2)
        return Slot(x: x, angle: angle, depth: depth, scale: scale, opacity: opacity)
    }

    /// The cards worth drawing around `position`.
    func visible(around position: Double, count: Int, reach: Int = 6) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        let lower = max(0, Int(position.rounded(.down)) - reach)
        let upper = min(count - 1, Int(position.rounded(.up)) + reach)
        return lower <= upper ? lower...upper : nil
    }
}

// MARK: - What the queue is, as covers

/// A run of queued songs from one album, which Cover Flow shows as one cover.
struct MusicCoverFlowEntry: Identifiable, Equatable {
    /// The queue position of the first song, so unique within the queue.
    var id: Int { range.lowerBound }
    let range: ClosedRange<Int>
    /// The first song of the run: its album's art, and what the labels say.
    let item: JellyfinMusicItem

    /// Consecutive songs of one album share a cover; an album that comes back later is a cover of its own.
    static func entries(from queue: [JellyfinMusicItem]) -> [MusicCoverFlowEntry] {
        var entries: [MusicCoverFlowEntry] = []
        var start = 0
        func key(_ item: JellyfinMusicItem) -> String { item.AlbumId ?? item.Id }
        for index in queue.indices {
            let ends = index + 1 == queue.count || key(queue[index + 1]) != key(queue[index])
            if ends {
                entries.append(MusicCoverFlowEntry(range: start...index, item: queue[start]))
                start = index + 1
            }
        }
        return entries
    }

    /// Which entry holds the queue position, found by bisection (queues can be long).
    static func index(of position: Int?, in entries: [MusicCoverFlowEntry]) -> Int? {
        guard let position else { return nil }
        var low = 0, high = entries.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if entries[middle].range.contains(position) { return middle }
            if position < entries[middle].range.lowerBound { high = middle - 1 } else { low = middle + 1 }
        }
        return nil
    }
}

// MARK: - The view

struct CoverFlowView: View {
    let music: JellyfinMusicSession
    let entries: [MusicCoverFlowEntry]
    /// Which entry is playing; the view follows it.
    let current: Int?
    /// Which cover is in front, for the captions: it is the playing one until the listener browses away.
    @Binding var focus: Int

    @State private var position: Double
    @State private var dragStart: Double?
    @State private var returnTask: Task<Void, Never>?
    @State private var settleTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let layout = CoverFlowLayout()

    init(music: JellyfinMusicSession, entries: [MusicCoverFlowEntry], current: Int?, focus: Binding<Int>) {
        self.music = music
        self.entries = entries
        self.current = current
        _focus = focus
        _position = State(initialValue: Double(current ?? 0))
    }

    private var focused: Int { min(max(0, Int(position.rounded())), max(0, entries.count - 1)) }
    private var glide: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.55) }

    var body: some View {
        GeometryReader { geometry in
            // The card is 1.12 wide and 1.42 tall, in artwork widths; leave room under it for the transport.
            // On a phone the middle card takes half the width, with its neighbours looking in from the sides.
            let side = max(110, min(geometry.size.width * (geometry.size.width < 600 ? 0.5 : 0.26), geometry.size.height * 0.42, 420))
            CoverFlowCovers(position: position, entries: entries, music: music, side: side, layout: layout,
                            tap: { index in tap(index) })
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(drag(side: side))
                #if os(macOS)
                .background(CoverFlowScrollCatcher { forward in scroll(by: forward / (side * 0.4)) })
                #endif
        }
        .focusable()
        // The arrow keys work without macOS drawing its focus ring around the whole window.
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onChange(of: self.focused, initial: true) { _, new in focus = new }
        .onChange(of: current) { _, new in
            guard let new, dragStart == nil else { return }
            returnTask?.cancel()
            withAnimation(glide) { position = Double(new) }
        }
        .onChange(of: entries.count) { _, _ in
            // The queue changed under us (a song added, a refill): keep the playing album in the middle.
            if dragStart == nil, let current { position = Double(current) }
        }
        .onDisappear { returnTask?.cancel(); settleTask?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Album covers")
        .accessibilityValue(entries.indices.contains(focused) ? entries[focused].item.Album ?? entries[focused].item.Name : "")
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 1 : -1)
        }
    }

    // MARK: Moving

    private func drag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil { dragStart = position; returnTask?.cancel() }
                let travelled = Double(-value.translation.width / (side * 0.4))
                position = min(max(0, (dragStart ?? 0) + travelled), Double(max(0, entries.count - 1)))
            }
            .onEnded { value in
                // Carry on a little with a fast flick, then settle on a cover.
                let projected = Double(-value.predictedEndTranslation.width / (side * 0.4))
                let target = min(max(0, ((dragStart ?? position) + projected).rounded()), Double(max(0, entries.count - 1)))
                dragStart = nil
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.82)) { position = target }
                scheduleReturn()
            }
    }

    /// A step by the keyboard or an accessibility action.
    private func step(_ delta: Int) {
        guard !entries.isEmpty else { return }
        returnTask?.cancel()
        withAnimation(glide) { position = min(max(0, Double(focused + delta)), Double(entries.count - 1)) }
        scheduleReturn()
    }

    #if os(macOS)
    /// A scroll of the trackpad or wheel moves with the fingers and settles on a cover a moment after they stop.
    private func scroll(by covers: Double) {
        returnTask?.cancel()
        dragStart = nil
        position = min(max(0, position + covers), Double(max(0, entries.count - 1)))
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { position = position.rounded() }
            scheduleReturn()
        }
    }
    #endif

    /// Left alone for a while off the playing album, the view glides back to it.
    private func scheduleReturn() {
        returnTask?.cancel()
        guard let current else { return }
        returnTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, dragStart == nil, Int(position.rounded()) != current else { return }
            withAnimation(glide) { position = Double(current) }
        }
    }

    /// A tap on a cover plays it; a tap on the one that is playing pauses or resumes it.
    private func tap(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        returnTask?.cancel()
        if index == current {
            music.toggle()
        } else {
            withAnimation(glide) { position = Double(index) }
            music.jump(to: entries[index].range.lowerBound)
        }
    }
}

// MARK: - The covers

/// The cards at a position. It animates the position itself, so a glide across several cards moves each one
/// along the curve (turning as it passes the middle) rather than straight to where it ends up.
private struct CoverFlowCovers: View, Animatable {
    // SwiftUI interpolates this from its own threads, so it is read and written outside the main actor.
    nonisolated(unsafe) var position: Double
    let entries: [MusicCoverFlowEntry]
    let music: JellyfinMusicSession
    let side: CGFloat
    let layout: CoverFlowLayout
    let tap: (Int) -> Void

    nonisolated var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let card = CoverCard.size(side: side)
            let centerY = geometry.size.height * 0.45
            ZStack {
                if let range = layout.visible(around: position, count: entries.count) {
                    ForEach(range, id: \.self) { index in
                        let distance = Double(index) - position
                        let slot = layout.slot(at: distance)
                        CoverCard(item: entries[index].item, music: music, side: side)
                            .scaleEffect(slot.scale)
                            .rotation3DEffect(.degrees(slot.angle), axis: (x: 0, y: 1, z: 0), anchor: .center, anchorZ: 0, perspective: 0.35)
                            // Cards farther from the middle also sit a little darker, as if further from the light.
                            .brightness(-0.12 * CoverFlowLayout.smoothstep(abs(distance) / 2))
                            .opacity(slot.opacity)
                            .position(x: geometry.size.width / 2 + slot.x * card.width, y: centerY)
                            .zIndex(-abs(distance))
                            .onTapGesture { tap(index) }
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

#if os(macOS)
/// Horizontal scroll (trackpad) or wheel movement over the view, as covers to move. A local monitor rather than a
/// view in the way, so clicks and taps still reach the covers.
private struct CoverFlowScrollCatcher: NSViewRepresentable {
    /// Positive moves forward through the queue.
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                // Fingers moving left (or the wheel rolled down) carry on to the next cover.
                let dominant = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                self.onScroll?(-dominant * scale)
                return nil
            }
        }

        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#endif

#endif
