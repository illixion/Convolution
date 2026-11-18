//
//  CinemaSpace.swift
//  Hypnos
//
//  What the cinema's immersive space holds and does, apart from the space that shows it:
//  the screen, the HUD's controls, the subtitles, the film's sound stage, their per-frame
//  placement and the gestures on them. `CinemaSpaceView` is this app's own space around it;
//  Nexus mounts the same root into its shared space and forwards the host's gestures
//  (`NexusHypnosModule.swift`, docs/nexus-module.md). Cinema (the model) says what to show;
//  this puts it there.
//

#if os(visionOS)

import AVFoundation
import DebugLog
import DebugTrace
import RAVEFilm
import RAVEMedia
import RAVESharedSpace
import RAVEUI
import RealityKit
import SwiftUI

@MainActor
final class CinemaSpace {
    let cinema = Cinema.shared
    private let session = FilmSession.shared
    /// Everything this space adds is under it.
    let root = Entity()
    private var appModel: AppModel?
    private var stage: FilmStage?
    private var ticking: Task<Void, Never>?
    private var built = false

    var screen = Entity()
    var sceneRoot = Entity()
    var headAnchor = AnchorEntity(.head)
    var hudHandle = Entity()
    var hudControls = Entity()
    var hudClose = Entity()
    var hudUtilities = Entity()
    var presentationEntity = Entity()
    let presentation = RAVEImmersivePlayerPresentation()
    var chromeOpacity: Float = 0
    var chromeLastUpdate = CACurrentMediaTime()
    var leftEdge = Entity()
    var rightEdge = Entity()
    /// The Big Screen's bottom corners: grips that resize it, like a window's.
    var leftCorner = Entity()
    var rightCorner = Entity()
    /// The Big Screen's picture shape, for a corner's diagonal drag.
    var screenAspect: Float = 16 / 9
    /// The corner grips fade with the window's controls.
    var cornerOpacity: Float = 0
    var cornerLastUpdate = CACurrentMediaTime()
    var dragStart: SIMD3<Float>?
    /// The Big Screen's centre when its grab bar's drag began.
    var screenDragStart: SIMD3<Float>?
    var resizeStart: Float?
    /// A video window's picture: a `VideoPlayerComponent` on its player.
    var playerPicture = Entity()
    /// The player the picture shows, held so it can't be mistaken for the
    /// next one: an `ObjectIdentifier` of a freed player was reused by the
    /// next episode's, at the same address, and the screen kept the old
    /// picture frozen while the new episode's sound played (device, 2026-11-05).
    var playerPictureSource: AVPlayer?
    /// The skip button and notices, over the picture's bottom-right corner.
    var hudPrompt = Entity()
    /// The stereo engine whose plane is on the screen, given back when it isn't.
    var stereoPictureEngine: Pseudo3DStereoEngine?
    /// A VR video's sphere (Cinema's VR mode), fed by the owner's player.
    let vrSphere = RAVEVRSphere()
    /// The format the sphere was last given.
    private var vrSphereFormat: VRFormat?
    /// Where the Big Screen's VR panel looks; kept between visits.
    var vrViewport = VRViewport()
    /// The view when a pan on the panel began.
    var vrPanStart: VRViewport?
    /// The subtitles over the picture, a view attachment.
    var subtitles = Entity()
    var subtitlesSource: ObjectIdentifier?
    /// The attachment's size in points; its aspect follows the picture's.
    private static let subtitleWidthPoints: CGFloat = 1600


