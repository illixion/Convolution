/*
 Hypnos - Music visualizer: Cover Flow in real depth (visionOS).

 The same cards and the same layout maths as the flat view (`CoverFlowLayout`, `CoverCard`), but each card is a
 SwiftUI view attached to a RealityKit entity standing in a volumetric window, so the glass is the system's and
 the cards turn and recede in real depth: the playing album faces you, the others fan out to either side. Pinch a
 card and drag to turn the queue past; tap one to play it.

 The scene is moved by one object (`CoverFlowSpatialScene`) that RealityKit's per-frame update drives, so the glide
 between cards is a frame-by-frame approach to a target rather than a SwiftUI animation: a RealityView's
 update closure only runs when SwiftUI state changes, which an animation in flight does not do.
 */

#if os(visionOS)

import RealityKit
import SwiftUI

@MainActor
final class CoverFlowSpatialScene {
    let root = Entity()
    var entries: [MusicCoverFlowEntry] = []
    var music = JellyfinMusicSession.shared
    /// Where the row is, in cards, and where it is heading.
    var position: Double = 0
    var target: Double = 0
    var isDragging = false
    /// Told when a different card comes to the front.
    var onFocus: ((Int) -> Void)?
    var subscription: EventSubscription?

    /// The artwork's width in points. A view attachment draws at about 1360 points to the metre, so the card
    /// (1.12 artwork widths) is a little under a quarter of a metre wide and a good 30 cm tall.
    static let side: CGFloat = 300
    static let pointsPerMetre: Float = 1360
    private static var cardSize: CGSize { CoverCard.size(side: side) }
    private static var cardWidth: Float { Float(cardSize.width) / pointsPerMetre }
    private static var cardHeight: Float { Float(cardSize.height) / pointsPerMetre }

    private let layout = CoverFlowLayout()
    private var cards: [Int: Entity] = [:]
    private var lastFocus = -1

    func advance(deltaTime: Double) {
        if !isDragging {
            // Eases towards the target, quickly at first, so a tap or a flick settles instead of snapping.
            position += (target - position) * (1 - exp(-8 * min(deltaTime, 0.1)))
            if abs(target - position) < 0.0004 { position = target }
        }
        place()
    }

    private func place() {
        guard let range = layout.visible(around: position, count: entries.count) else {
            for index in Array(cards.keys) { drop(index) }
            return
        }
        for index in Array(cards.keys) where !range.contains(index) { drop(index) }
        let width = Self.cardWidth
        for index in range {
            let entity = cards[index] ?? makeCard(index)
            let slot = layout.slot(at: Double(index) - position)
            let rotation = simd_quatf(angle: Float(slot.angle) * .pi / 180, axis: [0, 1, 0])
            entity.transform = Transform(scale: .init(repeating: Float(slot.scale)), rotation: rotation,
                                         translation: [Float(slot.x) * width, 0, -Float(slot.depth) * width])
            entity.components.set(OpacityComponent(opacity: Float(slot.opacity)))
        }
        let focus = min(max(0, Int(position.rounded())), max(0, entries.count - 1))
        if focus != lastFocus { lastFocus = focus; onFocus?(focus) }
    }

    private func drop(_ index: Int) {
        cards[index]?.removeFromParent()
        cards[index] = nil
    }

    /// A queue that changed under the scene: start the cards afresh against the new entries.
    func reset() {
        for index in Array(cards.keys) { drop(index) }
        lastFocus = -1
    }

    private func makeCard(_ index: Int) -> Entity {
        let entity = Entity()
        entity.name = "cover-\(index)"
        entity.components.set(ViewAttachmentComponent(rootView: CoverCard(item: entries[index].item, music: music, side: Self.side)))
        // The card takes pinches and taps as a block.
        let shape = ShapeResource.generateBox(width: Self.cardWidth, height: Self.cardHeight, depth: 0.02)
        entity.components.set(CollisionComponent(shapes: [shape]))
        entity.components.set(InputTargetComponent())
        root.addChild(entity)
        cards[index] = entity
        return entity
    }

    /// Which card an entity is.
    static func index(of entity: Entity) -> Int? {
        var node: Entity? = entity
        while let current = node {
            if current.name.hasPrefix("cover-"), let index = Int(current.name.dropFirst("cover-".count)) { return index }
            node = current.parent
        }
        return nil
    }

    /// Metres to cards, for a drag.
    static var metresPerCard: Double { Double(cardWidth) * 0.6 }
}

struct CoverFlowSpatialView: View {
    let music: JellyfinMusicSession
    let entries: [MusicCoverFlowEntry]
    let current: Int?
    @Binding var focus: Int

    @State private var scene = CoverFlowSpatialScene()
    @State private var dragStart: Double?
    @State private var returnTask: Task<Void, Never>?

    var body: some View {
        RealityView { content in
            scene.entries = entries
            scene.music = music
            scene.position = Double(current ?? 0)
            scene.target = scene.position
            scene.onFocus = { index in if focus != index { focus = index } }
            content.add(scene.root)
            scene.subscription = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated { scene.advance(deltaTime: event.deltaTime) }
            }
        } update: { _ in
            // What the playing queue is now: keep the scene's copy.
            if scene.entries != entries { scene.entries = entries; scene.reset() }
            scene.music = music
        }
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    if dragStart == nil { dragStart = scene.position; scene.isDragging = true; returnTask?.cancel() }
                    // Metres of drag in the scene, as cards.
                    let metres = Double(value.convert(value.translation3D, from: .local, to: .scene).x)
                    let travelled = -metres / CoverFlowSpatialScene.metresPerCard
                    scene.position = min(max(0, (dragStart ?? 0) + travelled), Double(max(0, entries.count - 1)))
                    scene.target = scene.position
                }
                .onEnded { _ in
                    scene.isDragging = false
                    scene.target = scene.position.rounded()
                    dragStart = nil
                    scheduleReturn()
                }
        )
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    guard let index = CoverFlowSpatialScene.index(of: value.entity), entries.indices.contains(index) else { return }
                    returnTask?.cancel()
                    if index == current {
                        music.toggle()
                    } else {
                        scene.target = Double(index)
                        music.jump(to: entries[index].range.lowerBound)
                    }
                }
        )
        .onChange(of: current) { _, new in
            guard let new, dragStart == nil else { return }
            returnTask?.cancel()
            scene.target = Double(new)
        }
        .onDisappear {
            returnTask?.cancel()
            scene.subscription?.cancel()
            scene.reset()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Album covers")
    }

    /// Off the playing album for a while, the row glides back to it.
    private func scheduleReturn() {
        returnTask?.cancel()
        guard let current else { return }
        returnTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, dragStart == nil else { return }
            scene.target = Double(current)
        }
    }
}

#endif