    /// Makes the content once, under `root`.
    func build(appModel: AppModel) {
        self.appModel = appModel
        guard !built else { return }
        built = true
        root.name = "cinema-space"
        screen.name = "cinema-screen"
        playerPicture.name = "cinema-player-picture"
        subtitles.name = "cinema-subtitles"
        root.addChild(sceneRoot)
        sceneRoot.addChild(screen)
        root.addChild(headAnchor)
        hudHandle.components.set(ModelComponent(mesh: .generateBox(width: 0.18, height: 0.014, depth: 0.008, cornerRadius: 0.007), materials: [UnlitMaterial(color: .white)]))
        hudHandle.components.set(CollisionComponent(shapes: [.generateBox(width: 0.28, height: 0.07, depth: 0.04)]))
        hudHandle.components.set(InputTargetComponent())
        for edge in [leftEdge, rightEdge] {
            edge.components.set(CollisionComponent(shapes: [.generateBox(width: 0.08, height: 0.6, depth: 0.05)]))
            edge.components.set(InputTargetComponent())
            edge.components.set(HoverEffectComponent())
        }
        // An L at each bottom corner, its bend on the corner, its arms along
        // the bottom and up the side; sized for 2 m and scaled with the distance.
        for (corner, side) in [(leftCorner, Float(-1)), (rightCorner, Float(1))] {
            corner.name = side < 0 ? "cinema-corner-left" : "cinema-corner-right"
            let material = UnlitMaterial(color: .white)
            let along = ModelEntity(mesh: .generateBox(width: 0.07, height: 0.012, depth: 0.006, cornerRadius: 0.006),
                                    materials: [material])
            along.position = SIMD3(-side * 0.029, 0, 0)
            let up = ModelEntity(mesh: .generateBox(width: 0.012, height: 0.07, depth: 0.006, cornerRadius: 0.006),
                                 materials: [material])
            up.position = SIMD3(0, 0.029, 0)
            corner.addChild(along)
            corner.addChild(up)
            corner.components.set(OpacityComponent(opacity: 0.85))
            corner.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(width: 0.13, height: 0.13, depth: 0.05)
                .offsetBy(translation: SIMD3(-side * 0.025, 0.025, 0))]))
            corner.components.set(InputTargetComponent())
            corner.components.set(HoverEffectComponent())
        }
        hudControls.components.set(ViewAttachmentComponent(rootView: CinemaHUDControls(presentation: presentation)))
        hudPrompt.components.set(ViewAttachmentComponent(rootView: CinemaHUDPrompt().environment(appModel)))
        hudClose.components.set(ViewAttachmentComponent(rootView: CinemaHUDClose { [cinema] in
            guard let owner = cinema.owner else { return }
            cinema.hudCloseAction?()
            Task { await cinema.releaseFromSpace(owner) }
        }))
        hudUtilities.components.set(ViewAttachmentComponent(rootView: CinemaHUDUtilities { [cinema] in
            guard let owner = cinema.owner else { return }
            Task { await cinema.returnToWindow(owner) }
        }))
    }

    /// The space is up: placement runs, and the cinema learns it is open.
    func appeared(actions: (open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction)? = nil) {
        cinema.spaceAppeared(actions: actions)
        ForearmSleeve.shared.spaceOpened(CinemaRemote.shared, headPose: { Cinema.shared.hudDevicePose() })
        // Placed in a loop rather than on a view update: the window's plane view may still lay
        // the entity out once after it moves here.
        ticking?.cancel()
        ticking = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.placeScreen()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func disappeared() {
        ticking?.cancel()
        ticking = nil
        stopStage()
        presentation.dismiss()
        ForearmSleeve.shared.spaceClosed()
        cinema.spaceDisappeared()
    }

    /// What the room around the content should look like: the passthrough filter the wearer
    /// picked for the mode (Big Screen dark by default, HUD none; `Cinema.surroundings`).
    var surroundings: RAVESpaceSurroundings? { cinema.surroundings }

    /// Whether the picture draws over the viewer's arms. visionOS draws real
    /// arms over content it judges to be behind them, from a soft, noisy
    /// mask, and the HUD's picture, close to the viewer, faded in patches
    /// wherever that mask reached. The same fade on a forearm-worn panel in
    /// spatial-ai-character stopped once the space hid the mask (worn
    /// 2026-11-12), so HUD does too. Big Screen is across the room, where
    /// hands in front of it should look like hands in front of it; but while
    /// the remote on the forearm shows (`ForearmSleeve`), its tiles are a
    /// centimetre off that arm and fade the same way, so the mask goes then too.
    var hidesUpperLimbs: Bool { cinema.mode == .hud || ForearmSleeve.shared.isVisible }

    // MARK: The film's sound

    /// The film's object audio is played from here while the film owns the cinema.
    private func followFilmStage() {
        if cinema.owner == .film {
            guard stage == nil else { return }
            let stage = FilmStage(player: session.player, roomPose: { Cinema.shared.roomPose })
            root.addChild(stage.room)
            stage.start()
            self.stage = stage
        } else {
            stopStage()
        }
    }

    private func stopStage() {
        guard let stage else { return }
        stage.stop()
        stage.room.removeFromParent()
        self.stage = nil
    }

    // MARK: Gestures (forwarded by the space's view, or by Nexus's host)

    func tapped(_ value: EntityTargetValue<SpatialTapGesture.Value>) {
        if value.entity === vrSphere.entity { cinema.noteScreenTap(); return }
        if value.entity === playerPicture || value.entity === session.player.video.videoEntity
            || (stereoPictureEngine != nil && value.entity === stereoPictureEngine?.videoEntity) {
            cinema.noteScreenTap()
        }
    }

    func dragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        if value.entity === vrSphere.entity, case .panel = vrSphere.presentation {
            // The picture follows the hand: dragging right looks left. By how
            // far the hand moves (the screen's own units are metres across a
            // 15 m screen, which turned a swipe into a degree or two).
            if vrPanStart == nil { vrPanStart = vrViewport }
            let movement = value.convert(value.translation3D, from: .local, to: screen)
            let degreesPerMetre = DebugTunables.number("cinema.vrPanDegreesPerMetre", 150, range: 30 ... 400,
                                                       label: "VR panel pan (° per metre of hand)")
            if var view = vrPanStart {
                view.yawDegrees -= Double(movement.x) * degreesPerMetre
                view.pitchDegrees -= Double(movement.y) * degreesPerMetre
                if let projection = cinema.screenVRFormat?.projection { view = view.clamped(to: projection) }
                vrViewport = view
                vrSphere.setPresentation(.panel(view))
            }
            return
        }
        if value.entity === hudHandle {
            if cinema.mode == .bigScreen {
                if screenDragStart == nil { screenDragStart = cinema.screenPose?.columns.3.xyz }
                let movement = value.convert(value.translation3D, from: .local, to: sceneRoot)
                if let screenDragStart { cinema.dragScreen(from: screenDragStart, by: movement) }
                return
            }
            if dragStart == nil { dragStart = cinema.hudOffset }
            let movement = value.convert(value.translation3D, from: .local, to: screen.parent ?? headAnchor)
            if let dragStart {
                let candidate = dragStart + movement
                cinema.moveHUD(to: candidate)
            }
        } else if value.entity === leftCorner || value.entity === rightCorner {
            // Out or down grows it, in or up shrinks it. The corner sits half
            // the width (or height) from the centre, so the size changes by
            // twice the hand's movement, along whichever way it moved more.
            if resizeStart == nil { resizeStart = cinema.pictureWidth }
            let movement = value.convert(value.translation3D, from: .local, to: screen)
            let sign: Float = value.entity === rightCorner ? 1 : -1
            let gain = DebugTunables.number("cinema.cornerResizeGain", Float(1), range: 0.25 ... 4, step: 0.05,
                                            label: "Big Screen corner resize speed")
            let across = 2 * sign * movement.x
            let down = -2 * movement.y * screenAspect
            if let resizeStart {
                let width = resizeStart + gain * (abs(across) >= abs(down) ? across : down)
                cinema.resizeScreen(toWidth: max(0.1, width))
            }
        } else if value.entity === leftEdge || value.entity === rightEdge {
            // From the width drawn, which a close picture holds below the one asked for.
            if resizeStart == nil { resizeStart = cinema.pictureWidth }
            let movement = value.convert(value.translation3D, from: .local, to: screen)
            let sign: Float = value.entity === rightEdge ? 1 : -1
            if let resizeStart {
                let width = resizeStart + sign * 2 * movement.x
                if cinema.mode == .bigScreen {
                    // The edges are scaled with the screen's distance, and so is the drag's reach.
                    cinema.resizeScreen(toWidth: max(0.1, width))
                } else {
                    cinema.hudWidth = min(4, max(0.25, width))
                }
            }
        }
    }

    func dragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        if dragStart != nil || resizeStart != nil { cinema.hudPlacementSettled() }
        dragStart = nil; screenDragStart = nil; resizeStart = nil; vrPanStart = nil
    }

    // MARK: VR

    /// A VR video seen as VR, three ways (`Cinema.presentsVR`):
    /// - VR: the sphere around the head where VR started (`Cinema.vrPose`).
    /// - HUD: the same sphere hung from the smoothed head (`CinemaHUDFollow`),
    ///   so the picture stays where the eyes are, like the photo HUD.
    /// - Big Screen: a square panel at the screen's place looking into the
    ///   sphere (`RAVEVRSphere.Presentation.panel`), as wide as the screen and
    ///   seeing as much of the picture as it spans; a drag on it pans, the
    ///   grab bar moves it and the edges resize it as for any picture.
    /// The window keeps its controls in all three.
    private func placeVR() {
        for entity in [hudControls, hudClose, hudUtilities, hudPrompt] {
            entity.removeFromParent()
        }
        presentationEntity.components.remove(ViewAttachmentComponent.self)
        presentationEntity.removeFromParent()
        presentation.dismiss()
        chromeOpacity = 0
        releasePlayerPicture()
        releaseSubtitles()
        let format = cinema.screenVRFormat
        if format != vrSphereFormat {
            vrSphereFormat = format
            let sphere = vrSphere
            Task { await sphere.setFormat(format) }
            AppLogger.videoWindow.info("Cinema: VR \(format?.projection.label ?? "none", privacy: .public), \(format?.layout.map { $0.arrangement.rawValue } ?? "mono", privacy: .public)")
        }
        if cinema.screenPlayer == nil {
            AppLogger.videoWindow.error("Cinema: VR has no player to draw from")
        }
        vrSphere.show(player: cinema.screenPlayer)
        let sphereEntity = vrSphere.entity
        switch cinema.mode {
        case .bigScreen:
            guard let pose = cinema.screenPose else { cinema.noteScreenAttached(false); return }
            if screen.parent !== sceneRoot {
                screen.removeFromParent()
                sceneRoot.addChild(screen)
            }
            screen.setTransformMatrix(pose, relativeTo: nil)
            vrViewport.fieldOfViewDegrees = Double(cinema.screenWidthDegrees)
            vrSphere.setPresentation(.panel(vrViewport))
            if sphereEntity.parent !== screen { screen.addChild(sphereEntity) }
            let width = cinema.pictureWidth
            let transform = Transform(scale: SIMD3(width, width, 1))
            if sphereEntity.transform != transform { sphereEntity.transform = transform }
            if sphereEntity.components[CollisionComponent.self] == nil {
                sphereEntity.components.set(CollisionComponent(
                    shapes: [ShapeResource.generateBox(width: 1, height: 1, depth: 0.001)], isStatic: true))
                sphereEntity.components.set(InputTargetComponent())
            }
            // The grab bar under it and the side edges, sized with the distance.
            let chrome = cinema.screenDistance / 2
            if hudHandle.parent !== screen { screen.addChild(hudHandle) }
            hudHandle.scale = SIMD3(repeating: chrome)
            hudHandle.position = SIMD3(0, -width / 2 - 0.06 * chrome, 0.02 * chrome)
            hudHandle.components.set(OpacityComponent(opacity: 1))
            hudHandle.isEnabled = true
            for edge in [leftEdge, rightEdge] where edge.parent !== screen { screen.addChild(edge) }
            leftEdge.position = SIMD3(-width / 2, 0, 0.02 * chrome)
            rightEdge.position = SIMD3(width / 2, 0, 0.02 * chrome)
            leftEdge.scale = SIMD3(chrome, max(width / 0.6, 0.2), 1)
            rightEdge.scale = leftEdge.scale
            leftEdge.isEnabled = true
            rightEdge.isEnabled = true
            placeCorners(width: width, height: width, chrome: chrome)
            cinema.noteScreenAttached(cinema.screenPlayer != nil)
        case .hud:
            removeVRChrome()
            if let player = cinema.screenPlayer { cinema.applyHUDSound(to: player) }
            vrSphere.setPresentation(.sphere)
            let follow = CinemaHUDFollow.shared
            follow.attach(to: sceneRoot, keeping: sphereEntity)
            let parent = follow.hasPose ? follow.head : headAnchor
            if sphereEntity.parent !== parent { parent.addChild(sphereEntity) }
            if sphereEntity.transform != .identity { sphereEntity.transform = .identity }
            cinema.noteScreenAttached(cinema.screenPlayer != nil)
        default:
            removeVRChrome()
            vrSphere.setPresentation(.sphere)
            if sphereEntity.parent !== sceneRoot { sceneRoot.addChild(sphereEntity) }
            if let pose = cinema.vrPose { sphereEntity.setTransformMatrix(pose, relativeTo: nil) }
            cinema.noteScreenAttached(cinema.screenPlayer != nil && cinema.vrPose != nil)
        }
    }

    /// The Big Screen's corner grips at its bottom corners, as easy to hit
    /// from any distance (`chrome` is the distance over 2 m). They show and
    /// hide with the window's controls (the user's ask), but stay hittable
    /// while they fade and while one is held.
    private func placeCorners(width: Float, height: Float, chrome: Float) {
        screenAspect = max(width / max(height, 0.01), 0.1)
        // Shown with the window's controls (a tap on the screen brings them
        // back), fading as they do; held while one is being dragged.
        let owner = cinema.owner
        let visible = resizeStart != nil
            || (owner == .film ? cinema.hudFilmChromeVisible : !(cinema.hudVideoModel?.isUIHidden ?? false))
        let now = CACurrentMediaTime()
        let step = Float(min(max(now - cornerLastUpdate, 0), 0.1)) / 0.22
        cornerLastUpdate = now
        cornerOpacity = visible ? min(1, cornerOpacity + step) : max(0, cornerOpacity - step)
        for (corner, side) in [(leftCorner, Float(-1)), (rightCorner, Float(1))] {
            if corner.parent !== screen { screen.addChild(corner) }
            corner.scale = SIMD3(repeating: chrome)
            corner.position = SIMD3(side * (width / 2 + 0.012 * chrome), -height / 2 - 0.012 * chrome, 0.02 * chrome)
            corner.components.set(OpacityComponent(opacity: 0.85 * cornerOpacity))
            corner.isEnabled = cornerOpacity > 0
        }
    }

    /// Around the viewer the sphere has no grab bar, edges or hit box.
    private func removeVRChrome() {
        for entity in [hudHandle, leftEdge, rightEdge, leftCorner, rightCorner] { entity.removeFromParent() }
        vrSphere.entity.components.remove(CollisionComponent.self)
        vrSphere.entity.components.remove(InputTargetComponent.self)
    }

    private func releaseVR() {
        guard vrSphere.entity.parent != nil else { return }
        vrSphere.entity.components.remove(CollisionComponent.self)
        vrSphere.entity.components.remove(InputTargetComponent.self)
        vrSphere.stop()
        vrSphere.entity.removeFromParent()
        vrSphereFormat = nil
    }

    // MARK: Per-frame placement

    private func placeScreen() {
        followFilmStage()
        // The remote on the forearm steps itself once it has the scene.
        ForearmSleeve.shared.attach(to: root)
        let filmPicture = session.player.video.videoEntity
        // A film picture left here by a previous owner goes back to its
        // window, which re-adds it once it shows it again.
        if cinema.owner != .film || !cinema.mode.showsPicture, filmPicture.parent === screen {
            filmPicture.removeFromParent()
        }
        // A video window between players keeps the last one's picture.
        if cinema.owner == .film || cinema.owner == nil || !cinema.mode.showsPicture {
            releasePlayerPicture()
        }
        // A stereo plane goes back to its window as soon as it isn't shown
        // here, or another engine (or the flat player) takes over.
        if stereoPictureEngine != nil,
           !cinema.mode.showsPicture || cinema.owner == .film || cinema.owner == nil
            || cinema.screenStereo !== stereoPictureEngine {
            releaseStereoPicture()
        }
        if cinema.presentsVR {
            placeVR()
            return
        }
        releaseVR()
        guard cinema.mode.showsPicture, let owner = cinema.owner else {
            hudHandle.removeFromParent()
            hudControls.removeFromParent()
            hudClose.removeFromParent()
            hudUtilities.removeFromParent()
            hudPrompt.removeFromParent()
            presentationEntity.components.remove(ViewAttachmentComponent.self)
            presentationEntity.removeFromParent()
            presentation.dismiss()
            chromeOpacity = 0
            leftEdge.removeFromParent()
            rightEdge.removeFromParent()
            leftCorner.removeFromParent()
            rightCorner.removeFromParent()
            releaseSubtitles()
            cinema.noteScreenAttached(false)
            return
        }
        if cinema.mode == .hud {
            // Re-asserted every tick: the window's own policy (applied when its
            // player was made or its scene changed) overwrites the HUD's sound.
            if let player = cinema.screenPlayer ?? cinema.hudVideoModel?.nativePlayer { cinema.applyHUDSound(to: player) }
            // Until the follow has its first pose, the head anchor holds the screen.
            let follow = CinemaHUDFollow.shared
            follow.attach(to: sceneRoot, keeping: screen)
            let parent = follow.hasPose ? follow.head : headAnchor
            if screen.parent !== parent { parent.addChild(screen) }
            let direction = simd_normalize(-cinema.hudOffset)
            screen.transform = Transform(rotation: simd_quatf(from: SIMD3<Float>(0, 0, 1), to: direction), translation: cinema.hudOffset)
            if hudHandle.parent !== screen { screen.addChild(hudHandle) }
            if hudControls.parent !== screen { screen.addChild(hudControls) }
            if hudClose.parent !== screen { screen.addChild(hudClose) }
            if hudUtilities.parent !== screen { screen.addChild(hudUtilities) }
            if hudPrompt.parent !== screen { screen.addChild(hudPrompt) }
            if presentationEntity.parent !== screen { screen.addChild(presentationEntity) }
            if leftEdge.parent !== screen { screen.addChild(leftEdge) }
            if rightEdge.parent !== screen { screen.addChild(rightEdge) }
        } else {
            guard let pose = cinema.screenPose else { cinema.noteScreenAttached(false); return }
            if screen.parent !== sceneRoot {
                screen.removeFromParent()
                // Reparent through the scene root retained by the RealityView.
                sceneRoot.addChild(screen)
            }
            // The grab bar stays, under the screen (placed below).
            if hudHandle.parent !== screen { screen.addChild(hudHandle) }
            hudControls.removeFromParent()
            hudClose.removeFromParent()
            hudUtilities.removeFromParent()
            hudPrompt.removeFromParent()
            presentationEntity.components.remove(ViewAttachmentComponent.self)
            presentationEntity.removeFromParent()
            presentation.dismiss()
            chromeOpacity = 0
            // The side edges stay too: they resize the screen.
            if leftEdge.parent !== screen { screen.addChild(leftEdge) }
            if rightEdge.parent !== screen { screen.addChild(rightEdge) }
            screen.setTransformMatrix(pose, relativeTo: nil)
        }

        let picture: Entity
        let aspect: Float
        switch owner {
        case .film:
            let video = session.player.video
            picture = filmPicture
            aspect = video.pictureAspect ?? 16 / 9
            video.pictureAttached = true
        case .video:
            if let engine = cinema.screenStereo, let plane = engine.lendPicture() {
                if stereoPictureEngine !== engine {
                    stereoPictureEngine = engine
                    // The flat player's plane would sit behind it.
                    releasePlayerPicture()
                    AppLogger.videoWindow.info("Cinema: stereo picture on the big screen")
                }
                picture = plane
                aspect = engine.pictureAspect ?? lastAspect(of: plane)
                engine.noteLentPlaneWidth(cinema.pictureWidth)
                break
            }
            if let player = cinema.screenPlayer, playerPictureSource !== player {
                // A fresh entity for every player: a second
                // `VideoPlayerComponent` set on one that already showed a
                // player isn't known to switch what it draws.
                let replacing = playerPictureSource != nil
                releasePlayerPicture()
                let entity = Entity()
                entity.name = "cinema-player-picture"
                entity.components.set(VideoPlayerComponent(avPlayer: player))
                playerPicture = entity
                playerPictureSource = player
                AppLogger.videoWindow.info("Cinema: video player on the \(cinema.mode.rawValue, privacy: .public) screen\(replacing ? " (next player)" : "", privacy: .public)")
            }
            // Nothing lent yet (the space opened before the player resolved).
            guard playerPictureSource != nil else {
                cinema.noteScreenAttached(false)
                return
            }
            picture = playerPicture
            let size = cinema.screenPlayer?.currentItem?.presentationSize ?? .zero
            aspect = size.width > 0 && size.height > 0 ? Float(size.width / size.height) : lastAspect(of: picture)
        }
        if picture.parent !== screen {
            screen.addChild(picture)
            AppLogger.filmPlayer.info("Cinema: picture moved to the big screen")
        }
        // The framing needs the picture's shape; a new one (or a resize) may
        // leave the HUD's offset outside the view, so it is pulled back first.
        if cinema.mode == .hud {
            cinema.hudAspect = max(aspect, 0.1)
            cinema.refitHUD()
        }
        // The video component's mesh is aspect × 1 m, so its scale is its height.
        let height = cinema.pictureWidth / max(aspect, 0.1)
        let controlsVisible = presentation.isPresented || (owner == .film ? cinema.hudFilmChromeVisible : !(cinema.hudVideoModel?.isUIHidden ?? false))
        let now = CACurrentMediaTime()
        let step = Float(min(max(now - chromeLastUpdate, 0), 0.1)) / 0.22
        chromeLastUpdate = now
        chromeOpacity = controlsVisible ? min(1, chromeOpacity + step) : max(0, chromeOpacity - step)
        let slide = (1 - chromeOpacity) * 0.04
        if controlsVisible { hudControls.isEnabled = true; hudClose.isEnabled = true; hudUtilities.isEnabled = true }
        if cinema.mode == .hud, hudControls.isEnabled,
           let bounds = hudControls.components[ViewAttachmentComponent.self]?.bounds,
           bounds.extents.x > 1e-4 {
            let scale = cinema.pictureWidth / bounds.extents.x
            let controlsHeight = bounds.extents.y * scale
            // The grab bar, Close and Recenter/Window are laid out in metres
            // for the home-sized picture and shrink (or grow) with it, as the
            // controls do: left at a fixed size they dwarfed a small HUD.
            let chrome = cinema.pictureWidth / Cinema.hudHomeWidth
            hudControls.scale = SIMD3(repeating: scale)
            hudControls.position = SIMD3(0, -height / 2 - 0.05 * chrome - controlsHeight / 2 - slide, 0.02)
            let chromeY = -height / 2 - 0.05 * chrome - controlsHeight - 0.12 * chrome - slide
            hudHandle.position = SIMD3(0, chromeY, 0.02)
            hudClose.position = SIMD3(-0.18 * chrome, chromeY, 0.025)
            hudUtilities.position = SIMD3(0.25 * chrome, chromeY, 0.025)
            hudHandle.scale = SIMD3(repeating: chrome)
        }
        if cinema.mode == .bigScreen {
            // As large to the eye as the HUD's bar at its 2 m, under the picture.
            let scale = cinema.screenDistance / 2
            hudHandle.scale = SIMD3(repeating: scale)
            hudHandle.position = SIMD3(0, -height / 2 - 0.06 * scale, 0.02 * scale)
        }
        if cinema.mode == .hud, hudClose.isEnabled, hudUtilities.isEnabled {
            let chrome = cinema.pictureWidth / Cinema.hudHomeWidth
            if let bounds = hudClose.components[ViewAttachmentComponent.self]?.bounds, bounds.extents.x > 1e-4 {
                hudClose.scale = SIMD3(repeating: 0.085 * chrome / bounds.extents.x)
            }
            if let bounds = hudUtilities.components[ViewAttachmentComponent.self]?.bounds, bounds.extents.x > 1e-4 {
                hudUtilities.scale = SIMD3(repeating: 0.19 * chrome / bounds.extents.x)
            }
        }
        if cinema.mode == .hud {
            reconcilePresentation()
            if let bounds = presentationEntity.components[ViewAttachmentComponent.self]?.bounds,
               let controlsBounds = hudControls.components[ViewAttachmentComponent.self]?.bounds,
               let source = presentation.sourceFrame, presentation.controlsSize.width > 0 {
                let scale = hudControls.scale.x
                let pointScale = controlsBounds.extents.x * scale / Float(presentation.controlsSize.width)
                let x = Float(source.midX - presentation.controlsSize.width / 2) * pointScale
                let y = hudControls.position.y + Float(presentation.controlsSize.height / 2 - source.minY) * pointScale
                presentationEntity.scale = SIMD3(repeating: scale)
                presentationEntity.position = SIMD3(x, y + 0.015 + bounds.extents.y * scale / 2, 0.1)
            }
        }
        if cinema.mode == .hud { placeHUDPrompt(pictureHeight: height) }
        // Big Screen edges grow with the distance, like its grab bar, to stay as easy to hit.
        let edgeChrome = cinema.mode == .bigScreen ? cinema.screenDistance / 2 : 1
        leftEdge.position = SIMD3(-cinema.pictureWidth / 2, 0, 0.02 * edgeChrome)
        rightEdge.position = SIMD3(cinema.pictureWidth / 2, 0, 0.02 * edgeChrome)
        leftEdge.scale = SIMD3(edgeChrome, max(height / 0.6, 0.2), 1)
        rightEdge.scale = leftEdge.scale
        for entity in [hudControls, hudClose, hudUtilities, hudHandle] {
            entity.components.set(OpacityComponent(opacity: chromeOpacity))
            entity.isEnabled = chromeOpacity > 0
        }
        leftEdge.isEnabled = controlsVisible
        rightEdge.isEnabled = controlsVisible
        if cinema.mode == .bigScreen {
            placeCorners(width: cinema.pictureWidth, height: height, chrome: edgeChrome)
        } else {
            leftCorner.removeFromParent()
            rightCorner.removeFromParent()
        }
        let transform = Transform(scale: SIMD3(repeating: height))
        if picture.transform != transform { picture.transform = transform }
        // The window's Opacity adjustment, which the window applies in SwiftUI
        // and the screen's picture would otherwise ignore.
        let pictureOpacity: Float = owner == .film ? 1
            : Float(min(max(cinema.hudVideoModel?.effectiveVideoAdjustments.opacity ?? 1, 0.01), 1))
        if picture.components[OpacityComponent.self]?.opacity != pictureOpacity {
            picture.components.set(OpacityComponent(opacity: pictureOpacity))
        }
        if picture.components[CollisionComponent.self] == nil {
            let box = ShapeResource.generateBox(width: aspect, height: 1, depth: 0.001)
            picture.components.set(CollisionComponent(shapes: [box], isStatic: true))
        }
        if picture.components[InputTargetComponent.self]?.isEnabled != true {
            picture.components.set(InputTargetComponent())
        }
        placeSubtitles(aspect: aspect)
        cinema.noteScreenAttached(cinema.mode != .hud || headAnchor.isAnchored)
    }

    /// The skip button and notices over the picture's bottom-right corner,
    /// at the controls' scale, shown whether or not the controls are: like
    /// the window's prompt, the button offers itself for its first seconds.
    /// In front of the subtitles (0.05) so they never cover it.
    private func placeHUDPrompt(pictureHeight height: Float) {
        guard let bounds = hudPrompt.components[ViewAttachmentComponent.self]?.bounds,
              bounds.extents.x > 1e-4 else { return }
        // The controls' points-to-metres scale (natural size until measured).
        let scale = hudControls.scale.x
        let size = bounds.extents * scale
        let margin = cinema.pictureWidth * 0.03
        hudPrompt.scale = SIMD3(repeating: scale)
        hudPrompt.position = SIMD3(cinema.pictureWidth / 2 - margin - size.x / 2,
                                   -height / 2 + margin + size.y / 2, 0.06)
    }

    /// Immersive spaces reject modal presentations, including ones created
    /// by PresentationComponent. Draw the menu as a head-relative attachment.
    private func reconcilePresentation() {
        guard presentation.isPresented else {
            presentationEntity.components.remove(ViewAttachmentComponent.self)
            return
        }
        if presentationEntity.components[ViewAttachmentComponent.self] == nil {
            AppLogger.videoWindow.info("HUD menu: installing view attachment")
            presentationEntity.components.set(ViewAttachmentComponent(
                rootView: CinemaHUDMenuAttachment(presentation: presentation).environment(appModel)
            ))
        }
    }

    /// The aspect the picture was last scaled for, from its collision box.
    private func lastAspect(of picture: Entity) -> Float {
        guard let shape = picture.components[CollisionComponent.self]?.shapes.first else { return 16 / 9 }
        let extents = shape.bounds.extents
        return extents.y > 0 ? extents.x / extents.y : 16 / 9
    }

    /// The owner's subtitles over the picture, as large as the screen.
    private func placeSubtitles(aspect: Float) {
        guard let source = cinema.screenSubtitles else {
            releaseSubtitles()
            return
        }
        let height = Self.subtitleWidthPoints / CGFloat(max(aspect, 0.1))
        if subtitlesSource != ObjectIdentifier(source.controller) {
            let time = source.time
            subtitles.components.set(ViewAttachmentComponent(rootView:
                SubtitleOverlay(controller: source.controller, pictureAspect: CGFloat(aspect), filmTime: time)
                    .frame(width: Self.subtitleWidthPoints, height: height)))
            subtitlesSource = ObjectIdentifier(source.controller)
        }
        if subtitles.parent !== screen { screen.addChild(subtitles) }
        // Just in front of the picture, scaled from the attachment's own
        // measured width to the screen's.
        guard let bounds = subtitles.components[ViewAttachmentComponent.self]?.bounds,
              bounds.extents.x > 1e-4 else { return }
        let scale = cinema.pictureWidth / bounds.extents.x
        let transform = Transform(scale: SIMD3(repeating: scale), translation: SIMD3(0, 0, 0.05))
        if subtitles.transform != transform { subtitles.transform = transform }
    }

    private func releaseSubtitles() {
        guard subtitlesSource != nil else { return }
        subtitles.components.remove(ViewAttachmentComponent.self)
        subtitles.removeFromParent()
        subtitlesSource = nil
    }

    private func releaseStereoPicture() {
        guard let engine = stereoPictureEngine else { return }
        stereoPictureEngine = nil
        engine.reclaimPicture()
    }

    private func releasePlayerPicture() {
        guard playerPictureSource != nil else { return }
        playerPicture.components.remove(VideoPlayerComponent.self)
        playerPicture.components.remove(CollisionComponent.self)
        playerPicture.removeFromParent()
        playerPictureSource = nil
    }
}

/// This app's own immersive space for the cinema: `CinemaSpace` in a `RealityView`.
struct CinemaSpaceView: View {
    @Environment(\.openImmersiveSpace) private var open
    @Environment(\.dismissImmersiveSpace) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var space = CinemaSpace()

    var body: some View {
        RealityView { content in
            space.build(appModel: appModel)
            content.add(space.root)
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { space.tapped($0) })
        .simultaneousGesture(DragGesture().targetedToAnyEntity()
            .onChanged { space.dragChanged($0) }
            .onEnded { space.dragEnded($0) })
        .preferredSurroundingsEffect(space.surroundings?.effect)
        .upperLimbVisibility(space.hidesUpperLimbs ? .hidden : .automatic)
        .onAppear { space.appeared(actions: (open, dismiss)) }
        .onChange(of: space.presentation.isPresented) { _, shown in
            AppLogger.videoWindow.info("HUD menu requested: \(shown, privacy: .public)")
        }
        .onDisappear { space.disappeared() }
    }
}

#endif
